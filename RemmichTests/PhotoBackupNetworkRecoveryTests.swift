import Foundation
import Photos
import Synchronization
import Testing
@testable import Remmich

/// 网络恢复必须经过真实Controller/Worker/SQLite与私有URLSession；只替代PhotoKit字节及HTTP对端。
@Suite("Foreground backup network recovery")
struct PhotoBackupNetworkRecoveryTests {
    /// 旧格式缺省独立同意为关闭；Header可往返且不改包含/排除/iCloud/后台规则。
    @Test func independentConsentRoundTripsWithoutExpandingSavedRules() throws {
        let legacy = try JSONDecoder().decode(PhotoBackupJournal.Header.self, from: Data(#"{"version":1,"namespace":"synthetic","selectedAlbumIDs":[],"allowCloud":false}"#.utf8))
        #expect(legacy.foregroundNetworkRecoveryEnabled == nil)
        var journal = PhotoBackupJournal(namespace: "synthetic")
        #expect(throws: PhotoBackupStateError.self) { try journal.setForegroundNetworkRecoveryEnabled(true) }
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        try journal.applyAlbumScan(selection.scan([.init(id: "include", assets: []), .init(id: "exclude", assets: [])]), allowCloud: true)
        try journal.setForegroundNetworkRecoveryEnabled(true)
        let restored = try JSONDecoder().decode(PhotoBackupJournal.Header.self, from: JSONEncoder().encode(journal.header))
        try restored.validate(namespace: "synthetic")
        #expect(restored.foregroundNetworkRecoveryEnabled == true && restored.allowCloud)
        #expect(restored.foregroundAutomaticEnabled == nil && restored.backgroundAutomaticEnabled == nil)
        #expect(restored.selectedAlbumIDs == ["include"] && restored.excludedAlbumIDs == ["exclude"])
    }

    /// 未知POST已由对端接收但超时；冷恢复必须重新导出→SHA1查重→fresh配对确认，绝不直接第二次POST原片。
    @Test(arguments: [false, true])
    @MainActor func acceptedButTimedOutUploadIsVerifiedAfterColdRecovery(_ live: Bool) async throws {
        let fixture = try await NetworkRecoveryFixture(live: live, recovery: true, failure: nil)
        defer { fixture.removeFiles() }
        await fixture.activate()
        let partial = try await fixture.coldJournal()
        let failed = try #require(partial.jobs.first)
        #expect(failed.stage == .failed && failed.failure == .network && failed.attempts == 1 && failed.primaryAssetID == nil)
        #expect(failed.motionAssetID == (live ? UUID(uuidString: recoveryMotionID) : nil))
        #expect(partial.foregroundAutomaticEnabled == true && partial.foregroundNetworkRecoveryEnabled == true)
        #expect(fixture.server.counts.upload == 1)
        #expect(fixture.controller.automaticLibraryChanged() == nil)
        await fixture.retire()

        // 全新SQLite实例与Controller读取真实持久资料；启动本身不恢复失败任务。
        let coldStore = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let coldExporter = NetworkRecoveryExporter(root: fixture.root.appending(path: "cold-exports"), store: coldStore, scope: fixture.scope)
        let controller = fixture.makeController(store: coldStore, exporter: coldExporter)
        await controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: true)?.value
        #expect(coldExporter.reads.isEmpty && fixture.server.counts.upload == 1)
        let event = UUID()
        let retry = try #require(controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event))
        await retry.value
        let completed = try await coldStore.loadPhotoBackups(scope: fixture.scope)
        #expect(completed.jobs.first?.stage == .completed && completed.jobs.first?.attempts == 2)
        #expect(completed.jobs.first?.primaryWasDuplicate == true && completed.jobs.first?.primaryChecksum == recoveryPhotoBase64)
        #expect(completed.jobs.first?.motionAssetID == (live ? UUID(uuidString: recoveryMotionID) : nil))
        #expect(coldExporter.reads == [true] && fixture.server.counts.upload == 1)
        #expect(fixture.server.counts.check == (live ? 4 : 2) && fixture.server.counts.fresh == (live ? 2 : 1))
        #expect(controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) == nil)
        #expect(fixture.server.counts.upload == 1 && !controller.running)
        await controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: false)?.value
        await fixture.close()
    }

