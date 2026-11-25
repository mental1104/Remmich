import Foundation
import Observation

/// 相簿公开链接的前台生命周期；只有用户确认才写，一次写后必须fresh确认，未知结果禁重发并要求重读。
@MainActor @Observable final class AlbumPublicLinkStore {
    private(set) var albums: [AlbumSharingSnapshot] = []
    private(set) var album: AlbumSharingSnapshot?
    private(set) var links: [AlbumPublicLink] = []
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

    /// 退出/后台/换号退休所有读写并清敏感内存；同账号已发送的未知写入仅发布失效，不自动重试。
    func invalidate(manager: LibraryManagementController) {
        if writeWasSent, let accountGeneration {
            manager.publishChanges(ifGeneration: accountGeneration)
        }
        generation = UUID(); operation?.cancel(); operation = nil
        albums = []; album = nil; links = []; selectedID = nil; accountGeneration = nil
        hasFreshData = false; isLoading = false; isWorking = false; writeWasSent = false; error = nil; notice = nil
    }

    /// albumID可空时保留当前或第一个可见相簿；只读取当前账户自己创建的链接，不获取其他成员的密钥。
    @discardableResult func reload(albumID: String? = nil, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking, let client = manager.client else { return nil }
        operation?.cancel(); generation = UUID()
        let owner = generation; let account = manager.generation; let wanted = albumID ?? selectedID
        album = nil; links = []; hasFreshData = false; isLoading = true; error = nil; notice = nil
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
                albums = visible; selectedID = visible.first(where: { $0.id.lowercased() == wanted?.lowercased() })?.id ?? visible.first?.id
                guard let selectedID else { hasFreshData = true; return }
                let current = try await client.sharingAlbum(selectedID)
                try requireCurrent(owner, account: account, manager: manager)
                let ownLinks = try await client.albumPublicLinks(selectedID)
                try requireCurrent(owner, account: account, manager: manager)
                album = current; links = ownLinks; hasFreshData = true
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = "Public links could not be read completely. Check permissions and reload."
            }
        }
        operation = task; return task
    }

    /// command仅冻结一次确认，所有写选项完整规范化；创建依实际owner/editor，编辑撤销只认链接创建者。
    func prepare(_ command: AlbumPublicLinkCommand, manager: LibraryManagementController) throws -> AlbumPublicLinkPlan {
        guard hasFreshData, !isLoading, !isWorking, !manager.busy, accountGeneration == manager.generation,
              let album, let client = manager.client else { throw AlbumPublicLinkError.reloadRequired }
        let normalized: AlbumPublicLinkCommand
        switch command {
        case let .create(options):
            guard album.canManage(client.userID) else { throw AlbumPublicLinkError.permission }
            normalized = try .create(options.normalized(forCreation: true))
        case let .update(link, options):
            try requireOwned(link, userID: client.userID, albumID: album.id)
            normalized = try .update(link, options.normalized())
        case let .revoke(link):
            try requireOwned(link, userID: client.userID, albumID: album.id); normalized = .revoke(link)
        }
        return .init(album: album, baseline: links, command: normalized, readGeneration: generation, accountGeneration: manager.generation)
    }

    /// 消费当前计划：fresh权限/链接预检→唯一写→fresh详情和列表确认；每个await后核对Task/账号/页面。
    @discardableResult func start(_ plan: AlbumPublicLinkPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              accountGeneration == plan.accountGeneration, album == plan.album, links == plan.baseline,
              hasFreshData, !isLoading, !isWorking, !manager.busy else { error = "Reload public links before confirming another action."; return nil }
        generation = UUID(); let owner = generation
        hasFreshData = false; isWorking = true; error = nil; notice = nil; writeWasSent = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    isWorking = false; operation = nil
                }
            }
            do {
                let confirmed = try await manager.perform(publishChange: false) { client in
                    let receipt: AlbumPublicLink?
                    switch plan.command {
                    case let .create(options):
                        let freshAlbum = try await client.sharingAlbum(plan.album.id)
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard freshAlbum == plan.album, freshAlbum.canManage(client.userID) else { throw AlbumPublicLinkError.changed }
                        let existing = try await client.albumPublicLinks(plan.album.id)
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard existing == plan.baseline else { throw AlbumPublicLinkError.changed }
                        try await self.markSent(owner, account: plan.accountGeneration, manager: manager)
                        receipt = try await client.createAlbumPublicLink(plan.album.id, options: options)
                    case let .update(link, options):
                        let fresh = try await client.albumPublicLink(link.id, albumID: plan.album.id)
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard fresh == link else { throw AlbumPublicLinkError.changed }
                        try await self.markSent(owner, account: plan.accountGeneration, manager: manager)
                        receipt = try await client.updateAlbumPublicLink(link.id, albumID: plan.album.id, options: options)
                    case let .revoke(link):
                        let fresh = try await client.albumPublicLink(link.id, albumID: plan.album.id)
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard fresh == link else { throw AlbumPublicLinkError.changed }
                        try await self.markSent(owner, account: plan.accountGeneration, manager: manager)
                        try await client.revokeAlbumPublicLink(link.id); receipt = nil
                    }
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    var detail: AlbumPublicLink?
                    if let receipt {
                        let fresh = try await client.albumPublicLink(receipt.id, albumID: plan.album.id)
                        try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                        guard fresh.confirms(receipt) else { throw AlbumPublicLinkError.changed }
                        if case .create = plan.command, plan.baseline.contains(where: { $0.id.lowercased() == fresh.id.lowercased() }) {
                            throw AlbumPublicLinkError.changed
                        }
                        detail = fresh
                    }
                    let visible = try await client.albumPublicLinks(plan.album.id)
                    try await self.requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                    if let detail {
                        guard visible.contains(detail) else { throw AlbumPublicLinkError.changed }
                    } else if case let .revoke(link) = plan.command {
                        guard !visible.contains(where: { $0.id.lowercased() == link.id.lowercased() }) else { throw AlbumPublicLinkError.changed }
                    }
                    return visible
                }
                try requireCurrent(owner, account: plan.accountGeneration, manager: manager)
                links = confirmed; hasFreshData = true; writeWasSent = false
                manager.publishChanges(ifGeneration: plan.accountGeneration)
                notice = "Public link change confirmed from fresh server data."
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                if writeWasSent {
                    manager.publishChanges(ifGeneration: plan.accountGeneration); writeWasSent = false
                }
                links = []; hasFreshData = false; self.error = "The public link change was not confirmed. Reload before another action."
            }
        }
        operation = task; return task
    }

    /// 当前页本地失败说明不接收服务端原文、地址、密码或密钥。
    func showError() {
        error = "This public link action is unavailable. Reload and check the selected options."
    }

    /// 仅用户主动复制时调用；须仍是同账号fresh链接，不把旧页面的密钥用于新账号地址或自动写入剪贴板。
    func copyURL(for link: AlbumPublicLink, manager: LibraryManagementController) -> URL? {
        guard hasFreshData, !isLoading, !isWorking, accountGeneration == manager.generation,
              let album, let client = manager.client, (try? requireOwned(link, userID: client.userID, albumID: album.id)) != nil else { return nil }
        return link.copyURL(apiURL: client.apiURL)
    }

    /// link必须是当前fresh集合中的同一创建者/相簿对象；不接受调用者伪造的链接身份或选项。
    private func requireOwned(_ link: AlbumPublicLink, userID: String, albumID: String) throws {
        try link.validate(userID: userID, albumID: albumID)
        guard links.contains(link) else { throw AlbumPublicLinkError.reloadRequired }
    }

    /// 记录唯一写即将发送；之后即使取消也只使同账号读者失效，不推断事务回滚或自动重放。
    private func markSent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try requireCurrent(owner, account: account, manager: manager); writeWasSent = true
    }

    /// 账号/端点/Page代际和Task取消均须成立；无权上下文不得回退成另一次网络请求。
    private func requireCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try Task.checkCancellation(); guard isCurrent(owner, account: account, manager: manager) else { throw CancellationError() }
    }

    /// owner为本次页面任务，account为manager配置代际；切账户/端点时旧结果立即退休。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        generation == owner && manager.generation == account && accountGeneration == account
    }
}
