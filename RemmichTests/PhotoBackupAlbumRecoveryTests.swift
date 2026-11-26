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
        #expect(controller.selected == ["keep", "missing-included"] && controller.excluded == ["missing-excluded"])
        #expect(controller.allowCloud && !controller.requiresSelectionScan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let loaded = try await store.loadPhotoBackups(scope: scope)
        let before = try encoder.encode(loaded)
        await controller.loadAlbums()
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == ["keep"] && controller.excluded.isEmpty && controller.requiresSelectionScan)
        #expect(controller.jobs.first?.motionAssetID == motionID && controller.jobs.first?.stage == .paused)
        // 同一页面重新读取真实SQLite队列不能隐式丢弃草稿、恢复旧排除规则或解除新扫描门禁。
        await controller.load(using: manager)
        #expect(controller.selected == ["keep"] && controller.excluded.isEmpty && controller.requiresSelectionScan)
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

    /// 真实Controller扫描必须先应用排除，再将完整逻辑源写入SQLite；旧Live Photo部分回执只保留为取消历史。
    /// 仅照片库列表/快照被替换；冷Controller、队列选择与持久化均走正式实现，扫描本身不能导出或上传。
    @Test(.timeLimit(.minutes(1)))
    func explicitScanPersistsEligibleSourcesAndColdControllerRestoresExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupAlbumScan-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-scan-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let account = backupAlbumAccount(owner: "scan-owner", endpoint: endpoint)
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: account.scope)
        let hidden = PhotoBackupSource(localID: "excluded-live", modifiedAt: nil, kind: .livePhoto)
        let video = PhotoBackupSource(localID: "keep-video", modifiedAt: Date(timeIntervalSince1970: 1), kind: .video)
        let live = PhotoBackupSource(localID: "keep-live", modifiedAt: Date(timeIntervalSince1970: 1), kind: .livePhoto)
        var previous = PhotoBackupJournal(namespace: account.scope.cacheNamespace)
        try previous.enqueue([hidden])
        let hiddenID = try #require(previous.jobs.first?.id)
        let motionID = UUID()
        try previous.update(hiddenID) { job in try job.begin(); try job.exported(); try job.recordMotion(motionID); job.pause() }
        try await store.savePhotoBackups(previous, scope: account.scope)
        let exporter = UnexpectedBackupAlbumExporter()
        var requestedIDs: Set<String> = []
        let controller = PhotoBackupController(store: store, exporter: exporter, albumLoader: {
            .init(albums: [.init(id: "all", title: "All"), .init(id: "private", title: "Excluded")], limited: true)
        }, albumScanner: { ids in
            requestedIDs = ids
            return [
                .init(id: "all", assets: [.init(source: hidden, capturedAt: .distantPast),
                                          .init(source: video, capturedAt: Date(timeIntervalSince1970: 2)),
                                          .init(source: live, capturedAt: Date(timeIntervalSince1970: 3))]),
                .init(id: "private", assets: [.init(source: hidden, capturedAt: .distantPast)]),
            ]
        })
        await controller.load(using: account.manager)
        await controller.loadAlbums()
        controller.selected = ["all"]
        controller.excluded = ["private"]
        controller.allowCloud = false
        let pending = controller.scan(using: account.manager)
        let scan = try #require(pending)
        await scan.value
        #expect(requestedIDs == ["all", "private"] && !controller.running)
        #expect(exporter.calls == 0 && !controller.requiresSelectionScan)

        // 独立连接重新读盘，并检查worker使用的真实队列入口；被排除的整个Live源不能成为可执行项。
        let coldStore = SQLiteLibraryIndexStore(databaseURL: database)
        let saved = try await coldStore.loadPhotoBackups(scope: account.scope)
        #expect(saved.version == 2 && saved.selectedAlbumIDs == ["all"] && saved.excludedAlbumIDs == ["private"])
        #expect(!saved.allowCloud && saved.jobs.map(\.source) == [hidden, video, live])
        #expect(saved.jobs.map(\.stage) == [.cancelled, .queued, .queued])
        #expect(saved.jobs.first?.motionAssetID == motionID && saved.jobs.first?.id == hiddenID)
        let next = try await coldStore.nextQueuedPhotoBackup(scope: account.scope)
        #expect(next?.source == video)
        let cold = PhotoBackupController(store: coldStore, exporter: exporter)
        await cold.load(using: account.manager)
        #expect(cold.selected == ["all"] && cold.excluded == ["private"] && !cold.allowCloud)
        #expect(cold.jobs.map(\.source) == [hidden, video, live] && !cold.requiresSelectionScan)
        #expect(exporter.calls == 0)
    }

    /// 权限拒绝或排除相簿消失发生在扫描边界时必须保留原始SQLite/回执；不能以空排除替换计划。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedScanPreservesSavedExclusionPlan(_ permissionDenied: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupAlbumScanFailure-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-scan-failure-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let account = backupAlbumAccount(owner: "failed-owner", endpoint: endpoint)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: account.scope)
        let source = PhotoBackupSource(localID: "keep", modifiedAt: nil, kind: .photo)
        let selection = try PhotoBackupAlbumSelection(included: ["all"], excluded: ["private"])
        var journal = PhotoBackupJournal(namespace: account.scope.cacheNamespace)
        try journal.applyAlbumScan(selection.scan([.init(id: "all", assets: [.init(source: source, capturedAt: nil)]),
                                                   .init(id: "private", assets: [])]), allowCloud: false)
        try await store.savePhotoBackups(journal, scope: account.scope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(journal)
        let exporter = UnexpectedBackupAlbumExporter()
        let controller = PhotoBackupController(store: store, exporter: exporter, albumLoader: {
            .init(albums: [.init(id: "all", title: "All"), .init(id: "private", title: "Excluded")], limited: false)
        }, albumScanner: { _ in
            if permissionDenied {
                throw PhotoBackupController.AlbumReadError.permission
            }
            return [.init(id: "all", assets: [.init(source: source, capturedAt: nil)])]
        })
        await controller.load(using: account.manager)
        await controller.loadAlbums()
        let scan = controller.scan(using: account.manager)
        await scan?.value
        #expect(scan != nil && !controller.running && exporter.calls == 0)
        #expect(controller.selected == ["all"] && controller.excluded == ["private"])
        let after = try await store.loadPhotoBackups(scope: account.scope)
        #expect(try encoder.encode(after) == before)
    }

    /// 未扫描草稿只属于原账号；同一Controller读取新账号必须恢复新账号自己的规则，不跨账号沿用排除或iCloud同意。
    @Test(.timeLimit(.minutes(1)))
    func changingAccountDiscardsOnlyTheOldAccountsUnsavedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupAlbumAccount-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-account-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let first = backupAlbumAccount(owner: "first-owner", endpoint: endpoint)
        let second = backupAlbumAccount(owner: "second-owner", endpoint: endpoint)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: first.scope)
        try await store.prepare(scope: second.scope)
        var firstJournal = PhotoBackupJournal(namespace: first.scope.cacheNamespace)
        try firstJournal.applyAlbumScan(PhotoBackupAlbumSelection(included: ["first-keep", "missing"], excluded: ["first-private"])
            .scan([.init(id: "first-keep", assets: []), .init(id: "missing", assets: []), .init(id: "first-private", assets: [])]), allowCloud: true)
        var secondJournal = PhotoBackupJournal(namespace: second.scope.cacheNamespace)
        try secondJournal.applyAlbumScan(PhotoBackupAlbumSelection(included: ["second-keep"], excluded: ["second-private"])
            .scan([.init(id: "second-keep", assets: []), .init(id: "second-private", assets: [])]), allowCloud: false)
        try await store.savePhotoBackups(firstJournal, scope: first.scope)
        try await store.savePhotoBackups(secondJournal, scope: second.scope)
        let controller = PhotoBackupController(store: store, albumLoader: {
            .init(albums: [.init(id: "first-keep", title: "First")], limited: false)
        }, albumScanner: { _ in
            Issue.record("A different account must load its configuration before scanning")
            return []
        })
        await controller.load(using: first.manager)
        let foreignResume = controller.resume(using: second.manager)
        await foreignResume?.value
        #expect(foreignResume == nil)
        await controller.loadAlbums()
        controller.removeUnavailableAlbumSelections()
        #expect(controller.selected == ["first-keep"] && controller.excluded.isEmpty && controller.requiresSelectionScan)
        // 尚未成功读出新账号日志时，即使旧页面仍在，也不能把旧草稿扫描进新账号。
        let prematureScan = controller.scan(using: second.manager)
        let prematureResume = controller.resume(using: second.manager)
        #expect(prematureScan == nil && prematureResume == nil && !controller.running)
        await controller.load(using: second.manager)
        #expect(controller.selected == ["second-keep"] && controller.excluded == ["second-private"])
        #expect(!controller.allowCloud && !controller.requiresSelectionScan)
        let savedFirst = try await store.loadPhotoBackups(scope: first.scope)
        let savedSecond = try await store.loadPhotoBackups(scope: second.scope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(savedFirst) == encoder.encode(firstJournal))
        #expect(try encoder.encode(savedSecond) == encoder.encode(secondJournal))
    }

    /// 普通包含/排除/iCloud改动也是未保存草稿；真实队列重读或取消读取都不能恢复旧字段、启动上传或清除扫描要求。
    /// 再明确取消任务只保存该任务；新Controller仍应恢复旧配置，证明草稿没有偷偷落盘。
    /// option指定修改的配置字段；cancelRead为true时在读取Task进入前取消，不冒充已验证任意中途取消时序。
    @Test(.timeLimit(.minutes(1)), arguments: ["included", "excluded", "cloud"], [false, true])
    func ordinaryDraftSurvivesQueueReloadAndJobCancellation(_ option: String, _ cancelRead: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupAlbumDraft-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-draft-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let account = backupAlbumAccount(owner: "draft-owner", endpoint: endpoint)
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: account.scope)
        let source = PhotoBackupSource(localID: "partial-live", modifiedAt: nil, kind: .livePhoto)
        let selection = try PhotoBackupAlbumSelection(included: ["keep"], excluded: ["private"])
        let scan = try selection.scan([.init(id: "keep", assets: [.init(source: source, capturedAt: nil)]), .init(id: "private", assets: [])])
        var journal = PhotoBackupJournal(namespace: account.scope.cacheNamespace)
        try journal.applyAlbumScan(scan, allowCloud: false)
        let id = try #require(journal.jobs.first?.id)
        let motionID = UUID()
        try journal.update(id) { job in try job.begin(); try job.exported(); try job.recordMotion(motionID); job.pause() }
        try await store.savePhotoBackups(journal, scope: account.scope)
        let exporter = UnexpectedBackupAlbumExporter()
        let controller = PhotoBackupController(store: store, exporter: exporter)
        await controller.load(using: account.manager)
        #expect(!controller.requiresSelectionScan)
        switch option {
        case "included": controller.selected.insert("additional")
        case "excluded": controller.excluded.insert("additional")
        default: controller.allowCloud = true
        }
        let included = controller.selected, excluded = controller.excluded, cloud = controller.allowCloud
        #expect(controller.requiresSelectionScan)

        // 主actor上创建后立即取消，明确覆盖已取消调用的进入边界；非取消场景实际完成Coordinator/SQLite读取。
        let reload = Task { await controller.load(using: account.manager) }
        if cancelRead {
            reload.cancel()
        }
        await reload.value
        #expect(controller.selected == included && controller.excluded == excluded && controller.allowCloud == cloud)
        #expect(controller.requiresSelectionScan && controller.jobs.first?.motionAssetID == motionID)
        let resume = controller.resume(using: account.manager)
        #expect(resume == nil && exporter.calls == 0)
        let saved = try await store.loadPhotoBackups(scope: account.scope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(saved) == encoder.encode(journal))

        controller.cancelJob(id, using: account.manager)
        try await waitUntil { !controller.running }
        #expect(controller.selected == included && controller.excluded == excluded && controller.allowCloud == cloud)
        #expect(controller.requiresSelectionScan)
        let cancelled = try await store.loadPhotoBackups(scope: account.scope)
        #expect(cancelled.selectedAlbumIDs == ["keep"] && cancelled.excludedAlbumIDs == ["private"] && !cancelled.allowCloud)
        #expect(cancelled.jobs.first?.stage == .cancelled && cancelled.jobs.first?.motionAssetID == motionID)
        let cold = PhotoBackupController(store: SQLiteLibraryIndexStore(databaseURL: database), exporter: exporter)
        await cold.load(using: account.manager)
        #expect(cold.selected == ["keep"] && cold.excluded == ["private"] && !cold.allowCloud && !cold.requiresSelectionScan)
        #expect(exporter.calls == 0)
    }

    /// switchAccount选择等待期间取消旧读取，或用同一manager切到B并先成功读取B；不靠sleep推测排队。
    /// 前一A操作被取消的真实信号证明旧load已进入Coordinator并等待退役屏障，不冒充SQLite内部await。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func queuedReloadCannotPublishAfterCancellationOrAccountSwitch(_ switchAccount: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupQueuedReload-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try #require(URL(string: "https://backup-queued-\(UUID().uuidString.lowercased()).example.invalid/api"))
        let first = backupAlbumAccount(owner: "queued-first", endpoint: endpoint)
        let second = backupAlbumAccount(owner: "queued-second", endpoint: endpoint)
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: first.scope)
        try await store.prepare(scope: second.scope)
        let live = PhotoBackupSource(localID: "a-partial-live", modifiedAt: nil, kind: .livePhoto)
        let photo = PhotoBackupSource(localID: "b-photo", modifiedAt: nil, kind: .photo)
        var firstJournal = PhotoBackupJournal(namespace: first.scope.cacheNamespace)
        let firstSelection = try PhotoBackupAlbumSelection(included: ["a-keep"], excluded: ["a-private"])
        try firstJournal.applyAlbumScan(firstSelection.scan([.init(id: "a-keep", assets: [.init(source: live, capturedAt: nil)]),
                                                             .init(id: "a-private", assets: [])]), allowCloud: false)
        let liveID = try #require(firstJournal.jobs.first?.id)
        let motionID = UUID()
        try firstJournal.update(liveID) { job in try job.begin(); try job.exported(); try job.recordMotion(motionID); job.pause() }
        var secondJournal = PhotoBackupJournal(namespace: second.scope.cacheNamespace)
        let secondSelection = try PhotoBackupAlbumSelection(included: ["b-keep"], excluded: ["b-private"])
        try secondJournal.applyAlbumScan(secondSelection.scan([.init(id: "b-keep", assets: [.init(source: photo, capturedAt: nil)]),
                                                               .init(id: "b-private", assets: [])]), allowCloud: true)
        try await store.savePhotoBackups(firstJournal, scope: first.scope)
        try await store.savePhotoBackups(secondJournal, scope: second.scope)
        let exporter = UnexpectedBackupAlbumExporter()
        let controller = PhotoBackupController(store: store, exporter: exporter)
        await controller.load(using: first.manager)
        controller.selected.insert("a-unsaved")
        let gate = BackupQueueReloadGate()
        let blocker = Task {
            try await PhotoBackupRunCoordinator.perform(scope: first.scope) { await gate.hold() }
        }
        do {
            try await gate.waitForEntry()
            let reload = Task { await controller.load(using: first.manager) }
            do {
                try await withTaskCancellationHandler {
                    // 只有真实load对同scope调用perform，才会取消被hold的前一任务；MainActor在登记等待者前不yield。
                    try await gate.waitForPredecessorCancellation()
                    if switchAccount {
                        first.manager.configure(session: second.session, endpoint: endpoint)
                        await controller.load(using: first.manager)
                        #expect(controller.jobs.map(\.id) == secondJournal.jobs.map(\.id) && !controller.requiresSelectionScan)
                        controller.excluded.insert("b-unsaved")
                    } else {
                        reload.cancel()
                    }
                    let included = controller.selected, excluded = controller.excluded, cloud = controller.allowCloud
                    let jobIDs = controller.jobs.map(\.id), status = controller.status
                    #expect(controller.requiresSelectionScan)
                    gate.release()
                    await reload.value
                    _ = await blocker.result
                    #expect(controller.selected == included && controller.excluded == excluded && controller.allowCloud == cloud)
                    #expect(controller.requiresSelectionScan && controller.jobs.map(\.id) == jobIDs && !controller.running)
                    #expect(controller.total == jobIDs.count && exporter.calls == 0)
                    if switchAccount {
                        #expect(controller.status == status && controller.jobs.first?.source == photo)
                    } else {
                        #expect(controller.jobs.first?.motionAssetID == motionID && controller.jobs.first?.stage == .paused)
                    }
                } onCancel: {
                    reload.cancel(); blocker.cancel()
                    Task { @MainActor in gate.stop() }
                }
            } catch {
                reload.cancel(); blocker.cancel(); gate.stop()
                await reload.value; _ = await blocker.result
                throw error
            }
        } catch {
            blocker.cancel(); gate.stop(); _ = await blocker.result
            throw error
        }
        gate.stop()

        // 重新打开两账号文件，完整日志/部分回执都必须不变；页面草稿只属于对应当前账号，绝不偷偷保存。
        let cold = SQLiteLibraryIndexStore(databaseURL: database)
        let savedFirst = try await cold.loadPhotoBackups(scope: first.scope)
        let savedSecond = try await cold.loadPhotoBackups(scope: second.scope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(savedFirst) == encoder.encode(firstJournal))
        #expect(try encoder.encode(savedSecond) == encoder.encode(secondJournal))
        let restored = PhotoBackupController(store: cold, exporter: exporter)
        await restored.load(using: first.manager)
        let expectedIncluded: Set<String> = switchAccount ? ["b-keep"] : ["a-keep"]
        let expectedExcluded: Set<String> = switchAccount ? ["b-private"] : ["a-private"]
        #expect(restored.selected == expectedIncluded && restored.excluded == expectedExcluded)
        #expect(restored.allowCloud == switchAccount && !restored.requiresSelectionScan && exporter.calls == 0)
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