    /// 新连接仍失败只做一次；同token和普通Photos通知不构成重试循环，下一新token才可再核一次。
    @Test @MainActor func eachValidatedNetworkEventAllowsOnlyOneFailedRound() async throws {
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: true, failure: .cannotConnectToHost)
        defer { fixture.removeFiles() }
        await fixture.activate()
        #expect(fixture.server.counts.check == 1 && fixture.controller.foregroundAutomaticEnabled)
        let event = UUID()
        let retry = try #require(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event))
        await retry.value
        #expect(fixture.server.counts.check == 2 && fixture.exporter.reads.count == 2)
        #expect(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) == nil)
        #expect(fixture.controller.automaticLibraryChanged() == nil && fixture.server.counts.check == 2)
        let next = try #require(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: UUID()))
        await next.value
        #expect(fixture.server.counts.check == 3 && fixture.exporter.reads.count == 3 && fixture.server.counts.upload == 0)
        await fixture.close()
    }

    /// 用户在实际设置入口明确同意只写头；已有失败不因开关立即重试，仍须新的验证事件。
    @Test @MainActor func enablingTheSeparateOptionDoesNotImmediatelyReplayFailures() async throws {
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: false, failure: .cannotConnectToHost)
        defer { fixture.removeFiles() }
        await fixture.activate()
        #expect(!fixture.controller.foregroundAutomaticEnabled && !fixture.controller.foregroundNetworkRecoveryEnabled)
        await fixture.controller.setForegroundAutomaticEnabled(true, using: fixture.manager)
        await fixture.controller.automaticLibraryChanged()?.value
        await fixture.controller.setForegroundNetworkRecoveryEnabled(true, using: fixture.manager)
        await fixture.controller.automaticLibraryChanged()?.value
        let consent = try await fixture.coldJournal()
        #expect(consent.foregroundAutomaticEnabled == true && consent.foregroundNetworkRecoveryEnabled == true)
        #expect(consent.jobs.first?.stage == .failed && fixture.server.counts.check == 1)
        let retry = try #require(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: UUID()))
        await retry.value
        #expect(fixture.server.counts.check == 2 && fixture.controller.foregroundAutomaticEnabled)
        await fixture.close()
    }

    /// 旧HTTP已在途而新路由验证到达；释放旧失败后新token必须恰好核查一次，不被旧轮清空也不重放同token。
    @Test(.timeLimit(.minutes(1))) @MainActor func aNewNetworkEventSurvivesThePreviousHeldHTTPFailure() async throws {
        let gate = NetworkRecoveryHTTPGate()
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: true, failure: .cannotConnectToHost, gate: gate)
        do {
            let initial = try #require(fixture.controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: true))
            let completion = Task { await initial.value; await gate.operationFinished() }
            let arrived = await gate.waitUntilHeld()
            if !arrived {
                Issue.record("Initial HTTP request did not reach the held response.")
                await gate.release(); await completion.value
            } else {
                let event = UUID()
                #expect(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) != nil)
                #expect(fixture.controller.lastValidatedNetworkRecoveryEvent == event)
                await gate.release(); await completion.value; await gate.waitForResponseExit()
                let saved = try await fixture.coldJournal()
                #expect(saved.jobs.first?.attempts == 2 && saved.jobs.first?.failure == .network)
                #expect(fixture.server.counts.check == 2 && fixture.exporter.reads.count == 2 && fixture.server.counts.upload == 0)
                #expect(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) == nil)
                #expect(fixture.controller.automaticLibraryChanged() == nil && fixture.server.counts.check == 2)
            }
        } catch {
            await gate.release(); await fixture.close(); fixture.removeFiles(); throw error
        }
        await fixture.close(); fixture.removeFiles()
    }

    /// 路由已在App前台确认而scene尚inactive时不上传；同上下文active后消费一次，旧inactive周期不能抢走事件。
    @Test @MainActor func aValidatedForegroundEventWaitsForTheOriginalSceneToBecomeActive() async throws {
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: true, failure: .cannotConnectToHost)
        defer { fixture.removeFiles() }
        await fixture.activate(); await fixture.retire()
        let event = UUID()
        #expect(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) == nil)
        #expect(fixture.server.counts.check == 1 && !fixture.controller.running)
        await fixture.activate()
        #expect(fixture.server.counts.check == 2 && fixture.controller.lastValidatedNetworkRecoveryEvent == event)
        #expect(fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: event) == nil)
        await fixture.close()
    }

    /// 默认off、权限、未扫描草稿和源版本变化均不允许自动恢复旧失败；回执/保存规则保持原样。
    @Test(arguments: ["disabled", "permission", "draft", "source-changed", "endpoint", "account"])
    @MainActor func blockedRecoveryCannotSendMoreMedia(_ reason: String) async throws {
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: reason != "disabled", failure: .networkConnectionLost)
        defer { fixture.removeFiles() }
        await fixture.activate()
        if reason == "permission" {
            fixture.port.authorization = .denied
        }
        if reason == "draft" {
            fixture.controller.excluded.insert("unsaved")
        }
        if reason == "source-changed" {
            fixture.port.source = .init(localID: "synthetic", modifiedAt: Date(timeIntervalSince1970: 2), kind: .photo)
        }
        if reason == "endpoint" || reason == "account" {
            let session = reason == "account" ? checksumLookupSession(endpoint: fixture.endpoint, user: "44444444-4444-4444-8444-444444444444", token: "network-recovery") : fixture.session
            fixture.manager.configure(session: session, endpoint: reason == "endpoint" ? fixture.endpoint.appending(path: "other") : fixture.endpoint)
        }
        if let retry = fixture.controller.networkRouteValidated(using: fixture.manager, scope: fixture.scope, eventID: UUID()) {
            await retry.value
        }
        let saved = try await fixture.coldJournal()
        #expect(saved.jobs.first?.stage == .failed && saved.jobs.first?.attempts == 1)
        #expect(saved.allowCloud && saved.selectedAlbumIDs == ["include"] && saved.excludedAlbumIDs == ["exclude"])
        #expect(fixture.server.counts.check == 1 && fixture.server.counts.upload == 0 && fixture.exporter.reads.count == 1)
        await fixture.close()
    }

    /// 真实HTTP错误分类只允许已知短暂连接重核；TLS/认证/取消/无效URL/文件错误保持人工核查，不自动重排。
    @Test(arguments: [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
                      .secureConnectionFailed, .serverCertificateUntrusted, .userAuthenticationRequired, .cancelled, .badURL, .fileDoesNotExist])
    @MainActor func permanentTransportErrorsDoNotKeepAutomaticRetryEnabled(_ code: URLError.Code) async throws {
        let fixture = try await NetworkRecoveryFixture(live: false, recovery: true, failure: code)
        defer { fixture.removeFiles() }
        await fixture.activate()
        let temporary: Set<URLError.Code> = [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet]
        let saved = try await fixture.coldJournal()
        #expect((saved.jobs.first?.failure == .network) == temporary.contains(code))
        #expect(fixture.controller.foregroundAutomaticEnabled == temporary.contains(code))
        #expect(saved.foregroundAutomaticEnabled == temporary.contains(code))
        #expect(fixture.server.counts.check == 1 && fixture.server.counts.upload == 0)
        await fixture.close()
    }

    /// 已取消/永久失败/未知暂停/源变化/无修改版本均保持原状态；独立同意不变成通用失败恢复。
    @Test(arguments: ["cancelled", "permission", "unknown", "version", "missing-version"])
    func journalNeverRequeuesUnsafeHistory(_ reason: String) throws {
        let source = PhotoBackupSource(localID: "synthetic", modifiedAt: reason == "missing-version" ? nil : Date(timeIntervalSince1970: 1), kind: .livePhoto)
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: [])
        var journal = PhotoBackupJournal(namespace: "synthetic")
        let scan = try selection.scan([.init(id: "include", assets: [.init(source: source, capturedAt: nil)])])
        try journal.applyAlbumScan(scan, allowCloud: false)
        try journal.setForegroundAutomaticEnabled(true); try journal.setForegroundNetworkRecoveryEnabled(true)
        let id = try #require(journal.jobs.first?.id)
        let motion = UUID()
        try journal.update(id) { job in
            try job.begin(); try job.exported(); try job.recordMotion(motion)
            switch reason { case "cancelled": job.cancel(); case "permission": job.fail(.permission); case "unknown": job.pause(); default: job.fail(.network) }
        }
        let actual: PhotoBackupAlbumScan
        if reason == "version" {
            let changed = PhotoBackupSource(localID: source.localID, modifiedAt: Date(timeIntervalSince1970: 2), kind: .livePhoto)
            actual = try selection.scan([.init(id: "include", assets: [.init(source: changed, capturedAt: nil)])])
        } else {
            actual = scan
        }
        let stage = journal.jobs.first?.stage
        #expect(try journal.resumeNetworkFailures(actual) == 0)
        #expect(journal.jobs.first?.stage == stage && journal.jobs.first?.motionAssetID == motion)
    }
}

