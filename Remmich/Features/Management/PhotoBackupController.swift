import Foundation
import Observation
import Photos

/// 备份页面的前台生命周期与用户明确操作；持久源/回执在SQLite，真实逐项上传由worker串行执行。
@MainActor @Observable final class PhotoBackupController {
    /// id是PhotoKit集合身份，只在此设备授权照片库内解析；不以相簿名推断远端相簿关系。
    struct Album: Identifiable {
        let id: String
        let title: String
        let collection: PHAssetCollection
    }

    var albums: [Album] = []
    var selected: Set<String> = []
    var allowCloud = false
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

    /// store复用现有账号存储布局；exporter可替换为合成媒体实现，不改变真实worker或HTTP语义。
    init(store: SQLiteLibraryIndexStore = .init(), exporter: any PhotoBackupResourceExporting = PhotoKitBackupResourceExporter()) {
        self.store = store
        self.exporter = exporter
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

    /// 请求照片访问并列出手机相簿；limited仅展示系统授权范围，不扩展权限或访问未授权资源。
    func loadAlbums() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { status = "需要照片访问权限。"; return }
        var choices: [Album] = []
        for result in [PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil),
                       PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)]
        {
            result.enumerateObjects { collection, _, _ in
                choices.append(.init(id: collection.localIdentifier, title: collection.localizedTitle ?? "相簿", collection: collection))
            }
        }
        albums = choices
        status = authorization == .limited ? "仅扫描当前已授权照片；系统未授权的资源不会进入队列。" : "选择相簿并扫描；扫描不会自动上传。"
    }

    /// 显式扫描保留稳定顺序、旧回执和变更版本；配置与所有任务原子保存后才允许单独点击继续。
    func scan(using manager: LibraryManagementController) {
        guard !running, !selected.isEmpty, let scope = manager.backupScope else { return }
        let owner = manager.generation
        let albumIDs = selected
        let cloud = allowCloud
        guard albumIDs.isSubset(of: Set(albums.map(\.id))) else { status = "请先重新读取可备份相簿，确认已保存的选择仍可访问。"; return }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { status = "请先读取可备份相簿并授权照片访问。"; return }
        var assets: [String: PHAsset] = [:]
        for album in albums where albumIDs.contains(album.id) {
            PHAsset.fetchAssets(in: album.collection, options: nil).enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video {
                    assets[asset.localIdentifier] = asset
                }
            }
        }
        let sources = assets.values.sorted {
            let lhs = $0.creationDate ?? .distantPast, rhs = $1.creationDate ?? .distantPast
            return lhs == rhs ? $0.localIdentifier < $1.localIdentifier : lhs < rhs
        }.map { asset in
            PhotoBackupSource(localID: asset.localIdentifier, modifiedAt: asset.modificationDate,
                              kind: asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
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
                    journal.selectedAlbumIDs = albumIDs.sorted()
                    journal.allowCloud = cloud
                    try journal.enqueue(sources)
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    return journal
                }
                try Self.validate(manager, owner: owner, scope: scope)
                apply(journal)
                status = "扫描已保存：\(sources.count) 项。点击继续队列后上传并查重。"
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
    }

    /// manager提供当前认证通道；jobID非nil只重试指定任务，nil恢复可重试项，已完成历史不会重传。
    /// 返回实际执行任务供调用方等待完整退役；nil表示前置门禁拒绝，页面可忽略该句柄。
    @discardableResult
    func resume(using manager: LibraryManagementController, jobID: UUID? = nil) -> Task<Void, Never>? {
        guard !running, !manager.busy, let scope = manager.backupScope, let client = manager.client else { return nil }
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
                    total = journal.jobs.count { $0.stage == .queued }
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
                apply(journal)
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

    /// journal为已验证的同账号冷快照；只在读取/扫描/一轮执行结束时更新完整列表。
    private func apply(_ journal: PhotoBackupJournal) {
        selected = Set(journal.selectedAlbumIDs)
        allowCloud = journal.allowCloud
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