/// 仅挂起真实Coordinator的前一操作并观察其实际取消；不读取/替换Controller或SQLite结果。
/// 所有状态在MainActor，release/stop幂等；进入与取消观察均可被测试取消释放，避免遗留continuation。
@MainActor private final class BackupQueueReloadGate {
    private var entered = false
    private var predecessorCancelled = false
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    private var entryObserver: CheckedContinuation<Void, Never>?
    private var cancellationObserver: CheckedContinuation<Void, Never>?

    /// 只在实际Coordinator执行到此处后报告进入；取消本身仍保持挂起，模拟必须等待的非协作退役。
    func hold() async {
        guard !released else { return }
        entered = true; entryObserver?.resume(); entryObserver = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                if released {
                    $0.resume()
                } else {
                    pending = $0
                }
            }
        } onCancel: {
            Task { @MainActor in self.observeCancellation() }
        }
    }

    /// 等待前一真实操作已挂起；返回前核Task取消与实际信号，清理释放不能假装已进入。
    func waitForEntry() async throws {
        try Task.checkCancellation()
        if !entered {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    if released {
                        $0.resume()
                    } else {
                        entryObserver = $0
                    }
                }
            } onCancel: { Task { @MainActor in self.stop() } }
        }
        try Task.checkCancellation()
        try #require(entered, "The predecessor operation must enter the real coordinator")
    }

    /// 新load调用perform会取消前一操作；该信号证明其已进入同scope排队，而非依赖固定延时。
    func waitForPredecessorCancellation() async throws {
        try Task.checkCancellation()
        if !predecessorCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    if released {
                        $0.resume()
                    } else {
                        cancellationObserver = $0
                    }
                }
            } onCancel: { Task { @MainActor in self.stop() } }
        }
        try Task.checkCancellation()
        try #require(predecessorCancelled, "The queued reload must cancel its real predecessor")
    }

    /// 记录实际取消处理器的事件，不释放旧操作，也不允许旧load提前读取SQLite。
    private func observeCancellation() {
        predecessorCancelled = true; cancellationObserver?.resume(); cancellationObserver = nil
    }

    /// 测试明确允许旧操作退役；重复调用无副作用，真实Coordinator决定后续load能否继续。
    func release() {
        released = true; pending?.resume(); pending = nil
    }

    /// 失败/超时先允许前一操作退役，再释放所有观察者；调用方随后等待实际Task结束后才删除临时文件。
    func stop() {
        release(); entryObserver?.resume(); entryObserver = nil
        cancellationObserver?.resume(); cancellationObserver = nil
    }
}

/// owner是合成认证ID，endpoint为本测试专有.invalid地址；返回真实session/scope/manager，HTTP全部由失败替身拦截。
@MainActor private func backupAlbumAccount(owner: String, endpoint: URL) -> (session: AccountSession, scope: MediaAccountScope, manager: LibraryManagementController) {
    let session = AccountSession(apiURL: endpoint, accessToken: "synthetic", userID: owner,
                                 userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                 serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
    let manager = LibraryManagementController(configurationFactory: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupAlbumNoNetworkProtocol.self]
        return configuration
    })
    manager.configure(session: session, endpoint: endpoint)
    return (session, MediaAccountScope(session: session), manager)
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