private nonisolated let recoveryPhotoHex = "f0dfc36a29e0f039816e54ddb59e0c7fc202c11c"
private nonisolated let recoveryPhotoBase64 = "8N/Daing8DmBblTdtZ4Mf8ICwRw="
private nonisolated let recoveryMotionHex = "2a44d7c7b4f8d547068091c153841d25772cbbd6"
private nonisolated let recoveryMotionBase64 = "KkTXx7T41UcGgJHBU4QdJXcsu9Y="
private nonisolated let recoveryPrimaryID = "22222222-2222-4222-8222-222222222222"
private nonisolated let recoveryMotionID = "33333333-3333-4333-8333-333333333333"

/// 只提供已授权相簿/源元数据；不访问真实Photos或更改保存选择。
@MainActor private final class NetworkRecoveryPhotoPort {
    var authorization = PHAuthorizationStatus.authorized
    var source: PhotoBackupSource
    /// live选择合成资源种类；稳定修改版本用于真实领域比较。
    init(live: Bool) {
        source = .init(localID: "synthetic", modifiedAt: Date(timeIntervalSince1970: 1), kind: live ? .livePhoto : .photo)
    }

    /// ids必须等于保存的并集；源始终属于include，exclude存在但为空。
    func scan(_ ids: Set<String>) throws -> [PhotoBackupAlbumSnapshot] {
        guard ids == ["include", "exclude"] else { throw PhotoBackupStateError.invalidJournal }
        return [.init(id: "include", assets: [.init(source: source, capturedAt: nil)]), .init(id: "exclude", assets: [])]
    }
}

