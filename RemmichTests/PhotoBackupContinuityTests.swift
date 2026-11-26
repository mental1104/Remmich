import Foundation
import SQLite3
import Testing
@testable import Remmich

/// 接续链路使用真实SQLite、生产Importer/Checker/Worker；只替换Photos观察与只读网络端口，禁止访问生产媒体。
@Suite("Backup continuity before original export")
struct PhotoBackupContinuityTests {
    /// 读取已安装Mac候选写入的真实旧枚举形状；保留已有/待核查状态，未知未来格式仍拒绝，不清空队列。
    @Test func retainsInstalledCandidateHistoryStates() throws {
        let legacy = #"[{"id":"11111111-1111-4111-8111-111111111111","source":{"localID":"legacy-existing","kind":"photo"},"stage":"existing","attempts":0,"primaryWasDuplicate":false},{"id":"22222222-2222-4222-8222-222222222222","source":{"localID":"legacy-review","kind":"photo"},"stage":"failed","attempts":0,"primaryWasDuplicate":false,"failure":"historyNeedsReview"}]"#
        let jobs = try JSONDecoder().decode([PhotoBackupJob].self, from: Data(legacy.utf8))
        let journal = PhotoBackupJournal(header: .init(version: 1, namespace: "synthetic", selectedAlbumIDs: [], allowCloud: false), jobs: jobs)
        try journal.validate(namespace: "synthetic")
        #expect(jobs.map(\.stage) == [.existing, .failed] && jobs[1].failure == .historyNeedsReview)
        var retained = jobs[0]
        retained.pause()
        #expect(retained.stage == .existing && retained.attempts == 0 && retained.primaryAssetID == nil)
        let roundTrip = try JSONDecoder().decode(PhotoBackupJournal.self, from: JSONEncoder().encode(journal))
        #expect(roundTrip.jobs.map(\.stage) == [.existing, .failed])
        let future = legacy.replacingOccurrences(of: "existing\"", with: "future\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([PhotoBackupJob].self, from: Data(future.utf8)) }
    }

    /// 实际SQLite只读导入保留缺失摘要，跨账号拒绝且源文件逐字节不变。
    @Test func importsReadOnlyAndRejectsAnotherAccount() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "official.sqlite")
        try makeContinuitySQLite(url)
        let before = try Data(contentsOf: url)
        let history = try await PhotoBackupHistoryImporter.read(url, scope: continuityScope(), now: Date(timeIntervalSince1970: 100))
        #expect(history.records.count == 2 && history.records[0].checksum != nil && history.records[1].checksum == nil)
        #expect(history.records[0].modifiedAt == Date(timeIntervalSince1970: 10))
        #expect(try Data(contentsOf: url) == before)
        await #expect(throws: PhotoBackupContinuityError.wrongAccount) {
            try await PhotoBackupHistoryImporter.read(url, scope: continuityScope(other: true))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    /// 88,187项历史按ID索引复用；重复ID、版本变化和无checksum均不可获得查询许可，不逐项搜索全数组。
    @Test(.timeLimit(.minutes(1))) func indexesLargeHistoryWithoutGuessingMissingVersions() {
        var records = (0 ..< 88187).map { id in
            PhotoBackupHistoryRecord(localID: "asset-\(id)", cloudID: "cloud-\(id)", checksum: continuityChecksum, modifiedAt: Date(timeIntervalSince1970: 10))
        }
        records.append(records[0])
        let index = PhotoBackupHistoryIndex(.init(version: 1, namespace: continuityScope().cacheNamespace, userID: continuityScope().userID,
                                                  importedAt: Date(timeIntervalSince1970: 100), records: records))
        #expect(index.query(for: continuitySource("asset-0")) == nil)
        #expect(index.query(for: continuitySource("asset-88186"))?.sha1Hex == String(repeating: "01", count: 20))
        #expect(index.query(for: continuitySource("asset-1", modified: 11)) == nil)
        #expect(index.query(for: continuitySource("asset-1", modified: 10.75)) != nil)
        #expect(index.query(for: continuitySource("other-phone"), cloudID: "cloud-1") != nil)
        #expect(index.query(for: continuitySource("missing")) == nil)
        // 整批逆序核查而非只测一个末项，防止未来退回每项遍历88,187行的平方开销。
        var resolved = 0
        for id in (1 ..< 88187).reversed() {
            guard index.query(for: continuitySource("asset-\(id)")) != nil else { break }
            resolved += 1
        }
        #expect(resolved == 88186)
    }

