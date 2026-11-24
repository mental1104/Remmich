import Foundation
import Testing
@testable import Remmich

/// 真实Controller的相簿读取/显式选择恢复边界；仅替换PhotoKit枚举来源，数据库与队列实现不替换。
@Suite("Unavailable backup album selection recovery")
@MainActor struct PhotoBackupAlbumRecoveryTests {
    /// 初始albums为空表示尚未读取；即使恢复选择不在数组里，也不能提前判断丢失或抹除规则。
    @Test func initialEmptyCatalogCannotRemoveSavedSelections() {
        let controller = PhotoBackupController(albumLoader: { .init(albums: [], limited: false) })
        controller.selected = ["included"]
        controller.excluded = ["excluded"]
        #expect(!controller.hasLoadedAlbums && controller.unavailableAlbumIDs.isEmpty)
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == ["included"] && controller.excluded == ["excluded"])
        #expect(!controller.requiresSelectionScan)
    }

    /// 成功空列表和有内容列表都能明确报告缺项；只有按钮会更改选择，包含/排除的可用项和重叠保持不变。
    @Test(arguments: [false, true])
    func successfulCatalogRequiresExplicitRemoval(_ empty: Bool) async {
        let controller = PhotoBackupController(albumLoader: {
            .init(albums: empty ? [] : [.init(id: "keep", title: "Synthetic")], limited: true)
        })
        controller.selected = ["keep", "missing-included"]
        controller.excluded = ["keep", "missing-excluded"]
        await controller.loadAlbums()
        let missing: Set<String> = empty ? ["keep", "missing-included", "missing-excluded"] : ["missing-included", "missing-excluded"]
        let kept: Set<String> = empty ? [] : ["keep"]
        #expect(controller.hasLoadedAlbums && !controller.loadingAlbums)
        #expect(controller.unavailableAlbumIDs == missing)
        #expect(controller.selected == ["keep", "missing-included"] && controller.excluded == ["keep", "missing-excluded"])
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == kept && controller.excluded == kept)
        #expect(controller.requiresSelectionScan && controller.unavailableAlbumIDs.isEmpty)
        await controller.loadAlbums()
        #expect(controller.requiresSelectionScan)
    }

    /// 已有成功列表也不能让后来的权限/枚举/网络/取消失败被误认为成功空列表；失败后不允许移除保存选择。
    @Test(arguments: ["permission", "invalid", "network", "cancelled"])
    func failedRereadCannotClassifyOrRemoveSelections(_ mode: String) async {
        let loader = BackupAlbumCatalogFixture()
        let controller = PhotoBackupController(albumLoader: { try loader.read() })
        controller.selected = ["keep", "missing"]
        controller.excluded = ["excluded"]
        await controller.loadAlbums()
        #expect(controller.hasLoadedAlbums && controller.unavailableAlbumIDs == ["missing", "excluded"])
        loader.failure = switch mode {
        case "permission": PhotoBackupController.AlbumReadError.permission
        case "invalid": PhotoBackupController.AlbumReadError.invalidCatalog
        case "network": URLError(.notConnectedToInternet)
        default: CancellationError()
        }
        await controller.loadAlbums()
        #expect(!controller.hasLoadedAlbums && controller.unavailableAlbumIDs.isEmpty)
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == ["keep", "missing"] && controller.excluded == ["excluded"])
        #expect(!controller.requiresSelectionScan)
    }

    /// 移除只改本页草稿：实际SQLite头/任务/部分Live Photo回执不变，恢复/单项重试都不能绕过新扫描门禁。
    /// 随后显式取消旧任务仍可保存取消状态，但不得恢复旧配置覆盖草稿或解除扫描要求。
    @Test func removalDoesNotPersistOrResumeAndCancellationKeepsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupAlbumRecovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-album-recovery-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let session = AccountSession(apiURL: endpoint, accessToken: "synthetic", userID: "synthetic-owner",
                                     userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session)
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: scope)
        let source = PhotoBackupSource(localID: "synthetic-live", modifiedAt: nil, kind: .livePhoto)
        let selection = try PhotoBackupAlbumSelection(included: ["keep", "missing-included"], excluded: ["missing-excluded"])
        let scan = try selection.scan([
            .init(id: "keep", assets: [.init(source: source, capturedAt: .distantPast)]),
            .init(id: "missing-included", assets: []), .init(id: "missing-excluded", assets: []),
        ])
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.applyAlbumScan(scan, allowCloud: true)
        let id = try #require(journal.jobs.first?.id)
        let motionID = UUID()
        try journal.update(id) { job in try job.begin(); try job.exported(); try job.recordMotion(motionID); job.pause() }
        try await store.savePhotoBackups(journal, scope: scope)
        let exporter = UnexpectedBackupAlbumExporter()
        let manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BackupAlbumNoNetworkProtocol.self]
            return configuration
        })
        manager.configure(session: session, endpoint: endpoint)
        let controller = PhotoBackupController(store: SQLiteLibraryIndexStore(databaseURL: database), exporter: exporter,
                                               albumLoader: { .init(albums: [.init(id: "keep", title: "Synthetic")], limited: false) })
        await controller.load(using: manager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let loaded = try await store.loadPhotoBackups(scope: scope)
        let before = try encoder.encode(loaded)
        await controller.loadAlbums()
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == ["keep"] && controller.excluded.isEmpty && controller.requiresSelectionScan)
        #expect(controller.jobs.first?.motionAssetID == motionID && controller.jobs.first?.stage == .paused)
        for single in [false, true] {
            let run = controller.resume(using: manager, jobID: single ? id : nil)
            #expect(run == nil)
            await run?.value
        }
        #expect(exporter.calls == 0 && !controller.running)
        let afterRemoval = try await store.loadPhotoBackups(scope: scope)
        #expect(try encoder.encode(afterRemoval) == before)

        // 取消是用户另一次明确操作；保留恢复资料里的原规则，页面草稿仍必须经新的成功扫描才能替换它。
        controller.cancelJob(id, using: manager)
        try await waitUntil { !controller.running }
        let cancelled = try await store.loadPhotoBackups(scope: scope)
        #expect(cancelled.jobs.first?.stage == .cancelled && cancelled.jobs.first?.motionAssetID == motionID)
        #expect(cancelled.selectedAlbumIDs == ["keep", "missing-included"] && cancelled.excludedAlbumIDs == ["missing-excluded"])
        #expect(controller.selected == ["keep"] && controller.excluded.isEmpty && controller.requiresSelectionScan)
    }

    /// condition观察当前Controller任务是否退役；有界等待只保护回归卡死，不靠固定sleep推测业务顺序。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Backup album recovery task did not retire")
    }
}