/// 仅替代PhotoKit导出，真实读取begin持久检查点并生成临时合成字节；不写任何完成状态。
@MainActor private final class NetworkRecoveryExporter: PhotoBackupResourceExporting {
    let root: URL
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    private(set) var reads: [Bool] = []
    /// root只属于本例，store/scope读取实际Worker检查点，完全不操作私人媒体。
    init(root: URL, store: SQLiteLibraryIndexStore, scope: MediaAccountScope) {
        self.root = root; self.store = store; self.scope = scope
    }

    /// source来自真实扫描，allowCloud须保持保存意愿；返回Worker自行清理的文件，不模拟HTTP回执。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        let saved = try await store.loadPhotoBackups(scope: scope)
        try Task.checkCancellation()
        let job = try #require(saved.jobs.first { $0.source == source })
        #expect(job.stage == .exporting && job.attempts > 0)
        reads.append(allowCloud)
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appending(path: "synthetic.jpg")
        try Data("foreground automatic synthetic photo\n".utf8).write(to: photo)
        var motion: PhotoBackupResources.File?
        if source.kind == .livePhoto {
            let file = directory.appending(path: "synthetic.mov")
            try Data("network recovery synthetic motion\n".utf8).write(to: file)
            motion = .init(file: file, name: "synthetic.mov")
        }
        return .init(directory: directory, primary: .init(file: photo, name: "synthetic.jpg"), motion: motion,
                     created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 1), favorite: false)
    }
}

