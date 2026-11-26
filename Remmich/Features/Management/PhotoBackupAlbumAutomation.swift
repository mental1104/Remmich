import Foundation
import Observation
import Photos

/// 自动相簿组织的窄驱动；默认关闭，前台事件或有效processing租约只调同一计划/成员链，不另造上传队列。
@MainActor @Observable final class PhotoBackupAlbumAutomation {
    private(set) var enabled = false
    private(set) var configuring = false
    private(set) var running = false
    /// 当前语言只影响展示；保留原任务、源版本和账号代际。
    var status: String {
        L10n.text(statusMessage)
    }

    private(set) var statusMessage: String.LocalizationValue = "自动相簿同步默认关闭；仅前台或已开启系统后台时使用保存的映射与相簿规则。"
    @ObservationIgnored private let sync: PhotoBackupAlbumSyncController
    @ObservationIgnored private let backup: PhotoBackupController
    @ObservationIgnored private let matching: LocalMediaMatchController
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let authorization: @MainActor () -> PHAuthorizationStatus
    @ObservationIgnored private let observePhotos: Bool
    @ObservationIgnored private weak var manager: LibraryManagementController?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var scope: MediaAccountScope?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var monitor: LocalPhotoChangeMonitor?
    @ObservationIgnored private var ownManagementRevision: Int?
    @ObservationIgnored private var suppressedScopes: Set<String> = []

