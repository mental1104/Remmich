import Foundation
import Observation

/// 单资源元数据确认与写回状态机；每次写前真实预检，写后重读，不建立自动重试或持久草稿队列。
@MainActor @Observable
final class AssetMetadataStore {
    private(set) var snapshot: AssetMetadataSnapshot?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var hasFreshData = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var confirmedChanges = 0
    private(set) var savedAccountGeneration: UUID?
    private(set) var isCheckingDateProjection = false
    private(set) var dateProjectionNotice: String?
    private var generation = UUID()
    private var readAccountGeneration: UUID?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var dateCheckTask: Task<Void, Never>?
    private var dateCheckID = UUID()
    private var writeWasSent = false
    private var writeWasConfirmed = false

    /// manager是当前账号边界；取消页面工作并清除旧快照。已发送且同账号的未知写入使读者失效一次。
    func invalidate(manager: LibraryManagementController) {
        if writeWasSent, let owner = readAccountGeneration {
            manager.publishChanges(ifGeneration: owner)
        }
        generation = UUID()
        readTask?.cancel(); writeTask?.cancel(); dateCheckTask?.cancel()
        readTask = nil; writeTask = nil
        snapshot = nil; readAccountGeneration = nil; hasFreshData = false
        isLoading = false; isWorking = false; error = nil; notice = nil
        writeWasSent = false; writeWasConfirmed = false
        savedAccountGeneration = nil; confirmedChanges = 0
        dateCheckTask = nil; dateCheckID = UUID(); isCheckingDateProjection = false; dateProjectionNotice = nil
    }

