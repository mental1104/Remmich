import Foundation
import Observation

/// 伙伴共享的前台确认生命周期；方向、本人权限、未知结果和账号退休都不依赖旧Library浏览索引。
@MainActor @Observable final class PartnerSharingStore {
    private(set) var snapshot: PartnerSharingSnapshot?
    private(set) var users: [AlbumSharingUser] = []
    private(set) var hasFreshData = false
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var generation = UUID()
    private var accountGeneration: UUID?
    private var operation: Task<Void, Never>?
    private var writeWasSent = false
    private var writeAffectsTimeline = false

    /// 退出/后台/账号/路由变化清理当前页并退休旧请求；已发出的同账号未知写只发布读者失效，不能自动重放。
    func invalidate(manager: LibraryManagementController) {
        if writeWasSent, let accountGeneration {
            publishChange(manager: manager, account: accountGeneration)
        }
        generation = UUID(); operation?.cancel(); operation = nil; snapshot = nil; users = []
        accountGeneration = nil; hasFreshData = false; isLoading = false; isWorking = false; writeWasSent = false; writeAffectsTimeline = false; error = nil; notice = nil
    }

    /// 读取incoming/outgoing和已有账户候选，全部成功且同代际才开放操作；不会主动建立任何共享。
    @discardableResult func reload(manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking, let client = manager.client else { return nil }
        operation?.cancel(); generation = UUID(); let owner = generation; let account = manager.generation
        snapshot = nil; users = []; hasFreshData = false; isLoading = true; error = nil; notice = nil; accountGeneration = account; writeWasSent = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: account, manager: manager) {
                    isLoading = false; operation = nil
                }
            }
            do {
                let incoming = try await client.partnerSharing(.incoming); try requireCurrent(owner, account: account, manager: manager)
                let outgoing = try await client.partnerSharing(.outgoing); try requireCurrent(owner, account: account, manager: manager)
                let candidates = try await client.sharingUsers(); try requireCurrent(owner, account: account, manager: manager)
                snapshot = .init(incoming: incoming, outgoing: outgoing); users = candidates; hasFreshData = true
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = "Partner sharing could not be read completely. Check permissions and reload."
            }
        }
        operation = task; return task
    }

    /// command来自当前页用户明确动作；此处只冻结基线和目标姓名，尚不发送写请求。
    func prepare(_ command: PartnerSharingCommand, manager: LibraryManagementController) throws -> PartnerSharingPlan {
        guard hasFreshData, !isLoading, !isWorking, !manager.busy, accountGeneration == manager.generation,
              let snapshot, let client = manager.client else { throw PartnerSharingError.reloadRequired }
        try snapshot.require(command, userID: client.userID, users: users)
        let name = (snapshot.incoming + snapshot.outgoing).first { $0.id.lowercased() == command.userID.lowercased() }?.name
            ?? users.first { $0.id.lowercased() == command.userID.lowercased() }?.name ?? "Selected account"
        return .init(baseline: snapshot, command: command, name: name, readGeneration: generation, accountGeneration: manager.generation)
    }

    /// 仅消费一次确认：fresh双向预检→唯一精确写→fresh双向核对；任何未确认结果锁定直到显式reload。
    @discardableResult func start(_ plan: PartnerSharingPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation, accountGeneration == plan.accountGeneration,
              snapshot == plan.baseline, hasFreshData, !isLoading, !isWorking, !manager.busy else { showError(); return nil }
        generation = UUID(); let owner = generation
        hasFreshData = false; isWorking = true; error = nil; notice = nil; writeWasSent = false
        if case .timeline = plan.command {
            writeAffectsTimeline = true
        } else {
            writeAffectsTimeline = false
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    isWorking = false; operation = nil
                }
            }
            do {
                let confirmed = try await manager.perform(publishChange: false) { client in
                    let incoming = try await client.partnerSharing(.incoming)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    let outgoing = try await client.partnerSharing(.outgoing)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    let fresh = PartnerSharingSnapshot(incoming: incoming, outgoing: outgoing)
                    guard fresh == plan.baseline else { throw PartnerSharingError.changed }
                    let candidates: [AlbumSharingUser]
                    if case .add = plan.command {
                        candidates = try await client.sharingUsers()
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    } else {
                        candidates = []
                    }
                    try fresh.require(plan.command, userID: client.userID, users: candidates)
                    try await self.markSent(owner, account: plan.accountGeneration, manager: manager)
                    let receipt = try await client.changePartnerSharing(plan.command)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    let afterIncoming = try await client.partnerSharing(.incoming)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    let afterOutgoing = try await client.partnerSharing(.outgoing)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    let next = PartnerSharingSnapshot(incoming: afterIncoming, outgoing: afterOutgoing)
                    guard next.confirms(plan.command, receipt: receipt, from: plan.baseline) else { throw PartnerSharingError.changed }
                    return next
                }
                try requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                snapshot = confirmed; hasFreshData = true; writeWasSent = false
                publishChange(manager: manager, account: plan.accountGeneration)
                notice = "Partner sharing confirmed from fresh server data."
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                if writeWasSent {
                    publishChange(manager: manager, account: plan.accountGeneration); writeWasSent = false
                }
                snapshot = nil; hasFreshData = false; self.error = "The partner change was not confirmed. Reload before another action."
            }
        }
        operation = task; return task
    }

    /// 本地拒绝原因保持安全，不输出服务端原文、邮箱或端点。
    func showError() {
        error = "This partner action is unavailable. Reload and check the sharing direction."
    }

    /// 只有接收者timeline偏好需要全作用域核对调度；其他关系变化沿原管理revision，不伪称本地照片已更新。
    private func publishChange(manager: LibraryManagementController, account: UUID) {
        if writeAffectsTimeline {
            manager.publishPartnerTimelineChange(ifGeneration: account)
        } else {
            manager.publishChanges(ifGeneration: account)
        }
    }

    /// 在有效账号/页面内记录唯一写即将发送，供取消或未知回执时通知读者失效。
    private func markSent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try requireCurrent(owner, account: account, manager: manager); writeWasSent = true
    }

    /// 每个异步边界独立检查Task和当前身份，不能把取消当成继续向新服务器写入的理由。
    private func requireCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try Task.checkCancellation(); guard isCurrent(owner, account: account, manager: manager) else { throw CancellationError() }
    }

    /// owner为页面读取代际，account为管理账号/端点代际；两个条件均需成立才可发布状态。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        generation == owner && manager.generation == account && accountGeneration == account
    }
}