    /// 无SQLite且Photos对象也不可读取时仍须待核查，不能对缺失源发放字节上传许可。
    @Test @MainActor func missingPhotosSourceStillRequiresReview() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let checker = PhotoBackupContinuityChecker(store: store, metadata: photos)
        let source = continuitySource("old")
        let plan = try await checker.plan(jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {})
        #expect(plan.allowed.isEmpty && plan.existing.isEmpty && plan.review == [source])
        #expect(photos.reads == 1 && client.batches.isEmpty && client.savedMatches.isEmpty)
    }

    /// 超过两个批次的缓存摘要全部在导出前查询；真实Worker对已有主体只暂停，缺失历史单独待核查，Exporter零调用。
    @Test(.timeLimit(.minutes(1))) @MainActor func batchLookupNeverExportsExistingOrUnconfirmedHistory() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = continuityScope(), store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let sources = (0 ..< 130).map { continuitySource("asset-\($0)") }
        try await seedContinuity(store, sources: sources)
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        client.missEveryOther = true
        let jobs = sources.map { PhotoBackupJob(source: $0) }
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: jobs, scope: scope, client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(client.batches.map(\.count) == [64, 64, 2] && photos.reads == 0)
        #expect(plan.allowed.isEmpty && plan.existing.count == 65 && plan.review.count == 65)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue(sources)
        try await store.savePhotoBackups(journal, scope: scope)
        let exporter = ContinuityNoExport()
        let result = try await PhotoBackupWorker(store: store, exporter: exporter).run(
            scope: scope, userID: scope.userID, allowCloud: true, client: ContinuityNoUpload(), preflight: plan,
            validateContext: {}, progress: { _, _ in }
        )
        let cold = try await SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")).loadPhotoBackups(scope: scope)
        #expect(exporter.calls == 0 && result.completed == 0 && result.skipped == 65 && result.review == 65)
        #expect(cold.jobs.count { $0.stage == .existing } == 65 && cold.jobs.count { $0.failure == .historyNeedsReview } == 65)
        #expect(cold.jobs.allSatisfy { $0.attempts == 0 && $0.primaryAssetID == nil })
        do {
            let persistedSnapshot = try await store.loadPhotoBackupHistory(scope: continuityScope(other: true))
            #expect(persistedSnapshot == nil)
        }
    }

    /// Live Photo只有主体checksum命中不能冒充完整动态备份；仍不读取原片补证明。
    @Test @MainActor func duplicateStillDoesNotCompleteALivePhoto() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let source = PhotoBackupSource(localID: "live", modifiedAt: Date(timeIntervalSince1970: 10), kind: .livePhoto)
        try await seedContinuity(store, sources: [source])
        let photos = ContinuityPhotos()
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: [.init(source: source)], scope: continuityScope(), client: ContinuityQueries(), progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.allowed.isEmpty && plan.existing.isEmpty && plan.review == [source] && photos.reads == 0)
    }

    /// 只允许导入之后新拍摄/修改且完整远端元数据无关联的源；导入前、已被官方客户端备份或无云ID都待核查。
    @Test @MainActor func onlyNewUnassociatedPhotosReceivePermission() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await seedContinuity(store, sources: [])
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let names = ["new", "old", "already-synced", "unavailable"]
        for name in names {
            photos.values[name] = continuitySnapshot(name, created: name == "old" ? 90 : 200, cloud: name != "unavailable")
        }
        client.associatedCloud = "cloud-already-synced"
        let jobs = names.map { PhotoBackupJob(source: continuitySource($0, modified: 200)) }
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: jobs, scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.allowed.map(\.localID) == ["new"] && plan.review.count == 3 && plan.existing.isEmpty)
    }

    /// 已尝试的新源只有明确单项核查才可重进完整查重；该许可仍不能放宽导入前的未知历史。
    @Test @MainActor func explicitVerificationDoesNotAuthorizeOldHistory() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await seedContinuity(store, sources: [])
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        photos.values["new"] = continuitySnapshot("new", created: 200, cloud: true)
        photos.values["old"] = continuitySnapshot("old", created: 90, cloud: true)
        var new = PhotoBackupJob(source: continuitySource("new", modified: 200))
        var old = PhotoBackupJob(source: continuitySource("old", modified: 200))
        try new.begin(); new.pause(); new.queueForVerification()
        try old.begin(); old.pause(); old.queueForVerification()
        let checker = PhotoBackupContinuityChecker(store: store, metadata: photos)
        let blocked = try await checker.plan(jobs: [new, old], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {})
        #expect(blocked.allowed.isEmpty && blocked.review.count == 2)
        let explicit = try await checker.plan(jobs: [new, old], scope: continuityScope(), client: client, verificationIDs: [new.id, old.id], progress: { _, _ in }, validateContext: {})
        #expect(explicit.allowed == [new.source] && explicit.review == [old.source])
    }

    /// 在线响应回来时原账号已退休，Checker拒绝整个结果，不能用旧账号命中给新页面发放许可。
    @Test @MainActor func accountRetirementRejectsLateResults() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let source = continuitySource("old")
        try await seedContinuity(store, sources: [source])
        let client = ContinuityQueries()
        var current = true
        client.onQuery = { current = false }
        var rejected = false
        do {
            _ = try await PhotoBackupContinuityChecker(store: store, metadata: ContinuityPhotos()).plan(
                jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {
                    guard current else { throw LibraryWriteError.changedAccount }
                }
            )
        } catch LibraryWriteError.changedAccount { rejected = true }
        #expect(rejected)
        #expect(client.batches.count == 1)
    }

    /// 查询失败或响应缺项不能返回部分许可；即使先前批次命中，也不能启动实际导出。
    @Test(arguments: [false, true]) @MainActor func rejectsFailedOrIncompleteLookup(_ incomplete: Bool) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let source = continuitySource("old")
        try await seedContinuity(store, sources: [source])
        let client = ContinuityQueries()
        client.incomplete = incomplete; client.fails = !incomplete
        await #expect(throws: (any Error).self) {
            try await PhotoBackupContinuityChecker(store: store, metadata: ContinuityPhotos()).plan(
                jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
            )
        }
    }

    /// 真实Controller返回任务前先发布running；扫描await期间主线程仍能暂停，退役后磁盘队列没有被迟到结果改写。
    @Test(.timeLimit(.minutes(1))) @MainActor func scanCanBeCancelledWhileTheUIIsResponsive() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let session = continuitySession(), manager = LibraryManagementController()
        manager.configure(session: session, endpoint: session.apiURL)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (releases, release) = AsyncStream<Void>.makeStream()
        defer { start.finish(); release.finish() }
        let controller = PhotoBackupController(store: store, albumLoader: { .init(albums: [.init(id: "all", title: "Synthetic")], limited: false) }, albumScanner: { _ in
            start.yield(())
            var iterator = releases.makeAsyncIterator()
            _ = await iterator.next()
            return [.init(id: "all", assets: [.init(source: continuitySource("old"), capturedAt: nil)])]
        }, observeAutomaticPhotos: false)
        await controller.load(using: manager); await controller.loadAlbums()
        controller.selected = ["all"]
        let task = try #require(controller.scan(using: manager))
        #expect(controller.running)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        controller.cancel()
        release.yield(())
        await task.value
        let saved = try await store.loadPhotoBackups(scope: continuityScope())
        #expect(!controller.running && saved.jobs.isEmpty && controller.requiresSelectionScan)
    }
}