    /// sync/backup/matching为Media同一实例，store仍真实账号SQLite；授权/观察端口只替换Photos边界供回归。
    init(sync: PhotoBackupAlbumSyncController, backup: PhotoBackupController, matching: LocalMediaMatchController,
         store: SQLiteLibraryIndexStore = .init(), authorization: @escaping @MainActor () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) }, observePhotos: Bool = true)
    {
        self.sync = sync; self.backup = backup; self.matching = matching; self.store = store; self.authorization = authorization; self.observePhotos = observePhotos
    }

    /// scope来自已认证Media，active只表示真实scene前台；旧代际完全退役后才能接新事件，不伪装OS后台。
    @discardableResult func conditionsChanged(using manager: LibraryManagementController, scope next: MediaAccountScope?, active: Bool? = nil) -> Task<Void, Never>? {
        let nextActive = active ?? self.active
        guard self.manager !== manager || owner != manager.generation || scope != next || self.active != nextActive else { return task }
        let previous = task
        previous?.cancel()
        if running {
            sync.cancel()
        }
        monitor?.stop(); monitor = nil
        epoch = UUID(); pending = nextActive
        if scope != next {
            enabled = false
        }
        self.manager = manager; owner = manager.generation; scope = next; self.active = nextActive; ownManagementRevision = nil
        return launch(after: previous)
    }

    /// 上传真正退役、匹配/映射变化、Photos变化共用一次合并请求；没有相簿POST或原片传输后备路径。
    @discardableResult func contentsChanged() -> Task<Void, Never>? {
        guard active, !configuring, let manager, manager.backupScope == scope else { return nil }
        pending = true
        if let task {
            return task
        }
        return launch(after: nil)
    }

    /// 普通管理写入后允许重核；本驱动自己的publish不构成新照片事件，避免自激无限扫描。
    @discardableResult func managementChanged(_ revision: Int) -> Task<Void, Never>? {
        guard !running, revision != ownManagementRevision else { return task }
        return contentsChanged()
    }

    /// 用户明确开关独立账号意愿；关闭先撤销本驱动，再原子持久false，不用Coordinator打断其他上传/手动创建。
    func setEnabled(_ value: Bool, using manager: LibraryManagementController) async {
        let cachedScope = !value && self.manager === manager && owner == manager.generation ? scope : nil
        guard !configuring, let scope = manager.backupScope ?? cachedScope, self.manager === manager, self.scope == scope, owner == manager.generation else { return }
        let owner = manager.generation
        if value {
            let access = authorization()
            guard backup.hasCurrentSavedSelection(using: manager), access == .authorized || access == .limited else { return }
        }
        configuring = true
        defer { configuring = false }
        let previous = task
        previous?.cancel()
        if running {
            sync.cancel()
        }
        epoch = UUID(); pending = false; monitor?.stop(); monitor = nil
        let settingRun = epoch
        if !value {
            enabled = false; suppressedScopes.insert(scope.cacheNamespace)
        }
        do {
            let saved = try await store.setPhotoBackupAlbumSyncAutomaticEnabled(value, scope: scope)
            try Task.checkCancellation()
            guard manager.generation == owner, self.scope == scope else { throw CancellationError() }
            enabled = saved.automaticEnabled
            if value {
                suppressedScopes.remove(scope.cacheNamespace)
            }
            statusMessage = value ? "已开启自动增量补入；仅前台或有效系统后台备份租约处理安全新关系，不创建或重试未知/失败/取消项。" : "自动规则已关闭并保存；已发送请求仍可能已保存，其他实例在下次检查时停止，不回滚已有成员。"
        } catch {
            if manager.generation == owner {
                statusMessage = "自动相簿开关未确认保存；请重读并明确设置，不自动扩大同步范围。"
            }
        }
        await previous?.value
        guard manager.generation == owner, self.scope == scope else { return }
        guard epoch == settingRun else {
            configuring = false
            if active {
                contentsChanged()
            }
            return
        }
        task = nil
        configuring = false
        if enabled {
            contentsChanged()
        }
    }

    /// processing备份及其RunCoordinator已完全退役后同一租约await调用；不构造Media或伪装foreground。
    /// 不全库扫描/hash，不弹授权，不从iCloud/Immich下载原片；已选择RAW可依原规则读取本机双原图摘要。
    /// validateLease由现系统Coordinator检查当前租约/账号/端点和后台同意；取消会传给实际组织Task。
    static func performBackground(backup: PhotoBackupController, using manager: LibraryManagementController, scope: MediaAccountScope,
                                  validateLease: @escaping @MainActor () throws -> Void, store: SQLiteLibraryIndexStore = .init()) async throws -> Bool
    {
        try Task.checkCancellation(); try validateLease()
        guard manager.backupScope == scope else { throw CancellationError() }
        let saved = try await store.loadPhotoBackupAlbumSync(scope: scope)
        try Task.checkCancellation(); try validateLease()
        guard saved.automaticEnabled else { return true }
        let matching = LocalMediaMatchController(observeChanges: false)
        try await matching.restoreForAlbumOrganization(using: manager, scope: scope)
        try Task.checkCancellation(); try validateLease()
        let sync = PhotoBackupAlbumSyncController(matching: matching, store: store)
        let driver = PhotoBackupAlbumAutomation(sync: sync, backup: backup, matching: matching, store: store, observePhotos: false)
        return try await driver.performBackground(using: manager, scope: scope, validateLease: validateLease)
    }

    /// 注入同一真实Controller的后台入口供租约和回归使用；active必须保持false，每await后同时核租约和固定owner。
    func performBackground(using manager: LibraryManagementController, scope: MediaAccountScope, validateLease: @escaping @MainActor () throws -> Void) async throws -> Bool {
        guard !active, !running, !configuring, task == nil else { throw LibraryWriteError.busy }
        let owner = manager.generation
        let check: @MainActor () throws -> Void = {
            try Task.checkCancellation(); try validateLease()
            guard !self.active, manager.generation == owner, manager.backupScope == scope else { throw CancellationError() }
        }
        defer { running = false; sync.cancel() }
        return try await cycle(using: manager, scope: scope, check: check)
    }

    /// 调用方拥有本次实际组织Task；停止等待时也取消它，不能仅取消外层waiter后任其落迟到成功。
    private func awaitOwned(_ work: Task<Void, Never>) async throws {
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
    }

    /// 前台和processing复用唯一周期；只有保存同意、当前授权/配置/上下文成立才调真实prepare/synchronize。
    /// 返回true表示安全候选全部完成或当前无新关系；失败/部分不伪称完成，历史异常仍由计划门禁保留。
    private func cycle(using manager: LibraryManagementController, scope: MediaAccountScope, check: @escaping @MainActor () throws -> Void) async throws -> Bool {
        await backup.waitForCurrentWork(); try check()
        guard !backup.running, !backup.configuringAutomatic, !manager.busy, !matching.running, !sync.running, !sync.loading, !sync.prepared else { pending = true; return false }
        let saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
        enabled = saved.automaticEnabled && !suppressedScopes.contains(scope.cacheNamespace)
        guard enabled else { monitor?.stop(); monitor = nil; return true }
        let access = authorization()
        guard access == .authorized || access == .limited else { statusMessage = "自动相簿等待已有照片授权；不主动弹框，不从iCloud或Immich下载原片。"; return false }
        if active, observePhotos, monitor == nil {
            monitor = LocalPhotoChangeMonitor { [weak self] in self?.contentsChanged() }
        }
        await backup.load(using: manager); try check()
        guard backup.hasCurrentSavedSelection(using: manager), !manager.busy else { pending = true; return false }
        running = true
        await sync.load(using: manager, backup: backup); try check()
        guard let preparation = sync.prepare(using: manager, backup: backup, automatic: true, validateExternal: check) else { pending = true; return false }
        try await awaitOwned(preparation); try check()
        guard sync.prepared else { statusMessage = sync.statusMessage; return false }
        let planned = sync.previewCount
        guard planned > 0 else {
            sync.cancel(); statusMessage = "本次没有安全的新相簿关系；失败/未知/取消及部分回执仍保留手动核查。"
            return true
        }
        guard let work = sync.synchronize(using: manager, backup: backup, automatic: true, validateExternal: check) else { pending = true; return false }
        try await awaitOwned(work); try check()
        statusMessage = sync.statusMessage
        return sync.processed == planned && sync.confirmed == planned
    }

    /// after是已撤销的旧驱动；不能取消其等待中的备份任务，切代后先等退役再检查epoch，防旧defer污染新任务。
    private func launch(after previous: Task<Void, Never>?) -> Task<Void, Never> {
        let run = epoch
        let current = Task { [self] in
            defer {
                if epoch == run {
                    task = nil; running = false
                    // 运行期间的Photos/匹配事件只在实际退役后再接一轮；忙门仍占用时等其真实外部事件，不自旋。
                    if !Task.isCancelled, pending, active, enabled, !configuring, let manager, manager.backupScope == scope,
                       backup.hasCurrentSavedSelection(using: manager), !backup.running, !backup.configuringAutomatic, !manager.busy, !matching.running,
                       !sync.running, !sync.loading, !sync.prepared, authorization() == .authorized || authorization() == .limited
                    {
                        Task { [weak self] in self?.contentsChanged() }
                    }
                }
            }
            await previous?.value
            // 开关原子写可能与scene/账号交接重叠；等待其完成，不消费新上下文的pending或打断上传。
            do {
                while configuring {
                    try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
                }
            } catch { return }
            guard !Task.isCancelled, epoch == run else { return }
            while pending {
                guard !Task.isCancelled, epoch == run else { return }
                pending = false
                guard let manager, let scope, active, manager.backupScope == scope, !configuring else { return }
                let owner = manager.generation
                let check: @MainActor () throws -> Void = {
                    try Task.checkCancellation()
                    guard self.epoch == run, self.active, self.scope == scope, manager.generation == owner, manager.backupScope == scope else { throw CancellationError() }
                }
                do {
                    let matchingStamp = matching.revision
                    let completed = try await cycle(using: manager, scope: scope, check: check)
                    ownManagementRevision = manager.revision
                    if matching.revision != matchingStamp {
                        pending = true
                    }
                    running = false
                    if !completed {
                        return
                    }
                } catch {
                    guard epoch == run, manager.generation == owner else { return }
                    running = false
                    statusMessage = "本轮自动相簿已停止；未知/失败/取消项保留，需手动核查，不自动重放。"
                    return
                }
            }
        }
        task = current
        return current
    }
}
