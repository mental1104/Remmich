import Foundation
import SQLite3
import Testing
@testable import Remmich

/// 接续链路使用真实SQLite、生产Importer/Checker/Worker；只替换Photos观察与只读网络端口，禁止访问生产媒体。
@Suite("Backup continuity before original export")
struct PhotoBackupContinuityTests {
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
        #expect(index.query(for: continuitySource("other-phone"), cloudID: "cloud-1") != nil)
        #expect(index.query(for: continuitySource("missing")) == nil)
    }

    /// 无导入记录必须在Photos/HTTP及Exporter之前失败，不能把既有服务器图库视作空库重新上传。
    @Test @MainActor func requiresImportBeforeAnyReadOrExport() async throws {
        let root = continuityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let photos = ContinuityPhotos(), client = ContinuityQueries()
        let checker = PhotoBackupContinuityChecker(store: store, metadata: photos)
        await #expect(throws: PhotoBackupContinuityError.importRequired) {
            try await checker.plan(jobs: [.init(source: continuitySource("old"))], scope: continuityScope(), client: client, progress: { _, _ in }, validateContext: {})
        }
        #expect(photos.reads == 0 && client.batches.isEmpty)
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
        #expect(exporter.calls == 0 && result.completed == 0)
        #expect(cold.jobs.count { $0.stage == .paused } == 65 && cold.jobs.count { $0.failure == .historyUnconfirmed } == 65)
        #expect(cold.jobs.allSatisfy { $0.attempts == 0 && $0.primaryAssetID == nil })
        #expect(try await store.loadPhotoBackupHistory(scope: continuityScope(other: true)) == nil)
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

/// 构造完整公开元数据观察；cloud=false模拟系统无法解析云标识，不能猜测成新项目。
private nonisolated func continuitySnapshot(_ id: String, created: TimeInterval, cloud: Bool) -> LocalPhotoSnapshot {
    .init(identity: .init(localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 200), mediaKind: .image),
          creationDate: Date(timeIntervalSince1970: created), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
          pixelWidth: 10, pixelHeight: 10, duration: 0, mediaSubtypes: 0, resources: [], cloudIdentity: cloud ? .resolved("cloud-" + id) : .unavailable)
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
    /// queries逐批记录；可模拟完整未命中、协议缺项或网络失败，不返回任何上传许可。
    func lookupBackupChecksums(_ queries: [PhotoBackupCachedChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        if queries.isEmpty {
            return []
        }
        batches.append(queries)
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
    func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        guard let associatedCloud else { return [] }
        return [.init(assetID: UUID(), value: Data("{\"iCloudId\":\"\(associatedCloud)\"}".utf8))]
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