/// 无导入场景以独立Photos/网络端口观察真实Checker与Worker；交集零导出，新源进入字节查重通道。
@Suite("Server iCloud backup matching without imports")
struct PhotoBackupServerMatchingTests {
    /// 无导入新照片可按原片查重；没有云ID也可备份，只有可解析的公开元组会附加来源上报。
    @Test(arguments: [LocalPhotoCloudIdentity.resolved("cloud-fresh"), .unavailable, .incomplete, .failed])
    @MainActor func admitsUnmatchedSourcesForOriginalChecksum(_ cloud: LocalPhotoCloudIdentity) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        photos.values["fresh"] = continuitySnapshot("fresh", created: 200, cloud: true).withCloudIdentity(cloud)
        let source = continuitySource("fresh", modified: 200)
        let plan = try await PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos).plan(
            jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.allowed == [source] && plan.existing.isEmpty && plan.review.isEmpty && photos.reads == 2)
        #expect(client.savedMatches.isEmpty)
        if case .resolved = cloud {
            #expect(plan.uploadMetadata[source]?.cloudId == "cloud-fresh")
        } else {
            #expect(plan.uploadMetadata.isEmpty)
        }
    }

    /// 已尝试任务默认不自动重新上传；用户明确恢复该项后仍通过同一原片查重通道。
    @Test @MainActor func attemptedSourceNeedsExplicitVerification() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        photos.values["fresh"] = continuitySnapshot("fresh", created: 200, cloud: true)
        var job = PhotoBackupJob(source: continuitySource("fresh", modified: 200))
        try job.begin(); job.fail(.network); job.queueForVerification()
        let checker = PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos)
        let automatic = try await checker.plan(jobs: [job], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {})
        let explicit = try await checker.plan(jobs: [job], scope: continuityScope(), client: client, verificationIDs: [job.id], progress: { _, _ in }, validateContext: {})
        #expect(automatic.allowed.isEmpty && automatic.review == [job.source])
        #expect(explicit.allowed == [job.source] && explicit.review.isEmpty)
    }

    /// 真实Checker→磁盘原片→实际客户端HTTP→SQLite；未命中上传，字节重复零POST，来源失败/摘要不符保留未确认。
    @Test(arguments: ["created", "duplicate", "metadata-failure", "wrong-digest"], [PhotoBackupSource.Kind.photo, .video])
    @MainActor func backsUpWithoutImportAndReportsTheActualCloudOrigin(_ mode: String, _ kind: PhotoBackupSource.Kind) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
        var exchanges = continuityEmptyStream()
        exchanges.append(continuityOriginalCheck(id: id, duplicate: mode == "duplicate"))
        if mode != "duplicate" {
            exchanges.append(.init(method: "POST", path: "assets", status: 201, json: "{\"id\":\"\(id)\",\"status\":\"created\"}",
                                   requestContentTypePrefix: "multipart/form-data; boundary="))
        }
        let serverDigest = mode == "wrong-digest" ? continuityChecksum : digest
        // Worker内部使用UUID.uuidString，HTTP边界必须统一回服务端权限集合采用的小写，不能放宽夹具来掩盖问题。
        exchanges.append(.init(method: "GET", path: "assets/" + id, status: 200, json: continuityUploadedAsset(id: id, checksum: serverDigest, kind: kind)))
        if mode != "wrong-digest" {
            exchanges.append(continuityOriginWrite(fails: mode == "metadata-failure"))
        }
        let firstRequestCount = exchanges.count
        if mode == "metadata-failure" {
            exchanges += continuityEmptyStream()
            exchanges.append(continuityOriginalCheck(id: id, duplicate: true))
            exchanges.append(.init(method: "GET", path: "assets/" + id, status: 200, json: continuityUploadedAsset(id: id, checksum: digest, kind: kind)))
            exchanges.append(continuityOriginWrite())
        }
        let http = ChecksumLookupHTTPFixture(exchanges: exchanges)
        defer { http.close() }
        let client = try #require(http.manager.client)
        let scope = MediaAccountScope(session: checksumLookupSession(endpoint: http.endpoint))
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        let photos = ContinuityPhotos()
        photos.values["fresh"] = continuitySnapshot("fresh", created: 200, cloud: true, mediaKind: kind == .video ? .video : .image)
        let source = PhotoBackupSource(localID: "fresh", modifiedAt: Date(timeIntervalSince1970: 200), kind: kind)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([source]); try await store.savePhotoBackups(journal, scope: scope)
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: journal.jobs, scope: scope, client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.allowed == [source] && plan.uploadMetadata[source]?.cloudId == "cloud-fresh")
        let exporter = ContinuityOriginalExporter(directory: root.appending(path: "original"))
        let result = try await PhotoBackupWorker(store: store, exporter: exporter).run(
            scope: scope, userID: scope.userID, allowCloud: false, client: client, preflight: plan, validateContext: {}, progress: { _, _ in }
        )
        let cold = try await store.loadPhotoBackups(scope: scope)
        let requests = await http.script.requests()
        let succeeds = mode == "created" || mode == "duplicate"
        #expect(result.completed == (succeeds ? 1 : 0) && result.failed == (succeeds ? 0 : 1))
        #expect(result.duplicates == (mode == "duplicate" ? 1 : 0))
        #expect(cold.jobs.first?.stage == (succeeds ? .completed : .failed))
        #expect(cold.jobs.first?.primaryChecksum == digest && cold.jobs.first?.primaryAssetID?.uuidString.lowercased() == id)
        #expect(exporter.calls == 1 && exporter.cloudFlags == [false] && !FileManager.default.fileExists(atPath: exporter.directory.path))
        #expect(requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/assets") }.count == (mode == "duplicate" ? 0 : 1))
        let check = try #require(requests.first { $0.url.path.hasSuffix("/bulk-upload-check") })
        let checkBody = try #require(check.body)
        let json = try #require(try JSONSerialization.jsonObject(with: checkBody) as? [String: Any])
        let checked = try #require(json["assets"] as? [[String: String]])
        #expect(checked.first?["checksum"] == "a9993e364706816aba3e25717850c26c9cd0d89d")
        if mode != "wrong-digest" {
            let request = try #require(requests.last)
            let requestBody = try #require(request.body)
            let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let items = try #require(body["items"] as? [[String: Any]])
            let item = try #require(items.first)
            #expect(item["assetId"] as? String == id)
            let originValue = try #require(item["value"])
            let origin = try JSONDecoder().decode(PhotoBackupOrigin.self, from: JSONSerialization.data(withJSONObject: originValue))
            #expect(item["key"] as? String == PhotoBackupOrigin.metadataKey(for: "cloud-fresh"))
            #expect(origin.metadata.cloudId == "cloud-fresh" && origin.checksum == digest && origin.byteVerified && origin.method == "sha1")
            if mode == "created" {
                try await verifyOtherDeviceMatchesReportedOrigin(origin, assetID: id, kind: kind, root: root)
            }
        }
        #expect(requests.count == firstRequestCount)
        if mode == "metadata-failure" {
            // 媒体已成功但来源PUT失败：明确恢复后必须先查重，不能再次POST同一原片。
            var retry = try await store.loadPhotoBackups(scope: scope)
            let jobID = try #require(retry.jobs.first?.id)
            try retry.resumeForVerification(only: jobID); try await store.savePhotoBackups(retry, scope: scope)
            let retryPlan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
                jobs: retry.jobs, scope: scope, client: client, verificationIDs: [jobID], progress: { _, _ in }, validateContext: {}
            )
            let recovered = try await PhotoBackupWorker(store: store, exporter: exporter).run(
                scope: scope, userID: scope.userID, allowCloud: false, client: client, preflight: retryPlan, validateContext: {}, progress: { _, _ in }
            )
            let persisted = try await store.loadPhotoBackups(scope: scope)
            let allRequests = await http.script.requests()
            #expect(recovered.completed == 1 && recovered.duplicates == 1 && recovered.failed == 0)
            #expect(persisted.jobs.first?.stage == .completed && persisted.jobs.first?.attempts == 2)
            #expect(allRequests.count == exchanges.count)
            #expect(allRequests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/assets") }.count == 1)
        }
    }

    /// origin为第一台设备实际上传后捕获的请求，assetID为同一远端主体；另一台本机ID不同且原片不可导出。
    /// kind与第一台设备的媒体类型一致，root为独立测试目录；验证HTTP来源、fresh资产和仅ID标记，Worker零导出。
    @MainActor private func verifyOtherDeviceMatchesReportedOrigin(_ origin: PhotoBackupOrigin, assetID: String, kind: PhotoBackupSource.Kind, root: URL) async throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin))
        let event: [String: Any] = ["type": "AssetMetadataV1", "ack": "AssetMetadataV1|22222222-2222-4222-8222-222222222222",
                                    "data": ["assetId": assetID, "key": PhotoBackupOrigin.metadataKey(for: origin.metadata.cloudId), "value": value]]
        let line = try String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n"
        // 服务端可同时有旧官方元组和本次原片来源；另一设备应选中当前元组，重复当前元组仍须拒绝。
        let stale = try LocalMediaMobileMetadata(cloudId: origin.metadata.cloudId, createdAt: origin.metadata.createdAt?.addingTimeInterval(1),
                                                 adjustmentTime: origin.metadata.adjustmentTime, latitude: origin.metadata.latitude, longitude: origin.metadata.longitude)
        var oldEvent = event
        oldEvent["data"] = try ["assetId": assetID, "key": "mobile-app", "value": JSONSerialization.jsonObject(with: JSONEncoder().encode(stale))]
        let oldLine = try String(decoding: JSONSerialization.data(withJSONObject: oldEvent), as: UTF8.self) + "\n"
        let empty = continuityEmptyStream()
        let http = ChecksumLookupHTTPFixture(exchanges: [empty[0],
                                                         .init(method: "POST", path: "sync/stream", status: 200, json: oldLine + line + empty[1].json, contentType: "application/jsonlines+json"),
                                                         .init(method: "GET", path: "assets/" + assetID, status: 200, json: continuityUploadedAsset(id: assetID, checksum: origin.checksum, kind: kind)),
                                                         continuityOriginWrite()])
        defer { http.close() }
        let client = try #require(http.manager.client)
        let scope = MediaAccountScope(session: checksumLookupSession(endpoint: http.endpoint))
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "other-device.sqlite"))
        try await store.prepare(scope: scope)
        let photos = ContinuityPhotos()
        photos.values["ipad-local-id"] = continuitySnapshot("ipad-local-id", created: 200, cloud: true, cloudID: origin.metadata.cloudId, mediaKind: kind == .video ? .video : .image)
        let source = PhotoBackupSource(localID: "ipad-local-id", modifiedAt: Date(timeIntervalSince1970: 200), kind: kind)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([source]); try await store.savePhotoBackups(journal, scope: scope)
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: journal.jobs, scope: scope, client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.existing == [source] && plan.allowed.isEmpty && plan.review.isEmpty)
        let exporter = ContinuityNoExport()
        let result = try await PhotoBackupWorker(store: store, exporter: exporter).run(
            scope: scope, userID: scope.userID, allowCloud: false, client: ContinuityNoUpload(), preflight: plan, validateContext: {}, progress: { _, _ in }
        )
        let cold = try await store.loadPhotoBackups(scope: scope)
        let requests = await http.script.requests()
        #expect(result.skipped == 1 && result.completed == 0 && exporter.calls == 0)
        #expect(cold.jobs.first?.stage == .existing && cold.jobs.first?.attempts == 0 && cold.jobs.first?.primaryAssetID == nil)
        #expect(requests.count == 4 && !requests.contains { $0.url.path.hasSuffix("/bulk-upload-check") || $0.url.path.hasSuffix("/assets") })
        let request = try #require(requests.last)
        let body = try #require(request.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        let marker = try #require(items.first?["value"] as? [String: Any])
        #expect(items.first?["assetId"] as? String == assetID)
        #expect(items.first?["key"] as? String == "remmich-icloud-match" && marker["byteVerified"] as? Bool == false)
    }

    /// 云端原片命中直接记existing，另一个不可读取的Photos对象仍待核查；两者真实Worker均零导出。
    @Test @MainActor func matchesCloudOnlyWithoutImportOrOriginals() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = continuityScope(), store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let id = addServerContinuityCandidate("known", photos: photos, client: client)
        // unknown没有可读取的Photos快照；它与可读取但未匹配的新照片是两个不同状态。
        let sources = [continuitySource("known", modified: 200), continuitySource("unknown", modified: 200)]
        // 真实Controller已先建立认证账号目录；只准备同样的账号，不导入或保存任何备份历史。
        try await store.prepare(scope: scope)
        let importedHistory = try await store.loadPhotoBackupHistory(scope: scope)
        #expect(importedHistory == nil)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue(sources); try await store.savePhotoBackups(journal, scope: scope)
        let plan = try await PhotoBackupContinuityChecker(store: store, metadata: photos).plan(
            jobs: journal.jobs, scope: scope, client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.existing == [sources[0]] && plan.review == [sources[1]] && plan.allowed.isEmpty)
        #expect(client.savedMatches == [id: "cloud-known"] && client.batches.isEmpty)
        let exporter = ContinuityNoExport()
        let result = try await PhotoBackupWorker(store: store, exporter: exporter).run(
            scope: scope, userID: scope.userID, allowCloud: true, client: ContinuityNoUpload(), preflight: plan, validateContext: {}, progress: { _, _ in }
        )
        let cold = try await store.loadPhotoBackups(scope: scope)
        #expect(exporter.calls == 0 && result.completed == 0 && result.skipped == 1 && result.review == 1)
        #expect(cold.jobs.map(\.stage) == [.existing, .failed] && cold.jobs.allSatisfy { $0.attempts == 0 && $0.primaryAssetID == nil })
        let summary = PhotoBackupUnattemptedSummary(jobs: cold.jobs)
        #expect(summary.completed == 1 && summary.eligibleJobIDs.isEmpty)
    }

    /// kind覆盖视频/Live/双原图的逻辑身份；仅保存元数据匹配事实，不生成任何成员字节或上传完成证明。
    @Test(arguments: [PhotoBackupSource.Kind.video, .livePhoto, .rawJPEG])
    @MainActor func matchesCompoundIdentityWithoutClaimingOriginalBytes(_ kind: PhotoBackupSource.Kind) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let id = addServerContinuityCandidate("known", photos: photos, client: client)
        let mediaKind: LocalPhotoIdentity.MediaKind = kind == .video ? .video : kind == .livePhoto ? .livePhoto : .image
        let original = try #require(photos.values["known"])
        photos.values["known"] = .init(identity: .init(localIdentifier: "known", modificationDate: original.identity.modificationDate, mediaKind: mediaKind),
                                       creationDate: original.creationDate, adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
                                       pixelWidth: 10, pixelHeight: 10, duration: 0, mediaSubtypes: 0, resources: [], cloudIdentity: original.cloudIdentity)
        client.assets[id.uuidString] = try .init(id: id, ownerId: #require(UUID(uuidString: continuityScope().userID)), type: kind == .video ? "VIDEO" : "IMAGE", isTrashed: false,
                                                 isOffline: false, isEdited: false, checksum: continuityChecksum, updatedAt: Date(timeIntervalSince1970: 300))
        let pair: PhotoBackupRawJPEGSource? = if kind == .rawJPEG {
            try PhotoBackupRawJPEGSource(originals: [
                .init(kind: .alternatePhoto, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 10, pixelHeight: 10),
                .init(kind: .photo, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 10, pixelHeight: 10),
            ], hasAdjustments: false, adjustmentTime: nil)
        } else {
            nil
        }
        let source = PhotoBackupSource(localID: "known", modifiedAt: original.identity.modificationDate, kind: kind, rawJPEG: pair)
        let plan = try await PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos).plan(
            jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.existing == [source] && plan.allowed.isEmpty && client.savedMatches == [id: "cloud-known"])
    }

    /// kind选择缺失/歧义/版本/权限状态反例；只有ID相同不能绕过当前源和远端拥有者校验。
    @Test(arguments: ["ambiguous", "version", "missing-metadata", "owner", "trashed", "offline", "edited", "inaccessible"])
    @MainActor func rejectsIncompleteOrStaleServerEvidence(_ kind: String) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let id = addServerContinuityCandidate("known", photos: photos, client: client)
        if kind == "ambiguous" {
            client.records.append(client.records[0])
        }
        if kind == "version" {
            photos.values["known"] = continuitySnapshot("known", created: 201, cloud: true)
        }
        if kind == "missing-metadata" {
            client.records = [.init(assetID: id, value: Data(#"{"iCloudId":"cloud-known"}"#.utf8))]
        }
        if ["owner", "trashed", "offline", "edited"].contains(kind) {
            client.assets[id.uuidString] = .init(id: id, ownerId: kind == "owner" ? UUID() : UUID(uuidString: continuityScope().userID)!, type: "IMAGE",
                                                 isTrashed: kind == "trashed", isOffline: kind == "offline", isEdited: kind == "edited",
                                                 checksum: continuityChecksum, updatedAt: Date(timeIntervalSince1970: 300))
        }
        if kind == "inaccessible" {
            client.assets = [:]
        }
        let source = continuitySource("known", modified: 200)
        let plan = try await PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos).plan(
            jobs: [.init(source: source)], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.existing.isEmpty && plan.allowed.isEmpty && plan.review == [source] && client.savedMatches.isEmpty)
    }

    /// mode模拟元数据保存失败、账号退役或本机修改；实际等待后的变化不能发布已匹配或授权上传。
    @Test(arguments: ["write", "account", "source"])
    @MainActor func refusesUnconfirmedWritesAndLateContext(_ mode: String) async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        _ = addServerContinuityCandidate("known", photos: photos, client: client)
        client.rejectWrites = mode == "write"
        var current = true
        client.onAsset = {
            if mode == "account" {
                current = false
            }
            if mode == "source" {
                photos.values["known"] = continuitySnapshot("known", created: 201, cloud: true)
            }
        }
        await #expect(throws: (any Error).self) {
            try await PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos).plan(
                jobs: [.init(source: continuitySource("known", modified: 200))], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {
                    guard current else { throw LibraryWriteError.changedAccount }
                }
            )
        }
        #expect(client.savedMatches.isEmpty)
    }

    /// 超过两批的本机元数据/远端标记保持64项边界，无SHA1或原片读入口；同源匹配状态不重排为自动尾队列。
    @Test(.timeLimit(.minutes(1))) @MainActor func savesOnlyCompleteBoundedMatchBatches() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let jobs = (0 ..< 130).map { index -> PhotoBackupJob in
            let name = "server-\(index)"
            _ = addServerContinuityCandidate(name, photos: photos, client: client)
            return .init(source: continuitySource(name, modified: 200))
        }
        let plan = try await PhotoBackupContinuityChecker(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), metadata: photos).plan(
            jobs: jobs, scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {}
        )
        #expect(plan.existing.count == 130 && plan.allowed.isEmpty && client.matchBatchSizes == [64, 64, 2])
        #expect(client.savedMatches.count == 130 && client.batches.isEmpty)
    }
}