/// 每例真实SQLite和私有URLSession，初始任务只由保存规则扫描创建，失败/完成由真实Worker产生。
@MainActor private final class NetworkRecoveryFixture {
    let root: URL
    let database: URL
    let endpoint: URL
    let session: AccountSession
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let manager: LibraryManagementController
    let port: NetworkRecoveryPhotoPort
    let exporter: NetworkRecoveryExporter
    let controller: PhotoBackupController
    let server: NetworkRecoveryHTTPServer
    /// live选择资源种类，recovery为独立此前同意；failure为固定传输错误，nil先接收上传再超时，gate仅为首个HTTP并发门。
    init(live: Bool, recovery: Bool, failure: URLError.Code?, gate: NetworkRecoveryHTTPGate? = nil) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupNetwork-\(UUID())", directoryHint: .isDirectory)
        let database = root.appending(path: "index.sqlite")
        let endpoint = URL(string: "https://backup-network-\(UUID().uuidString.lowercased()).invalid/api")!
        let session = checksumLookupSession(endpoint: endpoint, token: "network-recovery")
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        let port = NetworkRecoveryPhotoPort(live: live)
        let exporter = NetworkRecoveryExporter(root: root.appending(path: "exports"), store: store, scope: scope)
        let server = NetworkRecoveryHTTPServer(endpoint: endpoint, live: live, failure: failure, gate: gate)
        let manager = LibraryManagementController(configurationFactory: {
            let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [NetworkRecoveryURLProtocol.self]; return value
        })
        manager.configure(session: session, endpoint: endpoint)
        let controller = PhotoBackupController(store: store, exporter: exporter, albumScanner: { try port.scan($0) },
                                               authorizationStatus: { port.authorization }, observeAutomaticPhotos: false)
        self.root = root; self.database = database; self.endpoint = endpoint; self.session = session; self.scope = scope
        self.store = store; self.port = port; self.exporter = exporter; self.server = server; self.manager = manager; self.controller = controller
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        try journal.applyAlbumScan(selection.scan(port.scan(["include", "exclude"])), allowCloud: true)
        try journal.setForegroundAutomaticEnabled(true); try journal.setForegroundNetworkRecoveryEnabled(recovery)
        do {
            try await store.prepare(scope: scope); try await store.savePhotoBackups(journal, scope: scope)
        } catch {
            manager.configure(session: nil, endpoint: nil)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        NetworkRecoveryURLProtocol.install(server)
    }

    /// 原生命周期入口启动有限一次，调用者等待真实Worker结束。
    func activate() async {
        await controller.automaticConditionsChanged(using: manager, scope: scope, active: true)?.value
    }

    /// 新实例仅读取真实磁盘恢复资料，不通过原Controller内存判断状态。
    func coldJournal() async throws -> PhotoBackupJournal {
        try await SQLiteLibraryIndexStore(databaseURL: database).loadPhotoBackups(scope: scope)
    }

    /// store/exporter为冷恢复依赖，沿用同保存相簿/权限adapter，不访问系统Photos。
    func makeController(store: SQLiteLibraryIndexStore, exporter: NetworkRecoveryExporter) -> PhotoBackupController {
        let port = port
        return .init(store: store, exporter: exporter, albumScanner: { try port.scan($0) }, authorizationStatus: { port.authorization }, observeAutomaticPhotos: false)
    }

    /// 等待原自动生命周期退役，不改用户同意或已持久回执。
    func retire() async {
        await controller.automaticConditionsChanged(using: manager, scope: scope, active: false)?.value
    }

    /// 先停任务后关闭本例私有会话；不删除结果以外任何媒体。
    func close() async {
        await retire(); manager.configure(session: nil, endpoint: nil); NetworkRecoveryURLProtocol.remove(endpoint)
    }

