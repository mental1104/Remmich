import Foundation
import Observation

/// 管理真实相簿分页、固定选择及逐项写回执；不持久化写队列，不自动重试未知结果。
@MainActor @Observable
final class BatchAssetManagementStore {
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var results: [BatchAssetItemResult] = []
    private(set) var operationTitle: String?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var isStopping = false
    private(set) var hasFreshData = false
    private(set) var error: String?
    private(set) var canLoadMore = false
    private var generation = UUID()
    private var album: BatchAlbumReference?
    private var scope: BatchAssetScope = .active
    private var query = TimelineQuery()
    private var reader: (any TimelineReading)?
    private var buckets: [TimelineBucketID] = []
    private var nextBucket = 0
    private var readTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    /// 返回当前已加载选择的稳定顺序；未加载的资源从不被“全选”暗中加入操作。
    var selectedAssets: [TimelineAssetSummary] {
        assets.filter { selectedIDs.contains($0.id) }
    }

    /// 账号/端点或页面失效后取消工作并清空全部选择与回执，旧响应失去发布权。
    func invalidate() {
        generation = UUID()
        readTask?.cancel()
        operationTask?.cancel()
        readTask = nil
        operationTask = nil
        assets = []
        selectedIDs = []
        results = []
        operationTitle = nil
        reader = nil
        buckets = []
        nextBucket = 0
        hasFreshData = false
        canLoadMore = false
        isLoading = false
        isWorking = false
        isStopping = false
        error = nil
    }