/// 合成完整空元数据快照；真实客户端必须先读取ack再消费终止行，不能把失败/半条流当作未命中。
private nonisolated func continuityEmptyStream() -> [ChecksumLookupExchange] {
    [.init(method: "GET", path: "sync/ack", status: 200, json: "[]"),
     .init(method: "POST", path: "sync/stream", status: 200,
           json: "{\"type\":\"SyncCompleteV1\",\"data\":{},\"ack\":\"SyncCompleteV1|11111111-1111-4111-8111-111111111111\"}\n", contentType: "application/jsonlines+json")]
}

/// id为合成服务端主体，duplicate选择字节重复或真正未命中；nonce必须读取实际请求，不能预先猜测。
private nonisolated func continuityOriginalCheck(id: String, duplicate: Bool) -> ChecksumLookupExchange {
    .init(method: "POST", path: "assets/bulk-upload-check", status: 200, json: "", responseJSON: { request in
        guard let body = request.body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let assets = json["assets"] as? [[String: String]], assets.count == 1, let nonce = assets.first?["id"]
        else {
            throw LibraryWriteError.malformedResponse
        }
        return "{\"results\":[{\"id\":\"\(nonce)\",\"action\":\"\(duplicate ? "reject" : "accept")\",\"assetId\":\"\(id)\",\"isTrashed\":false}]}"
    })
}