    /// 只清理本例随机临时目录；正常关闭在此前等待真实任务退役。
    func removeFiles() {
        controller.cancel()
        NetworkRecoveryURLProtocol.remove(endpoint); manager.configure(session: nil, endpoint: nil); try? FileManager.default.removeItem(at: root)
    }
}

/// 只响应合成查重/上传/fresh详情；timeout模式记录真实POST已到达，再给URLSession传输错误。
private final nonisolated class NetworkRecoveryHTTPServer: Sendable {
    struct Counts: Sendable { var check = 0; var upload = 0; var fresh = 0; var committed = false }
    let endpoint: URL
    let live: Bool
    let failure: URLError.Code?
    let gate: NetworkRecoveryHTTPGate?
    private let state = Mutex(Counts())
    var counts: Counts {
        state.withLock { $0 }
    }

    /// endpoint为唯一.invalid根，live决定fresh配对；failure不替换生产分类，gate默认nil保留同步有限响应。
    init(endpoint: URL, live: Bool, failure: URLError.Code?, gate: NetworkRecoveryHTTPGate? = nil) {
        self.endpoint = endpoint; self.live = live; self.failure = failure; self.gate = gate
    }

    /// request为真实客户端请求；未知路径/身份失败，不提供任何真实网络后备。
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer network-recovery", let url = request.url else { throw URLError(.userAuthenticationRequired) }
        if request.httpMethod == "POST", url == endpoint.appending(path: "assets/bulk-upload-check") {
            state.withLock { $0.check += 1 }
            if let failure {
                throw URLError(failure)
            }
            struct Check: Decodable { struct Item: Decodable { let id: String; let checksum: String }; let assets: [Item] }
            let check = try JSONDecoder().decode(Check.self, from: networkRecoveryBody(request))
            guard check.assets.count == 1, let item = check.assets.first, UUID(uuidString: item.id) != nil else { throw URLError(.badServerResponse) }
            let primary = item.checksum == recoveryPhotoHex
            guard primary || (live && item.checksum == recoveryMotionHex) else { throw URLError(.cannotDecodeContentData) }
            let duplicate = !primary || state.withLock { $0.committed }
            let id = primary ? recoveryPrimaryID : recoveryMotionID
            let result = duplicate ? #"{"results":[{"id":"\#(item.id)","action":"reject","assetId":"\#(id)","isTrashed":false}]}"#
                : #"{"results":[{"id":"\#(item.id)","action":"accept"}]}"#
            return (200, Data(result.utf8))
        }
        if request.httpMethod == "POST", url == endpoint.appending(path: "assets") {
            guard request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true else { throw URLError(.cannotDecodeContentData) }
            state.withLock { $0.upload += 1; $0.committed = true }
            throw URLError(.timedOut)
        }
        if request.httpMethod == "GET", url == endpoint.appending(path: "assets/\(recoveryPrimaryID)") || url == endpoint.appending(path: "assets/\(recoveryMotionID)") {
            state.withLock { $0.fresh += 1 }
            let motion = url.lastPathComponent == recoveryMotionID
            let id = motion ? recoveryMotionID : recoveryPrimaryID
            let pair = live && !motion ? #""\#(recoveryMotionID)""# : "null"
            let type = motion ? "VIDEO" : "IMAGE"
            let checksum = motion ? recoveryMotionBase64 : recoveryPhotoBase64
            return (200, Data(#"{"id":"\#(id)","ownerId":"99999999-9999-4999-8999-999999999999","type":"\#(type)","isTrashed":false,"isFavorite":false,"visibility":"timeline","originalFileName":"synthetic","livePhotoVideoId":\#(pair),"checksum":"\#(checksum)","isOffline":false,"exifInfo":null}"#.utf8))
        }
        throw URLError(.unsupportedURL)
    }
}

/// 仅本例URLSession使用，Mutex保护本类私有host表，不注册全局协议、不接其他测试或外网。
private final nonisolated class NetworkRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: NetworkRecoveryHTTPServer]>([:])
    private let stopped = Mutex(false)
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    /// server拥有唯一host；同步安装不启动网络或任务。
    static func install(_ server: NetworkRecoveryHTTPServer) {
        servers.withLock { $0[server.endpoint.host!] = server }
    }

    /// endpoint仅删除本例注册，不触碰其他并行会话。
    static func remove(_ endpoint: URL) {
        _ = servers.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 本会话拦截所有请求，未知host也失败而非外发。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// request保留原路径/正文，交真实LibraryMutationClient构造。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 默认同步有限响应；显式gate使用可取消实际Task等待响应门，取消后不发布成功。
    override func startLoading() {
        if let host = request.url?.host, let server = Self.servers.withLock({ $0[host] }), let gate = server.gate {
            let request = request
            let task = Task { [self] in
                var held = false
                do {
                    try Task.checkCancellation(); held = await gate.beforeResponse(); try Task.checkCancellation()
                    let (status, data) = try server.reply(request)
                    deliver(status: status, data: data, url: request.url!)
                } catch {
                    if !stopped.withLock({ $0 }) {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
                if held {
                    await gate.responseExited()
                }
            }
            loadingTask.withLock { $0 = task }
            if stopped.withLock({ $0 }) {
                task.cancel()
            }
            return
        }
        do {
            guard let url = request.url, let server = Self.servers.withLock({ $0[url.host ?? ""] }) else { throw URLError(.unsupportedURL) }
            let (status, data) = try server.reply(request)
            deliver(status: status, data: data, url: url)
        } catch {
            if !stopped.withLock({ $0 }) {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    /// 只停止本响应，不触碰生产URLSession或其他fixture。
    override func stopLoading() {
        stopped.withLock { $0 = true }
        loadingTask.withLock { $0 }?.cancel()
    }

    /// status/data只来自本例有限HTTP对端，url为原请求；取消后不发布成功。
    private func deliver(status: Int, data: Data, url: URL) {
        guard !stopped.withLock({ $0 }), let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

/// 只暂停首个真实URLProtocol响应；提前取消/业务结束会解除观察门，不用sleep制造并发次序。
private actor NetworkRecoveryHTTPGate {
    private var used = false
    private var released = false
    private var exited = false
    private var finished = false
    private var response: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var exitObserver: CheckedContinuation<Void, Never>?
    /// 首次请求发布已进入并等待明确释放，返回true供同一响应报告退出；后续返回false，真实取消释放首门。
    func beforeResponse() async -> Bool {
        guard !used else { return false }
        used = true; observer?.resume(returning: true); observer = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled {
                    continuation.resume()
                } else {
                    response = continuation
                }
            }
        } onCancel: { Task { await self.release() } }
        return true
    }

    /// 返回真实已入场或提前完成；不把经过时间当作HTTP已开始。
    func waitUntilHeld() async -> Bool {
        if used {
            return true
        }; if finished {
            return false
        }
        return await withCheckedContinuation { observer = $0 }
    }

    /// 明确释放本响应；支持测试错误/取消路径的重复清理。
    func release() {
        released = true; response?.resume(); response = nil
    }

    /// 业务实际结束时解除尚未达到的观察门。
    func operationFinished() {
        finished = true; if !used {
            observer?.resume(returning: false); observer = nil
        }
    }

    /// 实际响应Task退出后才发布，防止业务完成早于URLProtocol真正退休。
    func responseExited() {
        exited = true; exitObserver?.resume(); exitObserver = nil
    }

    /// 等待实际响应退出；早期业务失败没有响应时不留下不可达等待。
    func waitForResponseExit() async {
        if exited || !used {
            return
        }; await withCheckedContinuation { exitObserver = $0 }
    }
}

/// request来自真实URLSession，读取有限JSON体；不解析大multipart或把原片载入内存。
private nonisolated func networkRecoveryBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody {
        return data
    }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeRawData) }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
        if count == 0 {
            return result
        }
        result.append(contentsOf: buffer.prefix(count))
        guard result.count < 65536 else { throw URLError(.dataLengthExceedsMaximum) }
    }
}