    /// album/scope固定读取范围，factory必须产生当前账号前台读源；返回可等待的本次任务。
    /// 重载不会重放写入，保留上次回执供核对，但清空选择并重新获取真实成员。
    @discardableResult
    func reload(album: BatchAlbumReference, scope: BatchAssetScope,
                factory: @escaping ManagementTimelineFactory, manager: LibraryManagementController) -> Task<Void, Never>?
    {
        guard !isWorking else { return nil }
        readTask?.cancel()
        generation = UUID()
        let owner = generation
        let account = manager.generation
        self.album = album
        self.scope = scope
        query = scope.query(albumID: album.id)
        let requestQuery = query
        assets = []
        selectedIDs = []
        reader = nil
        buckets = []
        nextBucket = 0
        canLoadMore = false
        hasFreshData = false
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { finishRead(owner: owner) }
            do {
                let source = try await factory()
                try Task.checkCancellation()
                guard isCurrent(owner, account: account, manager: manager) else { return }
                let summaries = try await source.bucketSummaries(query: requestQuery)
                try Task.checkCancellation()
                guard isCurrent(owner, account: account, manager: manager) else { return }
                var seen = Set<TimelineBucketID>()
                buckets = summaries.filter { $0.assetCount > 0 && seen.insert($0.id).inserted }.map(\.id)
                reader = source
                if !buckets.isEmpty {
                    try await appendPage(source: source, owner: owner, account: account, manager: manager)
                }
                guard isCurrent(owner, account: account, manager: manager) else { return }
                hasFreshData = true
                canLoadMore = nextBucket < buckets.count
            } catch { recordReadFailure(owner: owner, account: account, manager: manager) }
        }
        readTask = task
        return task
    }

    /// 只读取下一个真实时间桶；失败不推进位置，返回任务供显式调用者等待，不建立后台循环。
    @discardableResult
    func loadMore(manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isLoading, !isWorking, hasFreshData, canLoadMore, let reader else { return nil }
        let owner = generation
        let account = manager.generation
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { finishRead(owner: owner) }
            do { try await appendPage(source: reader, owner: owner, account: account, manager: manager) }
            catch { recordReadFailure(owner: owner, account: account, manager: manager) }
        }
        readTask = task
        return task
    }

    /// id必须来自已加载成员；enabled只改变本页选择，执行中不能修改确认快照。
    func select(_ id: String, enabled: Bool) {
        guard !isWorking, hasFreshData, assets.contains(where: { $0.id == id }) else { return }
        if enabled {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }

    /// 只选择已显示/加载资源，避免把尚未读取的整本相簿纳入批量写。
    func selectLoaded() {
        guard !isWorking, hasFreshData else { return }
        selectedIDs = Set(assets.map(\.id))
    }

    /// 清除当前选择，不取消或重放已经确认的操作。
    func clearSelection() {
        guard !isWorking else { return }
        selectedIDs = []
    }

    /// action和manager指定确认时的意图及账号；返回固定计划，前置条件失败不发送任何写入。
    func prepare(_ action: BatchAssetAction, manager: LibraryManagementController) throws -> BatchAssetPlan {
        guard manager.client != nil else { throw BatchAssetManagementError.unavailable }
        guard hasFreshData, !isLoading, !isWorking, !manager.busy else { throw BatchAssetManagementError.reloadRequired }
        guard let album, validID(album.id), !selectedAssets.isEmpty,
              selectedAssets.allSatisfy({ validID($0.id) }) else { throw BatchAssetManagementError.invalidSelection }
        guard action.accepts(scope: scope, count: selectedIDs.count), validTarget(action, album: album)
        else { throw BatchAssetManagementError.wrongScope }
        return .init(action: action, assets: selectedAssets, album: album, scope: scope,
                     readGeneration: generation, accountGeneration: manager.generation)
    }

    /// plan为已确认快照；返回实际串行任务。旧计划、未重载或并发写入一律不发送。
    @discardableResult
    func start(_ plan: BatchAssetPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              plan.album == album, plan.scope == scope,
              hasFreshData, !isLoading, !isWorking, !manager.busy,
              plan.action.accepts(scope: scope, count: plan.assets.count), validTarget(plan.action, album: plan.album)
        else { error = BatchAssetManagementError.reloadRequired.errorDescription; return nil }
        let availableIDs = Set(assets.map(\.id))
        guard !plan.assets.isEmpty, Set(plan.assets.map(\.id)).count == plan.assets.count,
              plan.assets.allSatisfy({ availableIDs.contains($0.id) && validID($0.id) })
        else { error = BatchAssetManagementError.invalidSelection.errorDescription; return nil }
        error = nil
        isWorking = true
        isStopping = false
        results = plan.assets.map { .init(asset: $0, state: .pending) }
        operationTitle = plan.action.title
        let task = Task { [weak self] in
            guard let self else { return }
            await execute(plan, manager: manager)
        }
        operationTask = task
        return task
    }

    /// 请求停止当前写入；正在发送的结果可能未知，完成后必须重新读取，剩余项不会自动发送。
    func cancel() {
        guard isWorking else { return }
        isStopping = true
        operationTask?.cancel()
    }

    /// message仅为本地可安全显示的说明，例如确认计划已失效；不记录服务端原始响应。
    func showError(_ message: String) {
        error = message
    }

    /// source是本次前台读源；只有当前读/账号代际的完整成功响应才能追加并推进桶位置。
    private func appendPage(source: any TimelineReading, owner: UUID, account: UUID,
                            manager: LibraryManagementController) async throws
    {
        guard isCurrent(owner, account: account, manager: manager) else { return }
        guard nextBucket < buckets.count else { canLoadMore = false; return }
        let bucket = buckets[nextBucket]
        let page = try await source.assets(in: bucket, query: query)
        try Task.checkCancellation()
        guard isCurrent(owner, account: account, manager: manager) else { return }
        guard page.allSatisfy({ validID($0.id) }) else { throw BatchAssetManagementError.invalidResponse }
        var seen = Set(assets.map(\.id))
        assets += page.filter { seen.insert($0.id).inserted }
        nextBucket += 1
        canLoadMore = nextBucket < buckets.count
    }

    /// plan为固定的资源/动作；逐项通过真实manager/client执行，未知结果立即停止发送后续项。
    private func execute(_ plan: BatchAssetPlan, manager: LibraryManagementController) async {
        guard isCurrent(plan.readGeneration, account: plan.accountGeneration, manager: manager) else { return }
        defer {
            if isCurrent(plan.readGeneration, account: plan.accountGeneration, manager: manager) {
                for index in results.indices where results[index].state == .pending {
                    results[index].state = .notAttempted
                }
                let affected = results.contains { $0.state == .succeeded || $0.state == .unconfirmed }
                if affected {
                    manager.publishChanges(ifGeneration: plan.accountGeneration)
                }
                selectedIDs.subtract(results.filter { $0.state == .succeeded }.map(\.id))
                hasFreshData = false
                canLoadMore = false
                isWorking = false
                isStopping = false
                operationTask = nil
            }
        }
        do {
            try await manager.perform(publishChange: false) { client in
                for asset in plan.assets {
                    guard !Task.isCancelled,
                          await self.isCurrent(plan.readGeneration, account: plan.accountGeneration, manager: manager) else { break }
                    if plan.action.requiresAssetOwnership, asset.ownerID.lowercased() != client.userID.lowercased() {
                        await self.record(.rejected(.notOwned), id: asset.id, plan: plan, manager: manager)
                        continue
                    }
                    await self.record(.running, id: asset.id, plan: plan, manager: manager)
                    do {
                        try await client.applyBatchAction(plan.action, to: asset.id)
                        try Task.checkCancellation()
                        await self.record(.succeeded, id: asset.id, plan: plan, manager: manager)
                    } catch {
                        let failure = BatchAssetFailure(error: error)
                        await self.record(failure.state, id: asset.id, plan: plan, manager: manager)
                        if failure.stopsBatch {
                            break
                        }
                    }
                }
            }
        } catch {
            guard isCurrent(plan.readGeneration, account: plan.accountGeneration, manager: manager), !Task.isCancelled else { return }
            self.error = "The operation could not be completed. Reload before another operation."
        }
    }

    /// state属于已发送/拒绝的单个id；旧账号或旧读源的回执不进入当前页面。
    private func record(_ state: BatchAssetItemState, id: String, plan: BatchAssetPlan,
                        manager: LibraryManagementController)
    {
        guard isCurrent(plan.readGeneration, account: plan.accountGeneration, manager: manager),
              let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].state = state
    }

    /// owner/account是读取或确认时的快照；返回当前页面与管理账号是否仍一致。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        owner == generation && account == manager.generation
    }

    /// owner对应本次读取；旧任务完成不得清除新任务的加载状态。
    private func finishRead(owner: UUID) {
        if owner == generation {
            isLoading = false; readTask = nil
        }
    }

    /// 读取失败只显示安全错误；取消/失效静默结束，成功加载的旧页保留以便显式重试。
    private func recordReadFailure(owner: UUID, account: UUID, manager: LibraryManagementController) {
        guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
        error = "Album photos could not be loaded. Check permissions and connection."
    }

    /// value为当前API使用的UUID v4；拒绝非法版本/variant，避免保存可见选择但发送无效ID。
    private func validID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuid.6 & 0xF0 == 0x40 && uuid.uuid.8 & 0xC0 == 0x80
    }

    /// action的目标相簿必须是合法身份；移出/封面只能指向产生当前成员列表的相簿。
    private func validTarget(_ action: BatchAssetAction, album: BatchAlbumReference) -> Bool {
        switch action {
        case let .addToAlbum(target): validID(target.id)
        case let .removeFromAlbum(target), let .albumCover(target):
            validID(target.id) && target.id.lowercased() == album.id.lowercased()
        default: true
        }
    }
}