/// id/checksum为独立HTTP金值，kind选择照片或视频类型；摘要与abc对应，错误摘要不能产生来源写入。
private nonisolated func continuityUploadedAsset(id: String, checksum: String, kind: PhotoBackupSource.Kind = .photo) -> String {
    "{\"id\":\"\(id)\",\"ownerId\":\"99999999-9999-4999-8999-999999999999\",\"isFavorite\":false,\"visibility\":\"timeline\",\"isTrashed\":false,\"type\":\"\(kind == .video ? "VIDEO" : "IMAGE")\",\"originalFileName\":\"fresh.jpg\",\"checksum\":\"\(checksum)\",\"isOffline\":false,\"isEdited\":false,\"updatedAt\":\"1970-01-01T00:05:00Z\"}"
}

/// fails模拟媒体已提交但来源上报失败；成功仅回传实际items，业务断言独立检查请求中的身份与证据。
private nonisolated func continuityOriginWrite(fails: Bool = false) -> ChecksumLookupExchange {
    .init(method: "PUT", path: "assets/metadata", status: fails ? 503 : 200, json: "", responseJSON: { request in
        guard let body = request.body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any], let items = json["items"] else {
            throw LibraryWriteError.malformedResponse
        }
        return try String(decoding: JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    })
}

/// 仅替换系统原片读取；真实Worker仍运行SQLite检查点、客户端SHA1/HTTP、回读和来源写入。
@MainActor private final class ContinuityOriginalExporter: PhotoBackupResourceExporting {
    let directory: URL
    var calls = 0
    var cloudFlags: [Bool] = []

