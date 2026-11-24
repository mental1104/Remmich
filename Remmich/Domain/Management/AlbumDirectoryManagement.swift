import Foundation

/// 目录管理读取的真实相簿属性；分组名缺失或null均代表未分组，官方相簿解码模型不受影响。
nonisolated struct ManagedDirectoryAlbum: Decodable, Identifiable, Sendable {
    let id: String
    let albumName: String
    let ownerId: String
    let customGroupName: String?

    /// 分组按服务端trim规则归一化，空串是可分配大组的“未分组”节点。
    var groupName: String {
        (customGroupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 同一次前台重读获得的目录及可见相簿；不是原子服务端事务，写入权限仍由服务端裁决。
nonisolated struct ManagedAlbumDirectory: Sendable {
    let state: ForkAlbumDirectory.State
    let albums: [ManagedDirectoryAlbum]

    /// 只有仍有可见相簿的分组才可移动大组；不把历史映射当作独立空目录。
    var groupNames: [String] {
        Set(albums.map(\.groupName)).sorted()
    }

    /// groupName是已trim的可见分组；返回个人大组UUID，nil表示虚拟默认大组。
    func categoryID(for groupName: String) -> String? {
        state.groups.first { $0.groupName == groupName }?.categoryId
    }

    /// groupName对应可见分组；返回用户可读大组名，缺映射统一回默认。
    func categoryName(for groupName: String) -> String {
        let id = categoryID(for: groupName)
        return state.categories.first { $0.id == id }?.name ?? "Default"
    }
}

/// 确认时固定的目录意图；大组仅影响本人目录，相簿分组名称会被其他有权客户端看到。
nonisolated enum AlbumDirectoryCommand: Sendable {
    case createCategory(name: String)
    case renameCategory(id: String, name: String)
    case deleteCategory(id: String)
    case assignGroup(name: String, categoryID: String?)
    case moveAlbum(id: String, groupName: String?)
}

/// 页面/账号双代际绑定的确认快照；旧读取产生的确认不能用于新账号或写后快照。
nonisolated struct AlbumDirectoryPlan: Identifiable, Sendable {
    let id = UUID()
    let command: AlbumDirectoryCommand
    let title: String
    let message: String
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 本地前置条件失败；与HTTP权限/冲突分开，不显示原始响应、端点或资源ID。
nonisolated enum AlbumDirectoryManagementError: LocalizedError {
    case reloadRequired, invalidCategoryName, invalidSelection, notOwned

    var errorDescription: String? {
        switch self {
        case .reloadRequired: "Reload the directory before making another change."
        case .invalidCategoryName: "Enter a category name of 1 to 100 characters. The default category is reserved."
        case .invalidSelection: "This directory selection is no longer available. Reload the directory."
        case .notOwned: "Only albums owned by this account can be moved here."
        }
    }
}
