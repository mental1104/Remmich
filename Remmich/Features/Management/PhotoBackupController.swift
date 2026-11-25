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
    var selected: Set<String> = [] {
        didSet {
            if selected != oldValue {
                markSelectionDraftChanged()
            }
        }
    }

    var excluded: Set<String> = [] {
        didSet {
            if excluded != oldValue {
                markSelectionDraftChanged()
            }
        }
    }

    var allowCloud = false {
        didSet {
            if allowCloud != oldValue {
                markSelectionDraftChanged()
            }
        }
    }

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
    private(set) var foregroundAutomaticEnabled = false
    private(set) var automaticRunning = false
    private(set) var configuringAutomatic = false
    /// 当前列表可恢复上限与跳过原因；实际继续前仍重新读取SQLite和完整保存相簿规则。
    var unattemptedSummary: PhotoBackupUnattemptedSummary {
        .init(jobs: jobs)
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let exporter: any PhotoBackupResourceExporting
    @ObservationIgnored private let albumLoader: @MainActor () async throws -> AlbumCatalog
    @ObservationIgnored private let albumScanner: @MainActor (Set<String>) throws -> [PhotoBackupAlbumSnapshot]
    @ObservationIgnored private var configurationScope: MediaAccountScope?
    @ObservationIgnored private var applyingConfiguration = false
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private weak var automaticManager: LibraryManagementController?
    @ObservationIgnored private var automaticManagerGeneration: UUID?
    @ObservationIgnored private var automaticScope: MediaAccountScope?
    @ObservationIgnored private var automaticActive = false
    @ObservationIgnored private var automaticEpoch = UUID()
    @ObservationIgnored private var automaticRequested = false
    @ObservationIgnored private var automaticMonitor: LocalPhotoChangeMonitor?
    @ObservationIgnored private let authorizationStatus: @MainActor () -> PHAuthorizationStatus
    @ObservationIgnored private let observeAutomaticPhotos: Bool
    @ObservationIgnored private var automaticSuppressedScopes: Set<String> = []

    /// store复用账号存储，exporter控制媒体导出；albumLoader读取当前授权列表，albumScanner按包含/排除ID并集重新取源快照。
    /// 两个可选读取边界的nil使用真实权限/枚举，扫描失败在任何持久化/上传前停止。
    /// authorizationStatus只查询已有授权，自动周期不得请求授权；observeAutomaticPhotos为false时仅关闭系统变更观察供隔离测试。
    init(store: SQLiteLibraryIndexStore = .init(), exporter: any PhotoBackupResourceExporting = PhotoKitBackupResourceExporter(),
         albumLoader: (@MainActor () async throws -> AlbumCatalog)? = nil,
         albumScanner: (@MainActor (Set<String>) throws -> [PhotoBackupAlbumSnapshot])? = nil,
         authorizationStatus: @escaping @MainActor () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
         observeAutomaticPhotos: Bool = true)
    {
        self.store = store
        self.exporter = exporter
        self.albumLoader = albumLoader ?? Self.readPhotoAlbums
        self.albumScanner = albumScanner ?? Self.albumSnapshots
        self.authorizationStatus = authorizationStatus
        self.observeAutomaticPhotos = observeAutomaticPhotos
    }

    /// manager绑定本次读取账号；只冷恢复/读取配置，同scope保留未扫描草稿，不自动扫描或上传。
    /// 调用取消在读取前后与发布前检查；取消或账号退役不应用迟到配置，已完成的安全暂停恢复仍保留。
    func load(using manager: LibraryManagementController) async {
        guard !configuringAutomatic else { return }
        guard let scope = manager.backupScope else { status = "请先连接服务器。"; return }
        let owner = manager.generation
        do {
            try Task.checkCancellation()
            let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                try Task.checkCancellation()
                try Self.validate(manager, owner: owner, scope: scope)
                try await store.recoverPhotoBackupWork(scope: scope)
                try Task.checkCancellation()
                try Self.validate(manager, owner: owner, scope: scope)
                let journal = try await store.loadPhotoBackups(scope: scope)
                try Task.checkCancellation()
                return journal
            }
            try Task.checkCancellation()
            try Self.validate(manager, owner: owner, scope: scope)
            apply(journal, scope: scope, restoreConfiguration: !requiresSelectionScan)
            if requiresSelectionScan {
                status = "队列已读取；本页相簿选择尚未保存，请重新选择并扫描后再继续。"
            } else {
                status = jobs.isEmpty ? "选择手机相簿后扫描。不会删除或修改手机原片。" : "已恢复当前账户队列。点击继续后重新查重，不自动重发。"
            }
        } catch {
            guard manager.generation == owner else { return }
            status = error is CancellationError ? "队列读取已停止，现有选择和恢复资料已保留，未开始上传。" : "无法读取备份恢复资料，未清空队列或开始上传。"
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

    /// manager须与已读取配置属于同一账号；显式扫描保留顺序/回执，配置与任务原子保存后才允许单独点击继续。
    /// 返回持久化任务供调用方等待完整退役；nil表示读取/选择门禁拒绝或同步扫描失败，没有写入或上传。
    @discardableResult
    func scan(using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !running, !configuringAutomatic, hasLoadedAlbums, !loadingAlbums, !selected.isEmpty, let scope = manager.backupScope else { return nil }
        guard configurationScope == scope else { status = "请先读取当前账户的备份队列，再扫描相簿。"; return nil }
        let owner = manager.generation
        let albumIDs = selected
        let excludedIDs = excluded
        let cloud = allowCloud
        guard albumIDs.union(excludedIDs).isSubset(of: Set(albums.map(\.id))) else { status = "请先重新读取手机相簿，确认包含和排除的选择仍可访问。"; return nil }
        let scan: PhotoBackupAlbumScan
        do {
            let selection = try PhotoBackupAlbumSelection(included: albumIDs, excluded: excludedIDs)
            scan = try selection.scan(albumScanner(albumIDs.union(excludedIDs)))
        } catch {
            status = "相簿不可访问或扫描期间照片发生变化，未更新队列；请重新读取并扫描。"
            return nil
        }
        running = true
        task = Task {
            defer { running = false; task = nil; requestAutomaticWork() }
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
                apply(journal, scope: scope)
                status = foregroundAutomaticEnabled
                    ? "扫描已保存：可备份 \(scan.sources.count) 项；前台自动备份将使用本次保存的规则。"
                    : "扫描已保存：可备份 \(scan.sources.count) 项；不再符合选择的待执行项已取消。点击继续后上传。"
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
        return task
    }

    /// ids为包含与排除相簿的并集；先重新确认每个集合可访问，避免旧PHAssetCollection消失被当作空排除。
    /// 返回仅含授权源版本/日期的快照；不导出文件、不下载iCloud，集合缺失或前后权限等级变化时在队列写入前抛错。
    /// 这是本轮可见成员的冻结选择，不宣称跨集合原子快照或后续limited成员变化通知；执行前仍由exporter核对当前源。
    private static func albumSnapshots(for ids: Set<String>) throws -> [PhotoBackupAlbumSnapshot] {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw AlbumReadError.permission }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids.sorted(), options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for index in 0 ..< collections.count {
            let collection = collections.object(at: index)
            byID[collection.localIdentifier] = collection
        }
        guard ids.allSatisfy({ byID[$0] != nil }) else { throw PhotoBackupAlbumSelectionError.unavailableAlbum }
        let snapshots: [PhotoBackupAlbumSnapshot] = ids.sorted().compactMap { id in
            guard let collection = byID[id] else { return nil }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var values: [PhotoBackupScannedAsset] = []
            for index in 0 ..< assets.count {
                let asset = assets.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                let source = PhotoKitBackupResourceExporter.source(for: asset)
                values.append(.init(source: source, capturedAt: asset.creationDate))
            }
            return .init(id: id, assets: values)
        }
        // 枚举前后由系统确认同一权限等级，避免把撤销权限后的空排除集合与先前已读包含资源混合保存。
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization else { throw AlbumReadError.permission }
        return snapshots
    }

    /// manager须与已读取配置属于同一认证账号；jobID非nil只重试指定任务，nil恢复可重试项，已完成历史不会重传。
    /// 返回实际执行任务供调用方等待完整退役；nil表示前置门禁拒绝，页面可忽略该句柄。
    @discardableResult
    func resume(using manager: LibraryManagementController, jobID: UUID? = nil) -> Task<Void, Never>? {
        runSavedQueue(using: manager, mode: .verification(jobID))
    }

    /// 用户明确选择只继续未尝试尾队列；不会开启自动规则或把失败/未知回执当作新任务重发。
    @discardableResult
    func resumeUnattempted(using manager: LibraryManagementController) -> Task<Void, Never>? {
        runSavedQueue(using: manager, mode: .unattempted)
    }

    /// verification保留现有明确重试语义；unattempted只计划安全尾队列，二者共用同一执行与持久化路径。
    private nonisolated enum ResumeMode: Sendable {
        case verification(UUID?), unattempted
        /// 只选择新恢复语义；已有全部/单项明确核查路径保持原权限与计划行为。
        var onlyUnattempted: Bool {
            if case .unattempted = self {
                true
            } else {
                false
            }
        }
    }

    /// mode只决定已有日志的计划，不替换Worker或上传契约；manager仍绑定真实当前账号与端点。
    /// 返回实际Task，门禁拒绝返回nil；新恢复模式使用保存规则并只检查已有Photos授权。
    private func runSavedQueue(using manager: LibraryManagementController, mode: ResumeMode) -> Task<Void, Never>? {
        guard !running, !configuringAutomatic, !requiresSelectionScan, !manager.busy, let scope = manager.backupScope,
              configurationScope == scope, let client = manager.client else { return nil }
        let authorization = authorizationStatus()
        if mode.onlyUnattempted {
            guard !selected.isEmpty else { status = "请先明确选择相簿并扫描保存，再继续未尝试项目。"; return nil }
            guard !unattemptedSummary.eligibleJobIDs.isEmpty else { status = "没有可直接继续的未尝试项目；失败、未知或取消项需单独检查。"; return nil }
            guard authorization == .authorized || authorization == .limited else { status = "请先确认照片授权，再继续未尝试项目；未启动上传。"; return nil }
        }
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
                    switch mode {
                    case let .verification(id): try journal.resumeForVerification(only: id)
                    case .unattempted:
                        try Task.checkCancellation()
                        guard self.authorizationStatus() == authorization else { throw AlbumReadError.permission }
                        let selection = try PhotoBackupAlbumSelection(included: Set(journal.selectedAlbumIDs), excluded: Set(journal.excludedAlbumIDs ?? []))
                        let scan = try selection.scan(self.albumScanner(selection.included.union(selection.excluded)))
                        guard self.authorizationStatus() == authorization, !self.requiresSelectionScan else { throw AlbumReadError.permission }
                        try journal.resumeUnattempted(scan)
                    }
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    self.total = journal.jobs.count { $0.stage == .queued }
                    let cloud = journal.allowCloud
                    // management占用整个执行周期，防止多个窗口同时通过同一写通道执行队列。
                    return try await manager.perform(publishChange: false) { _ in
                        try await PhotoBackupWorker(store: store, exporter: exporter).run(
                            scope: scope, userID: client.userID, allowCloud: cloud, client: client,
                            validateContext: {
                                try Self.validate(manager, owner: owner, scope: scope)
                                if mode.onlyUnattempted {
                                    guard self.authorizationStatus() == authorization, !self.requiresSelectionScan else { throw AlbumReadError.permission }
                                }
                            },
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
                apply(current, scope: scope, restoreConfiguration: !mode.onlyUnattempted || !requiresSelectionScan)
                status = result.stopped ? "已暂停；先处理连接、权限或未确认结果，再明确继续。" : "本轮已确认 \(result.completed) 项（重复 \(result.duplicates)），失败 \(result.failed) 项。"
            } catch {
                showFailure(error, manager: manager, owner: owner)
                if manager.generation == owner, let journal = try? await store.loadPhotoBackups(scope: scope) {
                    if manager.generation == owner {
                        apply(journal, scope: scope, restoreConfiguration: !mode.onlyUnattempted || !requiresSelectionScan)
                    }
                }
            }
        }
        return task
    }

    /// id为当前列表中的逻辑任务，manager须匹配已读取配置的账号；只取消本地任务，不删除服务器资源。
    func cancelJob(_ id: UUID, using manager: LibraryManagementController) {
        guard !running, !configuringAutomatic, let scope = manager.backupScope, configurationScope == scope else { return }
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
                apply(journal, scope: scope, restoreConfiguration: !requiresSelectionScan)
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
    }

    /// 停止实际Task，worker负责将未完成任务持久化为暂停；已发送结果可能已被服务器保存。
    func cancel() {
        task?.cancel()
        automaticTask?.cancel()
        if running {
            status = "正在停止并保存队列；再次继续会重新查重。"
        }
    }

    /// 已读取账户配置后的包含/排除/iCloud改动都属于未保存草稿；直到成功扫描才解除恢复/重试门禁。
    /// 初始构造不创建草稿；apply恢复配置时会在全部字段赋值后统一清除标记。
    private func markSelectionDraftChanged() {
        guard configurationScope != nil, !applyingConfiguration else { return }
        requiresSelectionScan = true
        automaticRequested = false
        automaticTask?.cancel()
    }

    /// journal/scope为刚验证的当前账号快照；restoreConfiguration为false时仅保留同scope未扫描草稿。
    /// 换账号必须恢复新账号自己的选择并清除旧门禁，不能把旧账号排除规则带入新的扫描计划。
    private func apply(_ journal: PhotoBackupJournal, scope: MediaAccountScope, restoreConfiguration: Bool = true) {
        if restoreConfiguration || configurationScope != scope {
            applyingConfiguration = true
            selected = Set(journal.selectedAlbumIDs)
            excluded = Set(journal.excludedAlbumIDs ?? [])
            allowCloud = journal.allowCloud
            requiresSelectionScan = false
            applyingConfiguration = false
        }
        foregroundAutomaticEnabled = journal.foregroundAutomaticEnabled == true
        configurationScope = scope
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

/// 前台自动化只围绕同一Controller/SQLite队列工作；无定时器、OS后台任务或独立上传器。
extension PhotoBackupController {
    /// scope来自Media已认证账号，active为scene活跃状态；nil保留当前活跃值供端点更新使用。
    /// 返回本轮退役/自动任务以便测试等待；同条件重复通知复用任务，不并发重扫。
    @discardableResult
    func automaticConditionsChanged(using manager: LibraryManagementController, scope: MediaAccountScope?, active: Bool? = nil) -> Task<Void, Never>? {
        let nextActive = active ?? automaticActive
        guard automaticManager !== manager || automaticManagerGeneration != manager.generation || automaticScope != scope || automaticActive != nextActive else {
            return automaticTask
        }
        let previous = automaticTask
        let previousManual = task
        previous?.cancel()
        previousManual?.cancel()
        automaticMonitor?.stop(); automaticMonitor = nil
        automaticEpoch = UUID()
        automaticManager = manager; automaticManagerGeneration = manager.generation
        if automaticScope != scope {
            foregroundAutomaticEnabled = false
        }
        automaticScope = scope; automaticActive = nextActive; automaticRequested = nextActive
        automaticTask = nil
        return launchAutomaticWork(after: previous, manual: previousManual)
    }

    /// 公开Photos观察事件只合并一个待处理请求；测试也可调用同入口，不替代实际扫描/Worker。
    @discardableResult
    func automaticLibraryChanged() -> Task<Void, Never>? {
        requestAutomaticWork()
    }

    /// enabled是对最近保存相簿/iCloud选项的明确同意；关闭先取消并等待真实任务，再持久保存关闭。
    /// 读取/写入错误可见且不上传；未保存草稿只影响页面，不借切换自动开关偷偷保存。
    func setForegroundAutomaticEnabled(_ enabled: Bool, using manager: LibraryManagementController) async {
        guard !configuringAutomatic, let scope = manager.backupScope, configurationScope == scope,
              !enabled || (!running && !manager.busy && !requiresSelectionScan) else { return }
        let owner = manager.generation
        configuringAutomatic = true
        defer { configuringAutomatic = false }
        let previous = automaticTask, previousManual = task
        automaticEpoch = UUID(); automaticRequested = false
        previous?.cancel(); automaticTask = nil
        automaticMonitor?.stop(); automaticMonitor = nil
        if !enabled {
            foregroundAutomaticEnabled = false
            automaticSuppressedScopes.insert(scope.cacheNamespace)
            previousManual?.cancel()
        }
        await previous?.value
        if !enabled {
            await previousManual?.value
        }
        do {
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            let journal = try await persistAutomaticSetting(enabled, manager: manager, owner: owner, scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            apply(journal, scope: scope, restoreConfiguration: false)
            if enabled {
                automaticSuppressedScopes.remove(scope.cacheNamespace)
                status = "已开启前台自动备份，使用最近保存的相簿与 iCloud 选项；失败、已尝试暂停及取消项仍需手动处理。"
                configuringAutomatic = false
                requestAutomaticWork()
            } else {
                status = "前台自动备份已关闭并保存；队列与已确认回执保留，需明确重新开启或手动继续。"
            }
        } catch {
            guard manager.generation == owner else { return }
            status = "自动备份开关未确认保存，当前自动任务已停止；请重新读取并明确设置。"
        }
    }

    /// 明确停止关闭并持久保存自动规则；生命周期取消使用cancel而不更改用户开关。
    func stopManually(using manager: LibraryManagementController) async {
        cancel()
        await setForegroundAutomaticEnabled(false, using: manager)
    }

    /// 关闭备份页仅停止页面发起的手动操作；已明确开启的自动周期由整个App前台生命周期持有。
    func cancelPageWork() {
        if !automaticRunning {
            task?.cancel()
        }
    }

    /// 合并Photos/扫描后的请求；默认关闭、离线、未授权或有当前账号草稿时不进入上传。
    @discardableResult
    private func requestAutomaticWork() -> Task<Void, Never>? {
        guard foregroundAutomaticEnabled, automaticActive, let scope = automaticScope, let manager = automaticManager,
              manager.backupScope == scope, !automaticSuppressedScopes.contains(scope.cacheNamespace),
              !(requiresSelectionScan && configurationScope == scope), !configuringAutomatic else { return nil }
        automaticRequested = true
        if let automaticTask {
            return automaticTask
        }
        guard !running else { return nil }
        return launchAutomaticWork(after: nil, manual: nil)
    }

    /// previous/manual为已取消的前台任务；先等其退役，避免旧defer或检查点覆盖新账号运行状态。
    /// 返回实际任务；整个周期仍使用唯一PhotoBackupRunCoordinator，不拥有第二套队列/重试器。
    private func launchAutomaticWork(after previous: Task<Void, Never>?, manual: Task<Void, Never>?) -> Task<Void, Never> {
        let epoch = automaticEpoch
        let operation = Task { [weak self] in
            await previous?.value; await manual?.value
            guard let self else { return }
            // 退役等待不自动抛取消；旧epoch不得先消费新前台/账号周期写入的pending请求。
            guard !Task.isCancelled, automaticEpoch == epoch else { return }
            var ownsRun = false
            defer {
                if ownsRun {
                    running = false; automaticRunning = false
                }
                if automaticEpoch == epoch {
                    automaticTask = nil
                }
            }
            while automaticRequested {
                guard !Task.isCancelled, automaticEpoch == epoch else { return }
                automaticRequested = false
                guard let manager = automaticManager, let scope = automaticScope, automaticActive,
                      manager.backupScope == scope, !automaticSuppressedScopes.contains(scope.cacheNamespace),
                      !running, !manager.busy, !configuringAutomatic, !(requiresSelectionScan && configurationScope == scope) else { return }
                let owner = manager.generation
                let authorization = authorizationStatus()
                guard authorization == .authorized || authorization == .limited else {
                    status = "前台自动备份等待已有照片授权，不会主动弹出授权或修改 iCloud 选项。"
                    return
                }
                do {
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    let saved = try await store.loadPhotoBackups(scope: scope)
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    // 首次读取期间用户可能已开始明确手动操作；自动周期不能在await后抢占其Coordinator或运行状态。
                    guard !running, !manager.busy, !configuringAutomatic else { return }
                    foregroundAutomaticEnabled = saved.foregroundAutomaticEnabled == true
                    guard foregroundAutomaticEnabled else { return }
                    if observeAutomaticPhotos, automaticMonitor == nil {
                        automaticMonitor = LocalPhotoChangeMonitor { [weak self] in self?.automaticLibraryChanged() }
                    }
                    running = true; ownsRun = true
                    let result = try await PhotoBackupRunCoordinator.perform(scope: scope) { [self] in
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        var journal = try await store.loadPhotoBackups(scope: scope)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        guard journal.foregroundAutomaticEnabled == true else { throw CancellationError() }
                        journal.recoverInterrupted()
                        let selection = try PhotoBackupAlbumSelection(included: Set(journal.selectedAlbumIDs), excluded: Set(journal.excludedAlbumIDs ?? []))
                        let scan = try selection.scan(albumScanner(selection.included.union(selection.excluded)))
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        try journal.applyAutomaticAlbumScan(scan)
                        try await store.savePhotoBackups(journal, scope: scope)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        apply(journal, scope: scope)
                        automaticRunning = true
                        total = journal.jobs.count { $0.stage == .queued }
                        completed = 0; duplicates = 0; failed = 0
                        guard let client = manager.client else { throw LibraryWriteError.unavailable }
                        let cloud = journal.allowCloud
                        let result = try await manager.perform(publishChange: false) { [self] _ in
                            try await PhotoBackupWorker(store: store, exporter: exporter).run(
                                scope: scope, userID: client.userID, allowCloud: cloud, client: client,
                                // cleanup仍须在Task取消后保存安全暂停；正常Worker检查点先检查Task取消。
                                validateContext: {
                                    try Self.validate(manager, owner: owner, scope: scope)
                                    guard self.authorizationStatus() == authorization else { throw AlbumReadError.permission }
                                },
                                progress: { [self] _, value in completed = value.completed; duplicates = value.duplicates; failed = value.failed }
                            )
                        }
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        var current = try await store.loadPhotoBackups(scope: scope)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        if result.stopped || result.failed > 0 {
                            try current.setForegroundAutomaticEnabled(false)
                            try await store.savePhotoBackups(current, scope: scope)
                            try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                            automaticSuppressedScopes.insert(scope.cacheNamespace)
                            automaticMonitor?.stop(); automaticMonitor = nil; automaticRequested = false
                        }
                        apply(current, scope: scope)
                        return result
                    }
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    if result.completed > 0 {
                        manager.publishChanges(ifGeneration: owner)
                    }
                    status = result.stopped || result.failed > 0
                        ? "本轮有失败或未知结果，前台自动备份已关闭；请先手动检查，未自动重试。"
                        : "前台自动备份已确认 \(result.completed) 项；等待新的照片库变更。"
                    running = false; automaticRunning = false; ownsRun = false
                } catch {
                    guard automaticEpoch == epoch, manager.generation == owner else { return }
                    if Task.isCancelled || error is CancellationError {
                        return
                    }
                    automaticSuppressedScopes.insert(scope.cacheNamespace)
                    foregroundAutomaticEnabled = false; automaticRequested = false
                    automaticMonitor?.stop(); automaticMonitor = nil
                    if let current = try? await persistAutomaticSetting(false, manager: manager, owner: owner, scope: scope) {
                        apply(current, scope: scope, restoreConfiguration: false)
                        status = "前台自动备份已关闭；相簿、权限或未确认结果需明确检查后再开启，未自动重试。"
                    } else {
                        status = "前台自动备份已停止，关闭开关未确认保存；恢复资料保留，请明确检查。"
                    }
                    return
                }
            }
        }
        automaticTask = operation
        return operation
    }

    /// enabled只改变已有账号日志头；manager/owner/scope固定，整个保存仍等待同一Coordinator退役屏障。
    private func persistAutomaticSetting(_ enabled: Bool, manager: LibraryManagementController, owner: UUID,
                                         scope: MediaAccountScope) async throws -> PhotoBackupJournal
    {
        try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            var journal = try await store.loadPhotoBackups(scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            try journal.setForegroundAutomaticEnabled(enabled)
            try await store.savePhotoBackups(journal, scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            return journal
        }
    }

    /// epoch/active/权限限定自动周期；账号检查复用原实现，禁止在await后解释旧账号或后台结果。
    private func validateAutomatic(_ manager: LibraryManagementController, owner: UUID, scope: MediaAccountScope,
                                   epoch: UUID, authorization: PHAuthorizationStatus) throws
    {
        try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
        guard automaticEpoch == epoch, automaticActive, automaticScope == scope,
              authorizationStatus() == authorization, !(requiresSelectionScan && configurationScope == scope)
        else { throw CancellationError() }
    }
}