    /// directory为本例独占私有临时目录，不读取任何用户照片。
    init(directory: URL) {
        self.directory = directory
    }

    /// source限定合成照片；allowCloud逐项记录，返回已知SHA1的abc磁盘文件，供真实上传客户端独立计算。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        calls += 1; cloudFlags.append(allowCloud)
        guard source.kind == .photo || source.kind == .video else { throw PhotoBackupExportError(reason: .unsupportedResources) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.kind == .video ? "fresh.mp4" : "fresh.jpg"
        let file = directory.appending(path: name)
        try Data("abc".utf8).write(to: file)
        return .init(directory: directory, primary: .init(file: file, name: name), motion: nil,
                     created: Date(timeIntervalSince1970: 200), modified: Date(timeIntervalSince1970: 200), favorite: false)
    }
}

/// name绑定合成云标识、完整官方元组和独立fresh资产；返回真实候选UUID，不创建Photos资源或原片文件。
@MainActor private func addServerContinuityCandidate(_ name: String, photos: ContinuityPhotos, client: ContinuityQueries) -> UUID {
    let id = UUID()
    photos.values[name] = continuitySnapshot(name, created: 200, cloud: true)
    client.records.append(.init(assetID: id, value: Data(#"{"iCloudId":"cloud-\#(name)","createdAt":"1970-01-01T00:03:20Z"}"#.utf8)))
    client.assets[id.uuidString] = .init(id: id, ownerId: UUID(uuidString: continuityScope().userID)!, type: "IMAGE", isTrashed: false,
                                         isOffline: false, isEdited: false, checksum: continuityChecksum, updatedAt: Date(timeIntervalSince1970: 300))
    return id
}

/// 创建独占临时根目录URL；每例在实际异步任务退役后删除，不读取用户应用目录。
private nonisolated func continuityRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "Continuity-\(UUID())")
}

/// other选择另一个合成账号，用于隔离验证；永远不连接实际服务。
private nonisolated func continuitySession(other: Bool = false) -> AccountSession {
    .init(apiURL: URL(string: "https://continuity.example.invalid/api")!, accessToken: "synthetic", userID: other ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111",
          userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 返回使用生产namespace算法的合成账号边界。
private nonisolated func continuityScope(other: Bool = false) -> MediaAccountScope {
    .init(session: continuitySession(other: other))
}

/// 合成规范SHA1，不对应任何私人媒体。
private nonisolated var continuityChecksum: String {
    Data(repeating: 1, count: 20).base64EncodedString()
}

/// id为合成Photos身份，modified单位为Unix秒；默认对应官方缓存10秒版本。
private nonisolated func continuitySource(_ id: String, modified: TimeInterval = 10) -> PhotoBackupSource {
    .init(localID: id, modifiedAt: Date(timeIntervalSince1970: modified), kind: .photo)
}

/// 构造公开元数据观察；cloud=false模拟无法解析云标识，cloudID可复用另一设备的标识，mediaKind确定图片/视频。
private nonisolated func continuitySnapshot(_ id: String, created: TimeInterval, cloud: Bool, cloudID: String? = nil,
                                            mediaKind: LocalPhotoIdentity.MediaKind = .image) -> LocalPhotoSnapshot
{
    .init(identity: .init(localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 200), mediaKind: mediaKind),
          creationDate: Date(timeIntervalSince1970: created), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
          pixelWidth: 10, pixelHeight: 10, duration: 0, mediaSubtypes: 0, resources: [], cloudIdentity: cloud ? .resolved(cloudID ?? "cloud-" + id) : .unavailable)
}

/// store为测试专用真实SQLite；sources创建匹配的官方旧版本记录，导入时刻固定为100秒。
private func seedContinuity(_ store: SQLiteLibraryIndexStore, sources: [PhotoBackupSource]) async throws {
    let scope = continuityScope()
    try await store.prepare(scope: scope)
    try await store.savePhotoBackupHistory(.init(version: 1, namespace: scope.cacheNamespace, userID: scope.userID, importedAt: Date(timeIntervalSince1970: 100),
                                                 records: sources.map { .init(localID: $0.localID, cloudID: nil, checksum: continuityChecksum, modifiedAt: $0.modifiedAt) }), scope: scope)
}

/// url只能是本例新建路径；生成两行官方最小schema，关闭句柄后交给生产只读Importer。
private nonisolated func makeContinuitySQLite(_ url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw PhotoBackupContinuityError.invalidDatabase }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE auth_user_entity(id TEXT);
    INSERT INTO auth_user_entity VALUES('11111111-1111-4111-8111-111111111111');
    CREATE TABLE local_asset_entity(id TEXT,i_cloud_id TEXT,checksum TEXT,updated_at TEXT);
    INSERT INTO local_asset_entity VALUES('one','cloud-one','\(continuityChecksum)','1970-01-01T00:00:10.000Z');
    INSERT INTO local_asset_entity VALUES('two',NULL,NULL,NULL);
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw PhotoBackupContinuityError.invalidDatabase }
}

