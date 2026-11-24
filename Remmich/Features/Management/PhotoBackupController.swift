import Foundation
import Observation
import Photos

/// 备份页面的前台生命周期与用户明确操作；持久源/回执在SQLite，真实逐项上传由worker串行执行。
@MainActor @Observable final class PhotoBackupController {
    /// id是PhotoKit集合身份，只在此设备授权照片库内解析；不以相簿名推断远端相簿关系。
    nonisolated struct Album: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }

    /// 一次成功枚举的完整当前授权范围；空albums是成功空列表，与权限/枚举错误分开。
    nonisolated struct AlbumCatalog: Sendable {
        let albums: [Album]
        let limited: Bool
    }

    /// 仅标识相簿读取失败类别，不携带PhotoKit源身份或系统错误正文。
    nonisolated enum AlbumReadError: Error, Equatable, Sendable { case permission, invalidCatalog }

    var albums: [Album] = []
    var selected: Set<String> = []
    var excluded: Set<String> = []
    var allowCloud = false
    private(set) var loadingAlbums = false
    private(set) var hasLoadedAlbums = false
    private(set) var requiresSelectionScan = false
    private(set) var running = false
    private(set) var completed = 0
    private(set) var duplicates = 0
    private(set) var failed = 0
    private(set) var total = 0
    private(set) var jobs: [PhotoBackupJob] = []
    private(set) var status = "备份队列保存在当前账户；读取后由你明确扫描或继续。"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let exporter: any PhotoBackupResourceExporting
    @ObservationIgnored private let albumLoader: @MainActor () async throws -> AlbumCatalog

    /// store复用账号存储，exporter控制媒体导出；albumLoader仅替换相簿枚举来源，nil仍使用真实PhotoKit权限/读取。
    init(store: SQLiteLibraryIndexStore = .init(), exporter: any PhotoBackupResourceExporting = PhotoKitBackupResourceExporter(),
         albumLoader: (@MainActor () async throws -> AlbumCatalog)? = nil)
    {
        self.store = store
        self.exporter = exporter
        self.albumLoader = albumLoader ?? Self.readPhotoAlbums
    }

    /// 进入页面只冷恢复中断状态和读取配置，不自动扫描、下载iCloud或上传。
    func load(using manager: LibraryManagementController) async {
        guard let scope = manager.backupScope else { status = "请先连接服务器。"; return }
        let owner = manager.generation
        do {
            let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                try Self.validate(manager, owner: owner, scope: scope)
                try await store.recoverPhotoBackupWork(scope: scope)
                try Self.validate(manager, owner: owner, scope: scope)
                return try await store.loadPhotoBackups(scope: scope)
            }
            try Self.validate(manager, owner: owner, scope: scope)
            apply(journal)
            status = jobs.isEmpty ? "选择手机相簿后扫描。不会删除或修改手机原片。" : "已恢复当前账户队列。点击继续后重新查重，不自动重发。"
        } catch {
            guard manager.generation == owner else { return }
            status = "无法读取备份恢复资料，未清空队列或开始上传。"
        }
    }

    /// 只有当前成功枚举才能判断不可用选择；初始空列表/权限失败不能推断保存相簿已消失，读取不会自动移除选择。
    func loadAlbums() async {
        guard !running, !loadingAlbums else { return }
        loadingAlbums = true
        hasLoadedAlbums = false
        defer { loadingAlbums = false }
        do {
            try Task.checkCancellation()
            let catalog = try await albumLoader()
            try Task.checkCancellation()
            guard !running else { return }
            let ids = catalog.albums.map(\.id)
            guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw AlbumReadError.invalidCatalog }
            albums = catalog.albums
            hasLoadedAlbums = true
            status = catalog.limited ? "仅扫描当前已授权照片；不可用选择须明确移除后重新扫描。" : "相簿已读取；选择后扫描，不会自动上传。"
        } catch {
            guard !running else { return }
            status = (error as? AlbumReadError) == .permission
                ? "需要照片访问权限；已保存的相簿选择保持不变，未判断任何相簿为不可用。"
                : "未成功读取手机相簿；已保存选择保持不变，请重新读取后再判断不可用选择。"
        }
    }

    /// 返回成功枚举后缺失的保存/页面选择；尚未成功读取时返回空集合表示“不能判断”，不能据此移除任何选择。
    var unavailableAlbumIDs: Set<String> {
        guard hasLoadedAlbums, !loadingAlbums else { return [] }
        return selected.union(excluded).subtracting(albums.map(\.id))
    }

    /// 明确按钮只移除本页不可用选择，不保存日志或启动任务；恢复/重试必须等一次新的成功扫描。
    func removeUnavailableAlbumSelections() {
        guard !running, hasLoadedAlbums, !loadingAlbums else { return }
        let missing = unavailableAlbumIDs
        guard !missing.isEmpty else { return }
        selected.subtract(missing)
        excluded.subtract(missing)
        requiresSelectionScan = true
        status = "已移除不可用的本页选择，尚未保存；请重新选择并扫描。备份队列和已上传回执保持不变。"
    }

    /// 真实权限与枚举边界；limited只返回当前授权范围，不保留PHAssetCollection作为日后扫描的旧快照。
    private static func readPhotoAlbums() async throws -> AlbumCatalog {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw AlbumReadError.permission }
        var choices: [Album] = []
        for result in [PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil),
                       PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)]
        {
            result.enumerateObjects { collection, _, _ in
                choices.append(.init(id: collection.localIdentifier, title: collection.localizedTitle ?? "相簿"))
            }
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization else { throw AlbumReadError.permission }
        return .init(albums: choices, limited: authorization == .limited)
    }

    /// 显式扫描保留稳定顺序、旧回执和变更版本；配置与所有任务原子保存后才允许单独点击继续。
    func scan(using manager: LibraryManagementController) {
        guard !running, hasLoadedAlbums, !loadingAlbums, !selected.isEmpty, let scope = manager.backupScope else { return }
        let owner = manager.generation
        let albumIDs = selected
        let excludedIDs = excluded
        let cloud = allowCloud
        guard albumIDs.union(excludedIDs).isSubset(of: Set(albums.map(\.id))) else { status = "请先重新读取手机相簿，确认包含和排除的选择仍可访问。"; return }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { status = "请先读取可备份相簿并授权照片访问。"; return }
        let scan: PhotoBackupAlbumScan
        do {
            let selection = try PhotoBackupAlbumSelection(included: albumIDs, excluded: excludedIDs)
            scan = try selection.scan(albumSnapshots(for: albumIDs.union(excludedIDs)))
        } catch {
            status = "相簿不可访问或扫描期间照片发生变化，未更新队列；请重新读取并扫描。"
            return
        }
        running = true
        task = Task {
            defer { running = false; task = nil }
            do {
                let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                    try Self.validate(manager, owner: owner, scope: scope)
                    var journal = try await store.loadPhotoBackups(scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    journal.recoverInterrupted()
                    try journal.applyAlbumScan(scan, allowCloud: cloud)
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    return journal
                }
                try Self.validate(manager, owner: owner, scope: scope)
                apply(journal)
                status = "扫描已保存：可备份 \(scan.sources.count) 项；不再符合选择的待执行项已取消。点击继续后上传。"
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
    }

    /// ids为包含与排除相簿的并集；先重新确认每个集合可访问，避免旧PHAssetCollection消失被当作空排除。
    /// 返回仅含授权源版本/日期的快照；不导出文件、不下载iCloud，集合缺失时在任何队列写入前抛错。
    private func albumSnapshots(for ids: Set<String>) throws -> [PhotoBackupAlbumSnapshot] {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids.sorted(), options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for index in 0 ..< collections.count {
            let collection = collections.object(at: index)
            byID[collection.localIdentifier] = collection
        }
        guard ids.allSatisfy({ byID[$0] != nil }) else { throw PhotoBackupAlbumSelectionError.unavailableAlbum }
        return ids.sorted().compactMap { id in
            guard let collection = byID[id] else { return nil }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var values: [PhotoBackupScannedAsset] = []
            for index in 0 ..< assets.count {
                let asset = assets.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                let source = PhotoBackupSource(localID: asset.localIdentifier, modifiedAt: asset.modificationDate,
                                               kind: asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
                values.append(.init(source: source, capturedAt: asset.creationDate))
            }
            return .init(id: id, assets: values)
        }
    }

    /// manager提供当前认证通道；jobID非nil只重试指定任务，nil恢复可重试项，已完成历史不会重传。
    /// 返回实际执行任务供调用方等待完整退役；nil表示前置门禁拒绝，页面可忽略该句柄。
    @discardableResult
    func resume(using manager: LibraryManagementController, jobID: UUID? = nil) -> Task<Void, Never>? {
        guard !running, !requiresSelectionScan, !manager.busy, let scope = manager.backupScope, let client = manager.client else { return nil }
        let owner = manager.generation
        running = true
        completed = 0; duplicates = 0; failed = 0
        task = Task {
            defer { running = false; task = nil; manager.publishChanges(ifGeneration: owner) }
            do {
                let result = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store, exporter] in
                    try Self.validate(manager, owner: owner, scope: scope)
                    var journal = try await store.loadPhotoBackups(scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    // 前一会话可能已失去发布权而不能暂停；屏障后由当前会话接管恢复，不能跳过遗留in-flight。
                    journal.recoverInterrupted()
                    try journal.resumeForVerification(only: jobID)
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    self.total = journal.jobs.count { $0.stage == .queued }
                    let cloud = journal.allowCloud
                    // management占用整个执行周期，防止多个窗口同时通过同一写通道执行队列。
                    return try await manager.perform(publishChange: false) { _ in
                        try await PhotoBackupWorker(store: store, exporter: exporter).run(
                            scope: scope, userID: client.userID, allowCloud: cloud, client: client,
                            validateContext: { try Self.validate(manager, owner: owner, scope: scope) },
                            progress: { _, result in
                                self.completed = result.completed; self.duplicates = result.duplicates; self.failed = result.failed
                                self.status = "已确认 \(result.completed) 项，失败 \(result.failed) 项。"
                            }
                        )
                    }
                }
                try Self.validate(manager, owner: owner, scope: scope)
                let current = try await store.loadPhotoBackups(scope: scope)
                try Self.validate(manager, owner: owner, scope: scope)
                apply(current)
                status = result.stopped ? "已暂停；先处理连接、权限或未确认结果，再明确继续。" : "本轮已确认 \(result.completed) 项（重复 \(result.duplicates)），失败 \(result.failed) 项。"
            } catch {
                showFailure(error, manager: manager, owner: owner)
                if manager.generation == owner, let journal = try? await store.loadPhotoBackups(scope: scope) {
                    if manager.generation == owner {
                        apply(journal)
                    }
                }
            }
        }
        return task
    }

    /// id为当前列表中的逻辑任务；只取消本地任务，不删除已发送或已确认的服务器资源。
    func cancelJob(_ id: UUID, using manager: LibraryManagementController) {
        guard !running, let scope = manager.backupScope else { return }
        let owner = manager.generation
        running = true
        task = Task {
            defer { running = false; task = nil }
            do {
                let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                    try Self.validate(manager, owner: owner, scope: scope)
                    var journal = try await store.loadPhotoBackups(scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    journal.recoverInterrupted()
                    try journal.update(id) { $0.cancel() }
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    return journal
                }
                try Self.validate(manager, owner: owner, scope: scope)
                apply(journal, restoreConfiguration: !requiresSelectionScan)
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
    }

    /// 停止实际Task，worker负责将未完成任务持久化为暂停；已发送结果可能已被服务器保存。
    func cancel() {
        task?.cancel()
        if running {
            status = "正在停止并保存队列；再次继续会重新查重。"
        }
    }

    /// journal为同账号冷快照；restoreConfiguration只在读取/成功扫描等恢复配置时为true，取消任务不覆盖待扫描选择。
    private func apply(_ journal: PhotoBackupJournal, restoreConfiguration: Bool = true) {
        if restoreConfiguration {
            selected = Set(journal.selectedAlbumIDs)
            excluded = Set(journal.excludedAlbumIDs ?? [])
            allowCloud = journal.allowCloud
            requiresSelectionScan = false
        }
        jobs = journal.jobs
        total = jobs.count
    }

    /// owner/scope必须仍属于manager当前认证上下文；不检查Task取消，供worker取消清理判断是否仍可落盘。
    private static func validate(_ manager: LibraryManagementController, owner: UUID, scope: MediaAccountScope) throws {
        guard manager.generation == owner, manager.backupScope == scope else { throw LibraryWriteError.changedAccount }
    }

    /// error只影响原代际界面，不向用户显示私人PhotoKit标识或底层响应正文。
    private func showFailure(_ error: any Error, manager: LibraryManagementController, owner: UUID) {
        guard manager.generation == owner else { return }
        status = error is CancellationError ? "已停止。队列与部分回执已保留；继续时重新查重。" : "操作未确认完成。恢复资料保留；检查权限、连接或存储后再试。"
    }
}
