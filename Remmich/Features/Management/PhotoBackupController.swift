import Foundation
import Observation
import OSLog
import Photos

/// 备份页面、前台自动与明确同意的系统后台共用持久队列；真实逐项上传由唯一Coordinator/worker串行执行。
@MainActor @Observable final class PhotoBackupController {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "BackupFailure")
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
    private(set) var processed = 0
    private(set) var preflighting = false
    private(set) var phaseDone = 0
    private(set) var phaseTotal = 0
    var progressFraction: Double? {
        let count = preflighting ? phaseDone : processed
        let limit = preflighting ? phaseTotal : total
        guard limit > 0 else { return nil }
        return min(1, max(0, Double(count) / Double(limit)))
    }

    private(set) var jobs: [PhotoBackupJob] = []
    /// 界面读取时按当前语言格式化，不改变队列、取消代际或后台执行状态。
    var status: String {
        L10n.text(statusMessage)
    }

    var continuityStatus: String {
        L10n.text(continuityMessage)
    }

    private var statusMessage: String.LocalizationValue = "备份队列保存在当前账户；读取后由你明确扫描或继续。"
    private(set) var foregroundAutomaticEnabled = false
    private(set) var foregroundNetworkRecoveryEnabled = false
    private(set) var backgroundAutomaticEnabled = false
    private(set) var backgroundLastResult: Bool?
    private(set) var automaticRunning = false
    private(set) var configuringAutomatic = false
    /// 当前列表可恢复上限与跳过原因；实际继续前仍重新读取SQLite和完整保存相簿规则。
    private(set) var unattemptedSummary = PhotoBackupUnattemptedSummary(jobs: [])
    private var continuityMessage: String.LocalizationValue = "先核对 Immich 已有项目；旧备份记录可选导入，无需下载原片来匹配。"

    /// 只暴露当前已加载、无草稿且没有备份/配置写入的门禁，不向组织页面传递账号凭据或私有存储。
    func hasCurrentSavedSelection(using manager: LibraryManagementController) -> Bool {
        configurationScope == manager.backupScope && configurationScope != nil && !requiresSelectionScan && !running && !configuringAutomatic
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let exporter: any PhotoBackupResourceExporting
    @ObservationIgnored private let preflight: (any PhotoBackupPreflighting)?
    @ObservationIgnored weak var localMatches: LocalMediaMatchController?
    @ObservationIgnored private let albumLoader: @MainActor () async throws -> AlbumCatalog
    @ObservationIgnored private let albumScanner: @MainActor (Set<String>) async throws -> [PhotoBackupAlbumSnapshot]
    @ObservationIgnored private var configurationScope: MediaAccountScope?
    @ObservationIgnored private var applyingConfiguration = false
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private weak var automaticManager: LibraryManagementController?
    @ObservationIgnored private var automaticManagerGeneration: UUID?
    @ObservationIgnored private var automaticScope: MediaAccountScope?
    @ObservationIgnored private var automaticActive = false
    @ObservationIgnored private var automaticEpoch = UUID()
    @ObservationIgnored private var automaticRequested = false
    @ObservationIgnored private var automaticNetworkRecoveryRequested = false
    @ObservationIgnored private var automaticWaitingForNetwork = false
    /// 仅记录当前有效上下文已经消费的真实路由事件；同token不能再次启动失败重核。
    @ObservationIgnored private(set) var lastValidatedNetworkRecoveryEvent: UUID?
    @ObservationIgnored private var automaticMonitor: LocalPhotoChangeMonitor?
    @ObservationIgnored private let authorizationStatus: @MainActor () -> PHAuthorizationStatus
    @ObservationIgnored private let observeAutomaticPhotos: Bool
    @ObservationIgnored private var automaticSuppressedScopes: Set<String> = []
    @ObservationIgnored private var backgroundSuppressedScopes: Set<String> = []
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

    /// store复用账号存储，exporter控制媒体导出；albumLoader读取当前授权列表，albumScanner按包含/排除ID并集重新取源快照。
    /// 两个可选读取边界的nil使用真实权限/枚举，扫描失败在任何持久化/上传前停止。
    /// authorizationStatus只查询已有授权，自动周期不得请求授权；observeAutomaticPhotos为false时仅关闭系统变更观察供隔离测试。
    init(store: SQLiteLibraryIndexStore = .init(), exporter: any PhotoBackupResourceExporting = PhotoKitBackupResourceExporter(),
         albumLoader: (@MainActor () async throws -> AlbumCatalog)? = nil,
         albumScanner: (@MainActor (Set<String>) async throws -> [PhotoBackupAlbumSnapshot])? = nil,
         authorizationStatus: @escaping @MainActor () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
         observeAutomaticPhotos: Bool = true,
         preflight: (any PhotoBackupPreflighting)? = nil)
    {
        self.store = store
        self.exporter = exporter
        self.preflight = preflight
        self.albumLoader = albumLoader ?? Self.readPhotoAlbums
        self.albumScanner = albumScanner ?? { ids in try await Self.albumSnapshots(for: ids) }
        self.authorizationStatus = authorizationStatus
        self.observeAutomaticPhotos = observeAutomaticPhotos
    }

    /// manager绑定本次读取账号；只冷恢复/读取配置，同scope保留未扫描草稿，不自动扫描或上传。
    /// 调用取消在读取前后与发布前检查；取消或账号退役不应用迟到配置，已完成的安全暂停恢复仍保留。
    func load(using manager: LibraryManagementController) async {
        guard !configuringAutomatic else { return }
        guard let scope = manager.backupScope else { statusMessage = "请先连接服务器。"; return }
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
            // 草稿只属于原configurationScope；切换账号的冷恢复不能把旧账号选择带入新账号。
            apply(journal, scope: scope, restoreConfiguration: configurationScope != scope || !requiresSelectionScan)
            if requiresSelectionScan {
                statusMessage = "队列已读取；本页相簿选择尚未保存，请重新选择并扫描后再继续。"
            } else {
                statusMessage = jobs.isEmpty ? "选择手机相簿后扫描。不会删除或修改手机原片。" : "已恢复当前账户队列。点击继续后重新查重，不自动重发。"
            }
        } catch {
            guard manager.generation == owner else { return }
            statusMessage = error is CancellationError ? "队列读取已停止，现有选择和恢复资料已保留，未开始上传。" : "无法读取备份恢复资料，未清空队列或开始上传。"
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
            statusMessage = catalog.limited ? "仅扫描当前已授权照片；不可用选择须明确移除后重新扫描。" : "相簿已读取；选择后扫描，不会自动上传。"
        } catch {
            guard !running else { return }
            statusMessage = (error as? AlbumReadError) == .permission
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
        statusMessage = "已移除不可用的本页选择，尚未保存；请重新选择并扫描。备份队列和已上传回执保持不变。"
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
    /// 返回持久化任务供调用方等待完整退役；nil表示前置门禁拒绝。Photos枚举异步执行，失败不更新队列。
    @discardableResult
    func scan(using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !running, !configuringAutomatic, hasLoadedAlbums, !loadingAlbums, !selected.isEmpty, let scope = manager.backupScope else { return nil }
        guard configurationScope == scope else { statusMessage = "请先读取当前账户的备份队列，再扫描相簿。"; return nil }
        let owner = manager.generation
        let albumIDs = selected
        let excludedIDs = excluded
        let cloud = allowCloud
        guard albumIDs.union(excludedIDs).isSubset(of: Set(albums.map(\.id))) else { statusMessage = "请先重新读取手机相簿，确认包含和排除的选择仍可访问。"; return nil }
        running = true
        statusMessage = "正在核查所选相簿，可随时暂停。"
        task = Task {
            defer { running = false; task = nil; requestAutomaticWork() }
            do {
                // 先发布运行状态再枚举；大图库读取不占UI线程，暂停会传播到实际扫描任务。
                let selection = try PhotoBackupAlbumSelection(included: albumIDs, excluded: excludedIDs)
                let snapshots = try await albumScanner(albumIDs.union(excludedIDs))
                let scan = try await Self.planAlbumScan(selection, snapshots: snapshots)
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                guard selected == albumIDs, excluded == excludedIDs, allowCloud == cloud else { throw CancellationError() }
                let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                    try Task.checkCancellation()
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
                statusMessage = foregroundAutomaticEnabled
                    ? "扫描已保存：可备份 \(scan.sources.count) 项；前台自动备份将使用本次保存的规则。"
                    : "扫描已保存：可备份 \(scan.sources.count) 项；不再符合选择的待执行项已取消。点击继续后上传。"
            } catch { showFailure(error, manager: manager, owner: owner) }
        }
        return task
    }

    /// ids为包含与排除相簿的并集；先重新确认每个集合可访问，避免旧PHAssetCollection消失被当作空排除。
    /// 返回仅含授权源版本/日期的快照；不导出文件、不下载iCloud，集合缺失或前后权限等级变化时在队列写入前抛错。
    /// 这是本轮可见成员的冻结选择，不宣称跨集合原子快照或后续limited成员变化通知；执行前仍由exporter核对当前源。
    @concurrent static func albumSnapshots(for ids: Set<String>) async throws -> [PhotoBackupAlbumSnapshot] {
        try Task.checkCancellation()
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw AlbumReadError.permission }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids.sorted(), options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for index in 0 ..< collections.count {
            try Task.checkCancellation()
            let collection = collections.object(at: index)
            byID[collection.localIdentifier] = collection
        }
        guard ids.allSatisfy({ byID[$0] != nil }) else { throw PhotoBackupAlbumSelectionError.unavailableAlbum }
        let snapshots: [PhotoBackupAlbumSnapshot] = try ids.sorted().compactMap { id in
            try Task.checkCancellation()
            guard let collection = byID[id] else { return nil }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var values: [PhotoBackupScannedAsset] = []
            for index in 0 ..< assets.count {
                try Task.checkCancellation()
                // 每项释放Photos临时对象，避免数万项资源描述积留到整次枚举结束。
                autoreleasepool {
                    let asset = assets.object(at: index)
                    guard asset.mediaType == .image || asset.mediaType == .video else { return }
                    let source = PhotoKitBackupResourceExporter.source(for: asset)
                    values.append(.init(source: source, capturedAt: asset.creationDate))
                }
            }
            return .init(id: id, assets: values)
        }
        // 枚举前后由系统确认同一权限等级，避免把撤销权限后的空排除集合与先前已读包含资源混合保存。
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization else { throw AlbumReadError.permission }
        return snapshots
    }

    /// selection为冻结包含/排除规则，snapshots只含可发送值；去重排序在通用执行器运行，返回完整计划或取消错误。
    @concurrent static func planAlbumScan(_ selection: PhotoBackupAlbumSelection, snapshots: [PhotoBackupAlbumSnapshot]) async throws -> PhotoBackupAlbumScan {
        try Task.checkCancellation()
        let scan = try selection.scan(snapshots)
        try Task.checkCancellation()
        return scan
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

    /// 仅供现有系统processing授权调用；后台同意/已存规则/已有权限和原唯一Coordinator均须满足。
    /// 返回实际运行任务，nil表示门禁拒绝；调用者必须传递取消并等待退役，不伪装前台active。
    @discardableResult
    func runSystemBackground(using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard backgroundAutomaticEnabled, backgroundTask == nil, !running, !configuringAutomatic else { return nil }
        backgroundLastResult = nil
        let operation = runSavedQueue(using: manager, mode: .background)
        backgroundTask = operation
        return operation
    }

    /// 只取消系统后台持有的真实任务，不改变用户开关，也不误停另一次手动/前台运行。
    func cancelSystemBackground() {
        backgroundTask?.cancel()
    }

    /// manager是当前认证通道；只冷读日志头并发布当前账号的后台同意，不触碰任务状态或照片权限。
    /// 返回保存的同意；存储/代际错误抛出，调用方不得因此开始扫描或上传。
    func refreshBackgroundConsent(using manager: LibraryManagementController) async throws -> Bool {
        guard let scope = manager.backupScope else { throw LibraryWriteError.unavailable }
        let owner = manager.generation
        let enabled = try await store.photoBackupBackgroundEnabled(scope: scope)
        try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
        backgroundAutomaticEnabled = enabled && !backgroundSuppressedScopes.contains(scope.cacheNamespace)
        return backgroundAutomaticEnabled
    }

    /// verification保留现有明确重试语义；unattempted只计划安全尾队列，二者共用同一执行与持久化路径。
    private nonisolated enum ResumeMode: Sendable {
        case verification(UUID?), unattempted, background
        /// 只选择新恢复语义；已有全部/单项明确核查路径保持原权限与计划行为。
        var onlyUnattempted: Bool {
            switch self {
            case .unattempted, .background: true
            case .verification: false
            }
        }

        /// 系统授权入口可扫描新源；手动安全尾队列仍不扩大原已排任务。
        var isBackground: Bool {
            if case .background = self {
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
            guard !selected.isEmpty else { statusMessage = "请先明确选择相簿并扫描保存，再继续未尝试项目。"; return nil }
            guard mode.isBackground || !unattemptedSummary.eligibleJobIDs.isEmpty else { statusMessage = "没有可直接继续的未尝试项目；失败、未知或取消项需单独检查。"; return nil }
            guard !mode.isBackground || (backgroundAutomaticEnabled && !backgroundSuppressedScopes.contains(scope.cacheNamespace)) else { return nil }
            guard authorization == .authorized || authorization == .limited else { statusMessage = "请先确认照片授权，再继续未尝试项目；未启动上传。"; return nil }
        }
        let owner = manager.generation
        running = true
        completed = 0; duplicates = 0; failed = 0; processed = 0
        statusMessage = "正在准备备份队列，可随时暂停。"
        continuityMessage = "正在读取并核对已保存的任务。"
        task = Task {
            defer {
                running = false; task = nil
                if mode.isBackground {
                    backgroundTask = nil
                }
                manager.publishChanges(ifGeneration: owner)
            }
            do {
                let result = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store, exporter] in
                    try Self.validate(manager, owner: owner, scope: scope)
                    var journal = try await store.loadPhotoBackups(scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    // 前一会话可能已失去发布权而不能暂停；屏障后由当前会话接管恢复，不能跳过遗留in-flight。
                    journal.recoverInterrupted()
                    switch mode {
                    case let .verification(id): try journal.resumeForVerification(only: id)
                    case .unattempted, .background:
                        try Task.checkCancellation()
                        guard self.authorizationStatus() == authorization else { throw AlbumReadError.permission }
                        let selection = try PhotoBackupAlbumSelection(included: Set(journal.selectedAlbumIDs), excluded: Set(journal.excludedAlbumIDs ?? []))
                        let snapshots = try await self.albumScanner(selection.included.union(selection.excluded))
                        let scan = try await Self.planAlbumScan(selection, snapshots: snapshots)
                        try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                        guard self.authorizationStatus() == authorization, !self.requiresSelectionScan else { throw AlbumReadError.permission }
                        if mode.isBackground {
                            guard self.backgroundAutomaticEnabled else { throw CancellationError() }
                            try journal.applyBackgroundAlbumScan(scan)
                        } else {
                            try journal.resumeUnattempted(scan)
                        }
                    }
                    try await store.savePhotoBackups(journal, scope: scope)
                    try Self.validate(manager, owner: owner, scope: scope)
                    self.total = journal.jobs.count { $0.stage == .queued }
                    let cloud = journal.allowCloud
                    // management占用整个执行周期，防止多个窗口同时通过同一写通道执行队列。
                    return try await manager.perform(publishChange: false) { [journal] _ in
                        let verificationIDs: Set<UUID> = if case let .verification(id) = mode {
                            // 明确“匹配并备份”包含选中的整批恢复；仍逐项重新导出/查重，不自动重放未知上传。
                            id.map { Set([$0]) } ?? Set(journal.jobs.filter { $0.stage == .queued }.map(\.id))
                        } else {
                            []
                        }
                        let plan = try await self.prepareContinuity(journal, manager: manager, owner: owner, scope: scope, client: client, verificationIDs: verificationIDs, keepWaiting: !mode.isBackground)
                        return try await PhotoBackupWorker(store: store, exporter: exporter).run(
                            scope: scope, userID: client.userID, allowCloud: cloud, client: self.retryingUploader(client, manager: manager, owner: owner, scope: scope, keepWaiting: !mode.isBackground),
                            preflight: plan,
                            validateContext: {
                                try Self.validate(manager, owner: owner, scope: scope)
                                if mode.onlyUnattempted {
                                    guard self.authorizationStatus() == authorization, !self.requiresSelectionScan else { throw AlbumReadError.permission }
                                }
                                if mode.isBackground, !self.backgroundAutomaticEnabled {
                                    throw CancellationError()
                                }
                            },
                            progress: { _, result in
                                self.completed = result.completed; self.duplicates = result.duplicates; self.failed = result.failed
                                self.processed = result.completed + result.failed + result.skipped + result.review
                                self.statusMessage = "已处理 \(self.processed) 项：新备份 \(result.completed)，已匹配 \(result.skipped)，备份未确认 \(result.review)，失败 \(result.failed)。"
                            }
                        )
                    }
                }
                try Self.validate(manager, owner: owner, scope: scope)
                let current = try await store.loadPhotoBackups(scope: scope)
                try Self.validate(manager, owner: owner, scope: scope)
                apply(current, scope: scope, restoreConfiguration: !mode.onlyUnattempted || !requiresSelectionScan)
                statusMessage = result.stopped ? "已暂停；先处理连接、权限或未确认结果，再明确继续。" : "本轮新备份 \(result.completed) 项（重复 \(result.duplicates)），已匹配 \(result.skipped)，备份未确认 \(result.review)，失败 \(result.failed) 项。"
                if mode.isBackground {
                    backgroundLastResult = !result.stopped && result.failed == 0 && result.review == 0
                }
            } catch {
                if mode.isBackground, manager.generation == owner {
                    backgroundLastResult = false
                }
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
            statusMessage = "正在停止并保存队列；再次继续会重新查重。"
        }
    }

    /// 自动组织只等待当前上传/扫描真正退役，不取消它；await后的调用方仍须重新核账号/权限和新工作门禁。
    func waitForCurrentWork() async {
        let automatic = automaticTask, manual = task
        await automatic?.value
        await manual?.value
    }

    /// 已读取账户配置后的包含/排除/iCloud改动都属于未保存草稿；直到成功扫描才解除恢复/重试门禁。
    /// 初始构造不创建草稿；apply恢复配置时会在全部字段赋值后统一清除标记。
    private func markSelectionDraftChanged() {
        guard configurationScope != nil, !applyingConfiguration else { return }
        requiresSelectionScan = true
        automaticRequested = false
        automaticNetworkRecoveryRequested = false
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
        foregroundNetworkRecoveryEnabled = journal.foregroundNetworkRecoveryEnabled == true
        backgroundAutomaticEnabled = journal.backgroundAutomaticEnabled == true && !backgroundSuppressedScopes.contains(scope.cacheNamespace)
        configurationScope = scope
        jobs = journal.jobs
        unattemptedSummary = .init(jobs: journal.jobs)
        total = jobs.count
    }

    /// url来自用户选定的官方导出；manager绑定当前认证身份。只读导入并原子保存，失败保留原接续快照和队列。
    func importHistory(from url: URL, using manager: LibraryManagementController) async {
        guard !running, !configuringAutomatic, !manager.busy, let scope = manager.backupScope else { return }
        let owner = manager.generation
        configuringAutomatic = true
        defer { configuringAutomatic = false }
        do {
            let history = try await PhotoBackupHistoryImporter.read(url, scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            try await store.savePhotoBackupHistory(history, scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            continuityMessage = "已导入 \(history.records.count) 项记录。已有项目只核查，不重新下载原片。"
        } catch { showFailure(error, manager: manager, owner: owner) }
    }

    /// journal是Coordinator内固定的实际待执行队列；完整在线核查通过才发放Worker许可，每个await后继续核原账号。
    private func prepareContinuity(_ journal: PhotoBackupJournal, manager: LibraryManagementController, owner: UUID,
                                   scope: MediaAccountScope, client: LibraryMutationClient, verificationIDs: Set<UUID>, keepWaiting: Bool = true) async throws -> PhotoBackupPreflightPlan
    {
        let queued = journal.jobs.filter { $0.stage == .queued }
        preflighting = true; phaseDone = 0; phaseTotal = queued.count
        defer { preflighting = false }
        await localMatches?.beginBackupMatching(using: manager)
        try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
        let publishStatus: @MainActor (String.LocalizationValue) -> Void = { [weak self] message in self?.continuityMessage = message }
        let reader = PhotoBackupRetryingQueries(base: client, validate: {
            try Self.validate(manager, owner: owner, scope: scope)
        }, status: publishStatus, keepWaiting: keepWaiting, retryMatchedWrites: true)
        let checker = preflight ?? PhotoBackupContinuityChecker(store: store, status: { [weak self] message in
            self?.continuityMessage = message
        }, phaseProgress: { [weak self] done, total in
            self?.phaseDone = done; self?.phaseTotal = total
        }, serverFirst: true, verifiedCheckpoint: { [self] jobs, associations in
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            try await store.checkpointPhotoBackupMatches(jobs, scope: scope, associations: associations)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            processed += jobs.count
            localMatches?.acceptBackupMatches(associations, using: manager)
            statusMessage = "已保存匹配进度 \(processed) 项；中断后可继续剩余项目。"
        })
        let plan = try await checker.plan(jobs: queued, scope: scope, client: reader, verificationIDs: verificationIDs, progress: { [self] done, total in
            phaseDone = done; phaseTotal = total
            continuityMessage = "正在核查 \(done) / \(total) 项，可随时暂停。"
        }, validateContext: {
            try Self.validate(manager, owner: owner, scope: scope)
        })
        try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
        try plan.validate(sources: Set(queued.map(\.source)))
        continuityMessage = "已匹配服务器已有 \(plan.existing.count) 项，待上传 \(plan.allowed.count) 项，备份未确认 \(plan.review.count) 项。"
        return plan
    }

    func matchingAssociations(scope: MediaAccountScope) async throws -> [LocalMediaAssociation] {
        try await store.loadPhotoSyncAssociations(scope: scope)
    }

    func cacheMatchingAssociations(_ values: [LocalMediaAssociation], scope: MediaAccountScope) async throws {
        try await store.cachePhotoSyncAssociations(values, scope: scope)
    }

    private func retryingUploader(_ client: LibraryMutationClient, manager: LibraryManagementController, owner: UUID,
                                  scope: MediaAccountScope, keepWaiting: Bool = true) -> PhotoSyncRetryingUploader
    {
        .init(base: client, retry: .init(keepWaiting: keepWaiting, validate: {
            try Self.validate(manager, owner: owner, scope: scope)
        }, status: { [weak self] message in self?.continuityMessage = message }))
    }

    /// owner/scope必须仍属于manager当前认证上下文；不检查Task取消，供worker取消清理判断是否仍可落盘。
    private static func validate(_ manager: LibraryManagementController, owner: UUID, scope: MediaAccountScope) throws {
        guard manager.generation == owner, manager.backupScope == scope else { throw LibraryWriteError.changedAccount }
    }

    /// error只影响原代际界面，不向用户显示私人PhotoKit标识或底层响应正文。
    private func showFailure(_ error: any Error, manager: LibraryManagementController, owner: UUID) {
        guard manager.generation == owner else { return }
        if !(error is CancellationError) {
            let value = error as NSError
            Self.logger.error("Backup failed domain=\(value.domain, privacy: .public) code=\(value.code) phaseDone=\(self.phaseDone) phaseTotal=\(self.phaseTotal)")
            if let write = error as? LibraryWriteError, case let .http(code) = write {
                Self.logger.error("Backup failed HTTP status=\(code)")
            }
        }
        if let error = error as? PhotoBackupContinuityError {
            switch error {
            case .wrongAccount: statusMessage = "备份记录属于其他账户，未导入。"
            default: statusMessage = "接续核查未完成；记录与队列保留，本次没有开始上传。"
            }
        } else if PhotoBackupRetryingQueries.isTransient(error) {
            statusMessage = "连接中断。已确认的匹配结果已保存，点击继续仅核查未完成项目。"
        } else {
            statusMessage = error is CancellationError ? "已停止。队列与部分回执已保留；继续时重新查重。" : "操作未确认完成。恢复资料保留；检查权限、连接或存储后再试。"
        }
    }
}

/// 独立自动化同意与前台观察共用同一Controller/SQLite队列；系统授权由原App调度器持有，不创建第二上传器。
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
        let retainedNetworkEvent = nextActive && automaticManager === manager && automaticManagerGeneration == manager.generation
            && automaticScope == scope && automaticNetworkRecoveryRequested
        previous?.cancel()
        previousManual?.cancel()
        automaticMonitor?.stop(); automaticMonitor = nil
        automaticEpoch = UUID()
        automaticManager = manager; automaticManagerGeneration = manager.generation
        if automaticScope != scope {
            foregroundAutomaticEnabled = false
            foregroundNetworkRecoveryEnabled = false
            automaticWaitingForNetwork = false
            lastValidatedNetworkRecoveryEvent = nil
            backgroundAutomaticEnabled = false
            backgroundLastResult = nil
        }
        automaticNetworkRecoveryRequested = retainedNetworkEvent
        automaticScope = scope; automaticActive = nextActive; automaticRequested = nextActive
        automaticTask = nil
        return launchAutomaticWork(after: previous, manual: previousManual)
    }

    /// 公开Photos观察事件只合并一个待处理请求；测试也可调用同入口，不替代实际扫描/Worker。
    @discardableResult
    func automaticLibraryChanged() -> Task<Void, Never>? {
        requestAutomaticWork()
    }

    /// eventID来自原NWPathMonitor变化后真实验证的当前路由；不创建网络观察器，也不把同endpoint保留误作无恢复。
    /// 只有当前前台/账号接受事件，SQL保存同意仍在原周期内重新核对；同token合并，默认不恢复任何失败。
    @discardableResult
    func networkRouteValidated(using manager: LibraryManagementController, scope: MediaAccountScope?, eventID: UUID) -> Task<Void, Never>? {
        guard automaticManager === manager, automaticManagerGeneration == manager.generation,
              let scope, automaticScope == scope, manager.backupScope == scope,
              !automaticSuppressedScopes.contains(scope.cacheNamespace), !requiresSelectionScan, !configuringAutomatic else { return nil }
        guard lastValidatedNetworkRecoveryEvent != eventID else { return automaticTask }
        lastValidatedNetworkRecoveryEvent = eventID
        automaticNetworkRecoveryRequested = true; automaticWaitingForNetwork = false; automaticRequested = true
        // App已在前台而scene尚未active时只暂存本代际事件；相同上下文转active才由原生命周期启动。
        guard automaticActive else { return nil }
        if let automaticTask {
            return automaticTask
        }
        guard !running, !manager.busy else { return nil }
        return launchAutomaticWork(after: nil, manual: nil)
    }

    /// enabled为独立的失败重核同意，默认关闭；只保存已有规则，绝不借开关重排失败或扩大iCloud选择。
    /// 关闭先取消并等待旧周期；保存后仅恢复原安全新项扫描，失败仍须新验证网络token才能进入Worker。
    func setForegroundNetworkRecoveryEnabled(_ enabled: Bool, using manager: LibraryManagementController) async {
        guard !configuringAutomatic, let scope = manager.backupScope, configurationScope == scope,
              !enabled || (foregroundAutomaticEnabled && !running && !manager.busy && !requiresSelectionScan) else { return }
        let owner = manager.generation
        configuringAutomatic = true
        defer { configuringAutomatic = false }
        let previous = automaticTask
        automaticEpoch = UUID(); automaticRequested = false; automaticNetworkRecoveryRequested = false
        previous?.cancel(); automaticTask = nil
        await previous?.value
        do {
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                var journal = try await store.loadPhotoBackups(scope: scope)
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                try journal.setForegroundNetworkRecoveryEnabled(enabled)
                try await store.updatePhotoBackupAutomationSettings(scope: scope, networkRecovery: enabled)
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                return journal
            }
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            apply(journal, scope: scope, restoreConfiguration: false)
            statusMessage = enabled ? "已同意网络恢复后核查连接失败项；只在新路由验证后重新查重，不立即重试。" : "网络恢复重核已关闭；失败项仍需手动继续。"
            if !enabled {
                automaticWaitingForNetwork = false
            }
            configuringAutomatic = false
            requestAutomaticWork()
        } catch {
            guard manager.generation == owner else { return }
            statusMessage = "网络恢复选项未确认保存；请重新读取并明确设置，未恢复失败项。"
        }
    }

    /// enabled为当前账号的独立系统后台同意；启用只使用已保存选择，关闭先取消/等待真实后台任务。
    /// 失败保留恢复资料并显示未确认状态；不修改前台开关或iCloud意愿，不调用stopManually。
    func setBackgroundAutomaticEnabled(_ enabled: Bool, using manager: LibraryManagementController) async {
        guard !configuringAutomatic, let scope = manager.backupScope,
              !enabled || (configurationScope == scope && !running && !manager.busy && !requiresSelectionScan && !selected.isEmpty) else { return }
        let owner = manager.generation
        configuringAutomatic = true
        defer { configuringAutomatic = false }
        let previous = backgroundTask
        if !enabled {
            backgroundAutomaticEnabled = false
            backgroundSuppressedScopes.insert(scope.cacheNamespace)
            previous?.cancel()
            await previous?.value
        }
        do {
            let journal = try await PhotoBackupRunCoordinator.perform(scope: scope) { [store] in
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                var journal = try await store.loadPhotoBackups(scope: scope)
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                try journal.setBackgroundAutomaticEnabled(enabled)
                try await store.updatePhotoBackupAutomationSettings(scope: scope, background: enabled)
                try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
                return journal
            }
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            if enabled {
                backgroundSuppressedScopes.remove(scope.cacheNamespace)
            }
            apply(journal, scope: scope, restoreConfiguration: false)
            statusMessage = enabled ? "系统后台备份已开启，等待 iOS 分配运行时间；仅使用本账户保存的相簿与 iCloud 规则。" : "系统后台备份已关闭并保存，队列和回执保留。"
        } catch {
            guard manager.generation == owner else { return }
            statusMessage = "后台备份开关未确认保存，请重新读取并明确设置；恢复资料保留。"
        }
    }

    /// enabled是对最近保存相簿/iCloud选项的明确同意；关闭先取消并等待真实任务，再持久保存关闭。
    /// 读取/写入错误可见且不上传；未保存草稿只影响页面，不借切换自动开关偷偷保存。
    func setForegroundAutomaticEnabled(_ enabled: Bool, using manager: LibraryManagementController) async {
        // 启用须读取过当前账号配置；冷启动自动周期可能先等待旧任务，明确关闭不能被尚未apply的配置挡回。
        guard !configuringAutomatic, let scope = manager.backupScope,
              !enabled || (configurationScope == scope && !running && !manager.busy && !requiresSelectionScan) else { return }
        let owner = manager.generation
        configuringAutomatic = true
        defer { configuringAutomatic = false }
        let previous = automaticTask, previousManual = task
        automaticEpoch = UUID(); automaticRequested = false
        automaticNetworkRecoveryRequested = false
        automaticWaitingForNetwork = false
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
                statusMessage = "已开启前台自动备份，使用最近保存的相簿与 iCloud 选项；失败、已尝试暂停及取消项仍需手动处理。"
                configuringAutomatic = false
                requestAutomaticWork()
            } else {
                statusMessage = "前台自动备份已关闭并保存；队列与已确认回执保留，需明确重新开启或手动继续。"
            }
        } catch {
            guard manager.generation == owner else { return }
            statusMessage = "自动备份开关未确认保存，当前自动任务已停止；请重新读取并明确设置。"
        }
    }

    /// 明确停止关闭并持久保存前台和系统后台规则；生命周期/到期取消不更改用户开关。
    func stopManually(using manager: LibraryManagementController) async {
        let owner = manager.generation
        let scope = manager.backupScope
        cancel()
        await setForegroundAutomaticEnabled(false, using: manager)
        guard manager.generation == owner, manager.backupScope == scope else { return }
        await setBackgroundAutomaticEnabled(false, using: manager)
        guard let scope, manager.generation == owner, manager.backupScope == scope else { return }
        do {
            let saved = try await store.loadPhotoBackups(scope: scope)
            try Task.checkCancellation(); try Self.validate(manager, owner: owner, scope: scope)
            statusMessage = saved.foregroundAutomaticEnabled != true && saved.backgroundAutomaticEnabled != true
                ? "已停止并关闭前台与系统后台备份，队列和回执保留。"
                : "已停止当前任务，自动开关尚未全部确认关闭；请重新读取并设置。"
        } catch {
            guard manager.generation == owner else { return }
            statusMessage = "已停止当前任务，但自动开关未确认保存；请重新读取并设置。"
        }
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
              !(requiresSelectionScan && configurationScope == scope), !configuringAutomatic,
              !automaticWaitingForNetwork else { return nil }
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
                // inactive退休任务不可消费刚由App前台路由暂存、待同一scene恢复的网络事件。
                guard automaticActive else { return }
                automaticRequested = false
                let networkRecovery = automaticNetworkRecoveryRequested
                let consumedNetworkEvent = networkRecovery ? lastValidatedNetworkRecoveryEvent : nil
                automaticNetworkRecoveryRequested = false
                guard let manager = automaticManager, let scope = automaticScope, automaticActive,
                      manager.backupScope == scope, !automaticSuppressedScopes.contains(scope.cacheNamespace),
                      !running, !manager.busy, !configuringAutomatic, !(requiresSelectionScan && configurationScope == scope),
                      !automaticWaitingForNetwork || networkRecovery else { return }
                let owner = manager.generation
                let authorization = authorizationStatus()
                guard authorization == .authorized || authorization == .limited else {
                    statusMessage = "前台自动备份等待已有照片授权，不会主动弹出授权或修改 iCloud 选项。"
                    return
                }
                do {
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    let saved = try await store.loadPhotoBackups(scope: scope)
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    // 首次读取期间用户可能已开始明确手动操作；自动周期不能在await后抢占其Coordinator或运行状态。
                    guard !running, !manager.busy, !configuringAutomatic else { return }
                    foregroundAutomaticEnabled = saved.foregroundAutomaticEnabled == true
                    foregroundNetworkRecoveryEnabled = saved.foregroundNetworkRecoveryEnabled == true
                    backgroundAutomaticEnabled = saved.backgroundAutomaticEnabled == true && !backgroundSuppressedScopes.contains(scope.cacheNamespace)
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
                        let snapshots = try await albumScanner(selection.included.union(selection.excluded))
                        let scan = try await Self.planAlbumScan(selection, snapshots: snapshots)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        try journal.applyAutomaticAlbumScan(scan)
                        let verificationIDs: Set<UUID> = networkRecovery && journal.foregroundNetworkRecoveryEnabled == true
                            ? Set(journal.jobs.filter { $0.stage == .failed && $0.failure == .network }.map(\.id)) : []
                        if networkRecovery, journal.foregroundNetworkRecoveryEnabled == true {
                            try journal.resumeNetworkFailures(scan)
                        }
                        try await store.savePhotoBackups(journal, scope: scope)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        apply(journal, scope: scope)
                        automaticRunning = true
                        total = journal.jobs.count { $0.stage == .queued }
                        completed = 0; duplicates = 0; failed = 0; processed = 0
                        guard let client = manager.client else { throw LibraryWriteError.unavailable }
                        let cloud = journal.allowCloud
                        let attempted = Set(journal.jobs.filter { $0.stage == .queued }.map(\.id))
                        let result = try await manager.perform(publishChange: false) { [self, journal] _ in
                            let plan = try await prepareContinuity(journal, manager: manager, owner: owner, scope: scope, client: client, verificationIDs: verificationIDs)
                            try await validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                            return try await PhotoBackupWorker(store: store, exporter: exporter).run(
                                scope: scope, userID: client.userID, allowCloud: cloud, client: retryingUploader(client, manager: manager, owner: owner, scope: scope),
                                preflight: plan,
                                // cleanup仍须在Task取消后保存安全暂停；正常Worker检查点先检查Task取消。
                                validateContext: {
                                    try Self.validate(manager, owner: owner, scope: scope)
                                    guard self.authorizationStatus() == authorization else { throw AlbumReadError.permission }
                                },
                                progress: { [self] _, value in
                                    completed = value.completed; duplicates = value.duplicates; failed = value.failed
                                    processed = value.completed + value.failed + value.skipped + value.review
                                }
                            )
                        }
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        var current = try await store.loadPhotoBackups(scope: scope)
                        try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                        if result.stopped || result.failed > 0 {
                            let failures = current.jobs.filter { attempted.contains($0.id) && $0.stage == .failed }
                            if current.foregroundNetworkRecoveryEnabled == true, !failures.isEmpty,
                               failures.allSatisfy({ $0.failure == .network })
                            {
                                // 保留明确同意，但本轮停止；Photos/管理通知不能形成网络重试循环。
                                let newerEvent = automaticNetworkRecoveryRequested && lastValidatedNetworkRecoveryEvent != consumedNetworkEvent
                                automaticWaitingForNetwork = !newerEvent; automaticRequested = newerEvent
                                if !newerEvent {
                                    automaticNetworkRecoveryRequested = false
                                }
                            } else {
                                try current.setForegroundAutomaticEnabled(false)
                                try await store.savePhotoBackups(current, scope: scope)
                                try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                                automaticSuppressedScopes.insert(scope.cacheNamespace)
                                automaticMonitor?.stop(); automaticMonitor = nil; automaticRequested = false
                            }
                        }
                        apply(current, scope: scope)
                        return result
                    }
                    try validateAutomatic(manager, owner: owner, scope: scope, epoch: epoch, authorization: authorization)
                    if result.completed > 0 {
                        manager.publishChanges(ifGeneration: owner)
                    }
                    if automaticWaitingForNetwork {
                        statusMessage = "连接失败，等待新的网络路由验证后再核查；未立即重发上传。"
                    } else if result.stopped || result.failed > 0 {
                        statusMessage = foregroundAutomaticEnabled ? "连接恢复，正在核对待处理照片。" : "本轮有失败或未知结果，前台自动备份已关闭；请先手动检查，未自动重试。"
                    } else {
                        statusMessage = "前台自动备份已确认 \(result.completed) 项；等待新的照片库变更。"
                    }
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
                        statusMessage = "前台自动备份已关闭；相簿、权限或未确认结果需明确检查后再开启，未自动重试。"
                    } else {
                        statusMessage = "前台自动备份已停止，关闭开关未确认保存；恢复资料保留，请明确检查。"
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
            try await store.updatePhotoBackupAutomationSettings(scope: scope, foreground: enabled)
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