    /// assetID指定真实资源，manager指定账号；返回可等待读任务，失败不伪造空EXIF或恢复写权限。
    @discardableResult
    func reload(assetID: String, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        guard let client = manager.client else {
            error = AssetMetadataError.unavailable.errorDescription
            hasFreshData = false
            return nil
        }
        readTask?.cancel()
        dateCheckTask?.cancel(); dateCheckID = UUID(); isCheckingDateProjection = false; dateProjectionNotice = nil
        generation = UUID()
        let owner = generation
        let account = manager.generation
        snapshot = nil; hasFreshData = false; readAccountGeneration = nil
        isLoading = true; error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: account, manager: manager) {
                    isLoading = false; readTask = nil
                }
            }
            do {
                let result = try await client.assetMetadata(assetID)
                try Task.checkCancellation()
                guard isCurrent(owner, account: account, manager: manager) else { return }
                snapshot = result; hasFreshData = true; readAccountGeneration = account
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = Self.failureMessage(error, reading: true)
            }
        }
        readTask = task
        return task
    }

    /// patch只包含用户明确修改项；返回绑定快照/双代际的确认，尚不发送HTTP。
    func prepare(_ patch: AssetMetadataPatch, manager: LibraryManagementController) throws -> AssetMetadataPlan {
        guard hasFreshData, !isLoading, !isWorking, !isCheckingDateProjection, !manager.busy, readAccountGeneration == manager.generation,
              let snapshot, let client = manager.client else { throw AssetMetadataError.reloadRequired }
        try Self.requireWritable(snapshot, userID: client.userID)
        try patch.validate()
        return .init(baseline: snapshot, patch: patch, readGeneration: generation, accountGeneration: manager.generation)
    }

    /// plan为用户确认的固定补丁；返回实际任务。先GET预检再PUT，所有错误都不自动重发。
    @discardableResult
    func start(_ plan: AssetMetadataPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              hasFreshData, !isLoading, !isWorking, !isCheckingDateProjection, !manager.busy
        else {
            error = AssetMetadataError.reloadRequired.errorDescription
            return nil
        }
        generation = UUID()
        let owner = generation
        hasFreshData = false; isWorking = true; error = nil; notice = nil
        writeWasSent = false; writeWasConfirmed = false
        let task = Task { [weak self] in
            guard let self else { return }
            var refreshReaders = false
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    if writeWasConfirmed || refreshReaders {
                        manager.publishChanges(ifGeneration: plan.accountGeneration)
                    }
                    if writeWasConfirmed {
                        savedAccountGeneration = plan.accountGeneration; confirmedChanges += 1
                    }
                    let dateToCheck = writeWasConfirmed ? plan.patch.date : nil
                    writeWasSent = false; writeWasConfirmed = false
                    isWorking = false; writeTask = nil
                    if let dateToCheck, manager.metadataDateRefreshAvailable {
                        checkDateProjection(baseline: plan.baseline, expectedInstant: dateToCheck.instant, manager: manager)
                    }
                }
            }
            do {
                let current = try await manager.perform(publishChange: false) { client in
                    let fresh = try await client.assetMetadata(plan.baseline.id)
                    try Task.checkCancellation()
                    try await self.preflight(fresh, plan: plan, owner: owner, manager: manager, userID: client.userID)
                    try await self.markSent(owner: owner, account: plan.accountGeneration, manager: manager)
                    let response = try await client.updateAssetMetadata(plan.baseline.id, patch: plan.patch)
                    try await self.markConfirmed(response, plan: plan, owner: owner, manager: manager)
                    let readback = try await client.assetMetadata(plan.baseline.id)
                    try Task.checkCancellation()
                    guard plan.patch.isConfirmed(by: readback), readback.ownerId.lowercased() == client.userID.lowercased(),
                          !readback.isTrashed, readback.type == plan.baseline.type,
                          readback.livePhotoVideoId == plan.baseline.livePhotoVideoId else { throw AssetMetadataError.changedRemotely }
                    return readback
                }
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager), !Task.isCancelled else { return }
                snapshot = current; hasFreshData = true; readAccountGeneration = plan.accountGeneration
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                if writeWasConfirmed {
                    self.error = "Changes were saved, but current metadata could not be confirmed. Reload before another change."
                } else {
                    self.error = Self.failureMessage(error, reading: false)
                    refreshReaders = writeWasSent && Self.mayHaveChanged(error)
                }
            }
        }
        writeTask = task
        return task
    }

    /// 停止当前读取或写入等待；已发送写请求的结果可能未知，完成后须显式重载，不自动回滚或重发。
    func cancel() {
        readTask?.cancel()
        writeTask?.cancel()
        dateCheckTask?.cancel()
    }

    /// 用户显式重试当前服务器日期的时间线刷新；缺失日期/过期快照不猜值，也不重新PUT。
    @discardableResult
    func refreshTimelineDate(manager: LibraryManagementController) -> Task<Void, Never>? {
        guard hasFreshData, !isLoading, !isWorking, !isCheckingDateProjection,
              readAccountGeneration == manager.generation, let snapshot,
              let instant = AssetMetadataDateValue.parse(snapshot.exifInfo?.dateTimeOriginal)
        else {
            dateProjectionNotice = "Reload a valid server capture date before requesting timeline refresh."
            return nil
        }
        return checkDateProjection(baseline: snapshot, expectedInstant: instant, manager: manager)
    }

    /// 最多3次真实详情读取、间隔1秒；metadata/fileCreatedAt/localDateTime一致才发布当前投影，不声称后台队列完成。
    @discardableResult
    private func checkDateProjection(baseline: AssetMetadataSnapshot, expectedInstant: Date,
                                     manager: LibraryManagementController) -> Task<Void, Never>?
    {
        guard manager.metadataDateRefreshAvailable, let client = manager.client,
              readAccountGeneration == manager.generation else { return nil }
        dateCheckTask?.cancel()
        let token = UUID(); dateCheckID = token
        let page = generation; let account = manager.generation
        isCheckingDateProjection = true
        dateProjectionNotice = "Checking the server's capture date before refreshing the timeline."
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if dateCheckID == token, isCurrent(page, account: account, manager: manager) {
                    isCheckingDateProjection = false; dateCheckTask = nil
                }
            }
            do {
                for attempt in 0 ..< 3 {
                    try Task.checkCancellation()
                    guard dateCheckID == token, isCurrent(page, account: account, manager: manager) else { return }
                    let fresh = try await client.assetMetadata(baseline.id)
                    try Task.checkCancellation()
                    guard dateCheckID == token, isCurrent(page, account: account, manager: manager) else { return }
                    try Self.requireWritable(fresh, userID: client.userID)
                    guard fresh.type == baseline.type, fresh.livePhotoVideoId == baseline.livePhotoVideoId else {
                        throw AssetMetadataError.changedRemotely
                    }
                    snapshot = fresh; hasFreshData = true; readAccountGeneration = account
                    if let projection = AssetMetadataDateProjection.confirmed(fresh, expectedInstant: expectedInstant,
                                                                              accountGeneration: account)
                    {
                        if projection.visibility != "timeline" {
                            dateProjectionNotice = "The current server date matches. This asset is outside the main timeline."
                        } else if manager.requestMetadataDateRefresh(projection) {
                            dateProjectionNotice = "The current server date matches. A timeline refresh was requested; processing can still change the date later."
                        } else {
                            dateProjectionNotice = "The server date matches, but timeline refresh is unavailable in this context."
                        }
                        return
                    }
                    if attempt < 2 {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                dateProjectionNotice = "The server date is not ready for timeline refresh. Retry after processing; no further change was sent."
            } catch {
                guard dateCheckID == token, isCurrent(page, account: account, manager: manager) else { return }
                dateProjectionNotice = Task.isCancelled
                    ? "Date checking stopped. Timeline refresh remains unconfirmed; retry when ready."
                    : "The timeline date could not be checked. Reload server metadata and retry; no further change was sent."
            }
        }
        dateCheckTask = task
        return task
    }

    /// message仅为本地安全说明；例如用户输入不完整，不能传入服务端正文/私人路径。
    func showError(_ message: String) {
        error = message
    }

    /// fresh为写前真实GET；plan为确认时快照，owner/manager/userID核对当前页面和认证身份。
    private func preflight(_ fresh: AssetMetadataSnapshot, plan: AssetMetadataPlan, owner: UUID,
                           manager: LibraryManagementController, userID: String) throws
    {
        try Task.checkCancellation()
        guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { throw LibraryWriteError.changedAccount }
        try Self.requireWritable(fresh, userID: userID)
        guard fresh == plan.baseline else { throw AssetMetadataError.changedRemotely }
    }

    /// owner/account绑定真实发送阶段；取消或失效不得继续从预检进入PUT。
    private func markSent(owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try Task.checkCancellation()
        guard isCurrent(owner, account: account, manager: manager) else { throw LibraryWriteError.changedAccount }
        writeWasSent = true
    }

    /// response已通过客户端200/字段确认；仍核对媒体身份/关联，旧页面不能发布成功或改变其他上下文。
    private func markConfirmed(_ response: AssetMetadataSnapshot, plan: AssetMetadataPlan, owner: UUID,
                               manager: LibraryManagementController) throws
    {
        guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { throw LibraryWriteError.changedAccount }
        guard response.type == plan.baseline.type, response.livePhotoVideoId == plan.baseline.livePhotoVideoId else {
            throw LibraryWriteError.malformedResponse
        }
        writeWasConfirmed = true; notice = "Changes saved. Reload after processing to verify final metadata; timeline ordering may update later."
    }

    /// owner/account为任务启动快照；返回当前页面是否仍有发布权。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        generation == owner && manager.generation == account
    }

    /// snapshot为真实单资源快照，userID是认证拥有者；共享读取不能授予写权限，回收站资源先恢复。
    private nonisolated static func requireWritable(_ snapshot: AssetMetadataSnapshot, userID: String) throws {
        guard snapshot.ownerId.lowercased() == userID.lowercased() else { throw AssetMetadataError.notOwned }
        guard !snapshot.isTrashed else { throw AssetMetadataError.trashed }
    }

    /// error为未确认PUT的结果；HTTP拒绝无需通知其他页面，网络/错误成功码等可能已写入，保守要求重读。
    private nonisolated static func mayHaveChanged(_ error: any Error) -> Bool {
        if case LibraryWriteError.http(400 ..< 500) = error {
            return false
        }
        return true
    }

    /// reading区分加载与写入说明；只有稳定本地原因可显示，不泄露响应正文或坐标。
    private nonisolated static func failureMessage(_ error: any Error, reading: Bool) -> String {
        if let error = error as? AssetMetadataError {
            return error.errorDescription ?? "Reload the asset before another change."
        }
        switch error {
        case LibraryWriteError.http(401): return "Sign in again before changing metadata."
        case LibraryWriteError.http(403): return "This account does not have permission to change this asset."
        case LibraryWriteError.http(404): return "The asset is no longer available. Reload before another change."
        case LibraryWriteError.http(409): return "The asset changed. Reload and review your changes again."
        case LibraryWriteError.http(429): return "Too many requests. Wait, then reload the asset."
        default: return reading ? "Metadata could not be loaded. Check permissions and connection." : "The change could not be confirmed. Reload before another change; do not repeat it blindly."
        }
    }
}
