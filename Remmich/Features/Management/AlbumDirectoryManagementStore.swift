import Foundation
import Observation

/// 原生目录页的单命令状态机；写后真实重读两个接口，失败/未知结果必须显式重载后再确认。
@MainActor @Observable
final class AlbumDirectoryManagementStore {
    private(set) var directory: ManagedAlbumDirectory?
    private(set) var hasFreshData = false
    private(set) var isUnsupported = false
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var notice: String?
    private var generation = UUID()
    private var readAccountGeneration: UUID?
    private var readTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    /// 页面/账号退出时撤销发布权并取消真实网络等待；不重放任何写入。
    func invalidate() {
        generation = UUID()
        readTask?.cancel(); operationTask?.cancel()
        readTask = nil; operationTask = nil
        directory = nil; hasFreshData = false; isUnsupported = false
        readAccountGeneration = nil
        isLoading = false; isWorking = false; error = nil; notice = nil
    }

    /// manager提供当前账号真实管理通道；返回本次任务，完整目录与相簿读取成功后才开放写入。
    @discardableResult
    func reload(manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking, let client = manager.client else { return nil }
        readTask?.cancel()
        generation = UUID()
        let owner = generation
        let account = manager.generation
        directory = nil; hasFreshData = false; isUnsupported = false
        readAccountGeneration = nil
        isLoading = true; error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: account, manager: manager) {
                    isLoading = false; readTask = nil
                }
            }
            do {
                let result = try await Self.read(client: client)
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                publish(result, account: account)
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = Self.failureMessage(error, reading: true)
            }
        }
        readTask = task
        return task
    }

    /// command来自可见节点或用户输入；返回规范化且绑定双代际的确认，不发送网络请求。
    func prepare(_ command: AlbumDirectoryCommand, manager: LibraryManagementController) throws -> AlbumDirectoryPlan {
        guard hasFreshData, readAccountGeneration == manager.generation,
              !isLoading, !isWorking, !manager.busy, let directory, let client = manager.client
        else {
            throw AlbumDirectoryManagementError.reloadRequired
        }
        let normalized: AlbumDirectoryCommand
        let title: String
        let message: String
        switch command {
        case let .createCategory(name):
            let name = try categoryName(name)
            normalized = .createCategory(name: name); title = "Create category?"
            message = "Create \(name) in your personal album directory."
        case let .renameCategory(id, name):
            let category = try category(id, in: directory)
            let name = try categoryName(name)
            normalized = .renameCategory(id: category.id, name: name); title = "Rename category?"
            message = "Rename \(category.name) to \(name) in your personal directory."
        case let .deleteCategory(id):
            let category = try category(id, in: directory)
            normalized = .deleteCategory(id: category.id); title = "Delete category?"
            message = "Delete \(category.name). Its groups return to Default. Albums, photos and sharing are preserved."
        case let .assignGroup(name, categoryID):
            guard directory.groupNames.contains(name) else { throw AlbumDirectoryManagementError.invalidSelection }
            let target = try categoryID.map { try category($0, in: directory) }
            normalized = .assignGroup(name: name, categoryID: target?.id); title = "Move group?"
            message = "Move \(name.isEmpty ? "Ungrouped" : name) to \(target?.name ?? "Default") in your personal directory."
        case let .moveAlbum(id, groupName):
            guard let album = directory.albums.first(where: { $0.id.lowercased() == id.lowercased() }) else {
                throw AlbumDirectoryManagementError.invalidSelection
            }
            guard album.ownerId.lowercased() == client.userID.lowercased() else { throw AlbumDirectoryManagementError.notOwned }
            let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            normalized = .moveAlbum(id: album.id, groupName: name.isEmpty ? nil : name); title = "Move album?"
            message = "Move \(album.albumName) to \(name.isEmpty ? "Ungrouped" : name). This album property is visible to other clients. Photos and sharing are preserved."
        }
        return .init(command: normalized, title: title, message: message,
                     readGeneration: generation, accountGeneration: manager.generation)
    }

    /// plan是用户已确认意图；返回单次任务。旧计划/并发写入不发送，成功后真实重读才重新开放写入。
    @discardableResult
    func start(_ plan: AlbumDirectoryPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              hasFreshData, !isLoading, !isWorking, !manager.busy
        else {
            error = AlbumDirectoryManagementError.reloadRequired.errorDescription
            return nil
        }
        // 一次确认仅可消费一次，重读成功也不能再次使用写前计划。
        generation = UUID()
        let owner = generation
        hasFreshData = false; isWorking = true; error = nil; notice = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    isWorking = false; operationTask = nil
                }
            }
            do {
                try await manager.perform(publishChange: false) { client in try await client.applyDirectoryCommand(plan.command) }
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                self.error = Self.failureMessage(error, reading: false)
                // 取消/错误成功码/5xx可能已经改变服务端，通知同账号读者失效但不盲目重发。
                if Self.mayHaveChanged(error) {
                    manager.publishChanges(ifGeneration: plan.accountGeneration)
                }
                return
            }
            guard isCurrent(owner, account: plan.accountGeneration, manager: manager), let client = manager.client else { return }
            manager.publishChanges(ifGeneration: plan.accountGeneration)
            notice = "Change saved."
            do {
                let result = try await Self.read(client: client)
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager), !Task.isCancelled else { return }
                publish(result, account: plan.accountGeneration)
                if result == nil {
                    error = "The change was saved, but the directory extension is now unavailable. Reload to check it."
                }
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                self.error = "The change was saved, but fresh directory data could not be loaded. Reload before another change."
            }
        }
        operationTask = task
        return task
    }

    /// 请求取消正在进行的命令/写后重读；可能已写入时页面保持重载要求，绝不自动再次发送。
    func cancel() {
        operationTask?.cancel()
    }

    /// message必须是本地安全说明；用于展示确认前的输入/选择错误，不记录服务端响应。
    func showError(_ message: String) {
        error = message
    }

    /// client属于一次账号上下文；返回两个真实GET组成的快照，nil仅表示可选扩展缺失。
    private nonisolated static func read(client: LibraryMutationClient) async throws -> ManagedAlbumDirectory? {
        guard let state = try await client.albumDirectoryState() else { return nil }
        try Task.checkCancellation()
        let albums = try await client.directoryAlbums()
        try Task.checkCancellation()
        return .init(state: state, albums: albums)
    }

    /// result只可由当前双代际调用发布，account绑定快照账号；空相簿仍是有效目录，缺扩展不可写。
    private func publish(_ result: ManagedAlbumDirectory?, account: UUID) {
        directory = result; isUnsupported = result == nil; hasFreshData = result != nil
        readAccountGeneration = result == nil ? nil : account
    }

    /// owner/account为启动快照；返回页面和账号是否仍有权接收该结果。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        generation == owner && manager.generation == account
    }

    /// name使用服务端trim及UTF16长度；返回有效名称，虚拟默认组不允许持久化。
    private func categoryName(_ name: String) throws -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(title.utf16.count), title != "默认" else { throw AlbumDirectoryManagementError.invalidCategoryName }
        return title
    }

    /// id须来自本次真实目录；返回原始自有节点，阻止默认标识或已删除节点写入。
    private func category(_ id: String, in directory: ManagedAlbumDirectory) throws -> ForkAlbumDirectory.Category {
        guard let category = directory.state.categories.first(where: { $0.id.lowercased() == id.lowercased() }) else {
            throw AlbumDirectoryManagementError.invalidSelection
        }
        return category
    }

    /// error为真实写失败；返回是否可能产生需其他页面重读的服务端变化。
    private nonisolated static func mayHaveChanged(_ error: Error) -> Bool {
        switch error {
        case LibraryWriteError.http(400 ..< 500), LibraryWriteError.busy, LibraryWriteError.unavailable,
             LibraryWriteError.invalidID, LibraryWriteError.invalidDirectoryName, LibraryWriteError.changedAccount: false
        default: true
        }
    }

    /// reading区分读取与写回；错误只显示安全操作建议，401/403不能降级为扩展缺失。
    private nonisolated static func failureMessage(_ error: Error, reading: Bool) -> String {
        switch error {
        case LibraryWriteError.http(400): "The directory change was rejected. Check the name or selection, then reload."
        case LibraryWriteError.http(401): "Sign in again before managing the directory."
        case LibraryWriteError.http(403): "This account does not have permission for this directory operation."
        case LibraryWriteError.http(404): "The category, group or album is no longer available. Reload the directory."
        case LibraryWriteError.http(409): "That category name already exists. Reload the directory and choose another name."
        case LibraryWriteError.http(429): "Too many requests. Wait, then reload before another change."
        default: reading ? "The directory could not be loaded. Check permissions and connection." : "The change could not be confirmed. Reload before another change; do not repeat it blindly."
        }
    }
}