/// 读取来源替身只返回有限合成相簿或明确失败，不修改Controller选择、日志或队列。
@MainActor private final class BackupAlbumCatalogFixture {
    var failure: (any Error)?

    /// 成功默认提供一个可用ID；failure非nil时直接抛错，模拟先成功后读取失败的真实发布边界。
    func read() throws -> PhotoBackupController.AlbumCatalog {
        if let failure {
            throw failure
        }
        return .init(albums: [.init(id: "keep", title: "Synthetic")], limited: false)
    }
}

/// 门禁回归时也不访问PhotoKit或网络；任何意外进入实际worker都记录并在上传前明确失败。
@MainActor private final class UnexpectedBackupAlbumExporter: PhotoBackupResourceExporting {
    private(set) var calls = 0

    /// source/allowCloud不读取，仅证明未获新扫描确认的Controller不能启动任何媒体导出。
    func export(_: PhotoBackupSource, allowCloud _: Bool) async throws -> PhotoBackupResources {
        calls += 1
        throw PhotoBackupExportError(reason: .unavailable)
    }
}

/// 即使恢复门禁回归也拦截配置会话的全部请求，不允许合成host出网；意外请求直接使测试失败。
private final nonisolated class BackupAlbumNoNetworkProtocol: URLProtocol, @unchecked Sendable {
    /// 所有本会话请求都拦截，未识别URL也没有真实网络回退。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留真实请求；不重写路径、方法或正文。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 相簿选择移除不应发HTTP，立即记录失败并结束URLSession等待。
    override func startLoading() {
        Issue.record("Backup album selection recovery must not send HTTP")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    /// 没有后台响应或挂起continuation，无需取消额外资源。
    override func stopLoading() {}
}