/// 只替换Photos元数据；reads仅统计非空请求，确保缓存命中不再重复查询整个手机图库。
@MainActor private final class ContinuityPhotos: LocalPhotoMetadataReading {
    var values: [String: LocalPhotoSnapshot] = [:]
    var reads = 0
    /// ids为本批最多64项；context保留生产代际/取消协议，返回仅存在的合成观察。
    func snapshots(for ids: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext()
        if !ids.isEmpty {
            reads += 1
        }
        return ids.compactMap { values[$0] }
    }
}

/// 只读HTTP边界的确定性替身；真实请求编码与严格响应仍由既有LibraryMutationClient HTTP测试覆盖。
@MainActor private final class ContinuityQueries: PhotoBackupContinuityQuerying {
    var batches: [[PhotoBackupCachedChecksumQuery]] = []
    var missEveryOther = false
    var fails = false
    var incomplete = false
    var associatedCloud: String?
    var onQuery: (@MainActor () -> Void)?
    var records: [LocalMediaRemoteMetadataRecord] = []
    var assets: [String: LocalMediaRemoteAsset] = [:]
    var savedMatches: [UUID: String] = [:]
    var rejectWrites = false
    var matchBatchSizes: [Int] = []
    var onAsset: (@MainActor () -> Void)?
    /// queries逐批记录；可模拟完整未命中、协议缺项或网络失败，不返回任何上传许可。
    @MainActor func lookupBackupChecksums(_ queries: [PhotoBackupCachedChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        if queries.isEmpty {
            return []
        }
        batches.append(queries)
        onQuery?()
        if fails {
            throw URLError(.notConnectedToInternet)
        }
        if incomplete {
            return []
        }
        return queries.enumerated().map { index, query in
            .init(id: query.id, outcome: missEveryOther && index % 2 == 1 ? .noMatch : .existing(UUID()))
        }
    }

    /// cloudIDs是本轮真正新源；返回mobile-app已有关系，或完整空结果，不访问任何媒体。
    @MainActor func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        if !records.isEmpty {
            return records
        }
        guard let associatedCloud else { return [] }
        return [.init(assetID: UUID(), value: Data("{\"iCloudId\":\"\(associatedCloud)\"}".utf8))]
    }

