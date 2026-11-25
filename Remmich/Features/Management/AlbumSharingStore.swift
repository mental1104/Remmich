import Foundation
import Observation

/// 共享相簿一次确认的生命周期；所有写后状态来自fresh读取，不把HTTP受理或本地数组修改当成成功。
@MainActor @Observable final class AlbumSharingStore {
    private(set) var albums: [AlbumSharingSnapshot] = []
    private(set) var snapshot: AlbumSharingSnapshot?
    private(set) var users: [AlbumSharingUser] = []
    private(set) var selectedID: String?
    private(set) var hasFreshData = false
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var generation = UUID()
    private var accountGeneration: UUID?
    private var operation: Task<Void, Never>?
    private var writeWasSent = false

    /// 退出/后台/换号退休当前读写；已发送的同账号未知操作仅通知读者失效，绝不自动再次发出。
    func invalidate(manager: LibraryManagementController) {
        if writeWasSent, let accountGeneration {
            manager.publishChanges(ifGeneration: accountGeneration)
        }
        generation = UUID(); operation?.cancel(); operation = nil
        albums = []; snapshot = nil; users = []; selectedID = nil; accountGeneration = nil
        hasFreshData = false; isLoading = false; isWorking = false; writeWasSent = false; error = nil; notice = nil
    }

    /// albumID是用户当前选择，可空时保留当前或选第一个；仅fresh完整读后开放写，不自动执行任何更改。
    @discardableResult func reload(albumID: String? = nil, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking, let client = manager.client else { return nil }
        operation?.cancel(); generation = UUID()
        let owner = generation; let account = manager.generation; let wanted = albumID ?? selectedID
        snapshot = nil; users = []; hasFreshData = false; isLoading = true; error = nil; notice = nil
        writeWasSent = false; accountGeneration = account
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: account, manager: manager) {
                    isLoading = false; operation = nil
                }
            }
            do {
                let visible = try await client.sharingAlbums()
                try requireCurrent(owner, account: account, manager: manager)
                albums = visible
                selectedID = visible.first(where: { $0.id.lowercased() == wanted?.lowercased() })?.id ?? visible.first?.id
                guard let selectedID else { hasFreshData = true; return }
                let fresh = try await client.sharingAlbum(selectedID)
                try requireCurrent(owner, account: account, manager: manager)
                let candidates = fresh.canManage(client.userID) ? try await client.sharingUsers() : []
                try requireCurrent(owner, account: account, manager: manager)
                snapshot = fresh; users = candidates; hasFreshData = true
                if !fresh.hasKnownRoles {
                    notice = "Unknown member roles are read-only. Reload after checking server compatibility."
                }
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = "Sharing could not be read completely. Check permissions and reload."
            }
        }
        operation = task; return task
    }

    /// 单成员意图须来自当前fresh快照及同一账号；这里只生成确认，不发送请求。
    func prepare(_ command: AlbumSharingCommand, manager: LibraryManagementController) throws -> AlbumSharingPlan {
        guard hasFreshData, !isLoading, !isWorking, !manager.busy, accountGeneration == manager.generation,
              let snapshot, let client = manager.client else { throw AlbumSharingError.reloadRequired }
        try snapshot.require(command, userID: client.userID, users: users)
        let name = snapshot.albumUsers.first { $0.id.lowercased() == command.userID.lowercased() }?.user.name
            ?? users.first { $0.id.lowercased() == command.userID.lowercased() }?.name ?? ""
        return .init(baseline: snapshot, command: command, memberName: name, readGeneration: generation, accountGeneration: manager.generation)
    }

    /// 消费一次已确认计划；fresh预检→精确写→fresh验证，每次await后检查取消和页面/账号代际，无自动重发。
    @discardableResult func start(_ plan: AlbumSharingPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              accountGeneration == plan.accountGeneration, snapshot == plan.baseline,
              hasFreshData, !isLoading, !isWorking, !manager.busy else { error = AlbumSharingError.reloadRequired.errorDescription; return nil }
        generation = UUID(); let owner = generation; let candidates = users
        hasFreshData = false; isWorking = true; error = nil; notice = nil; writeWasSent = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    isWorking = false; operation = nil
                }
            }
            do {
                let result = try await manager.perform(publishChange: false) { client in
                    let fresh = try await client.sharingAlbum(plan.baseline.id)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    guard fresh == plan.baseline else { throw AlbumSharingError.changed }
                    try fresh.require(plan.command, userID: client.userID, users: candidates)
                    try await self.markSent(owner, account: plan.accountGeneration, manager: manager)
                    try await client.changeAlbumSharing(plan.command, albumID: fresh.id)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    if case let .remove(id) = plan.command, id.lowercased() == client.userID.lowercased() {
                        // 本人退出后可能无权GET详情；只有fresh可见列表确实不含该相簿才确认，403/404不是成功证据。
                        let visible = try await client.sharingAlbums()
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard !visible.contains(where: { $0.id.lowercased() == fresh.id.lowercased() }) else { throw AlbumSharingError.changed }
                        return AlbumSharingConfirmation.left(visible)
                    }
                    let confirmed = try await client.sharingAlbum(fresh.id)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    guard confirmed.confirms(plan.command, from: plan.baseline) else { throw AlbumSharingError.changed }
                    return AlbumSharingConfirmation.album(confirmed)
                }
                try requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                manager.publishChanges(ifGeneration: plan.accountGeneration); writeWasSent = false
                switch result {
                case let .left(visible): albums = visible; snapshot = nil; selectedID = nil; users = []; notice = "Left album. Reload to select another album."
                case let .album(confirmed):
                    snapshot = confirmed; hasFreshData = true
                    if let index = albums.firstIndex(where: { $0.id.lowercased() == confirmed.id.lowercased() }) {
                        albums[index] = confirmed
                    }
                    notice = "Member change confirmed from fresh server data."
                }
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                if writeWasSent {
                    manager.publishChanges(ifGeneration: plan.accountGeneration); writeWasSent = false
                }
                hasFreshData = false; self.error = "The member change was not confirmed. Reload before making another change."
            }
        }
        operation = task; return task
    }

    /// 只展示本地安全说明，不展示未经处理的服务端响应、成员私人字段或端点。
    func showError(_ message: String) {
        error = message
    }

    /// 只在发布权仍有效时标记即将发写请求，用于后续未知结果和后台取消的读者失效通知。
    private func markSent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try requireCurrent(owner, account: account, manager: manager); writeWasSent = true
    }

    /// 同账号与页面代际同时成立才允许继续；Task取消独立传播，不能回退到旧上下文继续写。
    private func requireCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try Task.checkCancellation(); guard isCurrent(owner, account: account, manager: manager) else { throw CancellationError() }
    }

    /// account为发起时manager代际，owner为页面代际；暂时离线/换服务器同样退休旧请求。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        generation == owner && manager.generation == account && accountGeneration == account
    }
}

/// 写后确认只携带fresh快照或fresh退出列表；跨执行器传递时不携带View/任务或HTTP对象。
private nonisolated enum AlbumSharingConfirmation: Sendable {
    case album(AlbumSharingSnapshot)
    case left([AlbumSharingSnapshot])
}