    /// id必须属于合成候选；返回独立详情或明确不可读，不提供媒体。
    @MainActor func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        onAsset?()
        guard let value = assets[id] else { throw LocalMediaCandidateError.inaccessible }
        return value
    }

    /// matches记录待写的真实候选身份；可模拟服务拒绝，以检查未确认写入不会发布已匹配状态。
    @MainActor func recordICloudMatches(_ matches: [UUID: String]) async throws {
        if rejectWrites {
            throw URLError(.cannotConnectToHost)
        }
        matchBatchSizes.append(matches.count)
        savedMatches.merge(matches) { _, new in new }
    }
}

/// 记录任何违规导出；此组测试所有源都应在Worker进入原片前被跳过或转待核查。
@MainActor private final class ContinuityNoExport: PhotoBackupResourceExporting {
    var calls = 0
    /// source/allowCloud均不应使用；出现调用立即失败，不创建媒体文件。
    func export(_: PhotoBackupSource, allowCloud _: Bool) async throws -> PhotoBackupResources {
        calls += 1; throw PhotoBackupExportError(reason: .unconfirmedResponse)
    }
}

/// Worker跳过测试的最后一道观测；任何上传或fresh GET都代表预核查未在导出前阻断。
private nonisolated struct ContinuityNoUpload: PhotoBackupUploading {
    /// 所有上传参数都禁止使用；测试不允许向任何网络提交媒体。
    func upload(file _: URL, filename _: String, created _: Date, modified _: Date, favorite _: Bool, hidden _: Bool, livePhotoVideoID _: String?) async throws -> LibraryMutationClient.UploadResult {
        Issue.record("Unexpected original upload"); throw PhotoBackupContinuityError.incompleteResponse
    }

    /// id不应被读取；跳过已有项目不能伪造新的原片回执。
    func asset(_: String) async throws -> ManagedAsset {
        Issue.record("Unexpected asset read"); throw PhotoBackupContinuityError.incompleteResponse
    }
}
