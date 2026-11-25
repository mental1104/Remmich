import Foundation

/// 对应现行官方ACL的相簿动作；属性/成员写允许任一owner或editor，删除整个相簿只允许owner。
nonisolated enum ManagedAlbumPermission: Sendable { case update, assets, delete }

/// 管理入口读取的最小完整成员形状；不要求展示字段，不把缺失或未来role推断成可写。
nonisolated struct ManagedAlbumMember: Decodable, Sendable {
    let user: User
    let role: String?

    /// 只读公开用户身份；权限不依赖姓名、邮箱或成员数组位置。
    nonisolated struct User: Decodable, Sendable { let id: String }
}

/// 与兼容ownerId展示投影分离的写权限快照；只在成员字段完全缺失时接受明确旧版owner。
nonisolated struct ManagedAlbumAccess: Sendable {
    let members: [ManagedAlbumMember]?
    let hasExplicitMembers: Bool
    let legacyOwnerID: String?

    /// members来自同一HTTP完整成员数组，hasExplicitMembers也记录null/畸形存在；legacyOwnerID只作旧响应兼容。
    init(members: [ManagedAlbumMember]? = nil, hasExplicitMembers: Bool = false, legacyOwnerID: String?) {
        self.members = members; self.hasExplicitMembers = hasExplicitMembers; self.legacyOwnerID = legacyOwnerID
    }

    /// userID是当前认证身份；返回此完整快照是否明确允许permission。未知成员/角色整体只读，不回退legacy覆盖。
    func allows(_ permission: ManagedAlbumPermission, userID: String) -> Bool {
        guard !userID.isEmpty else { return false }
        let role: String
        if hasExplicitMembers {
            guard let members, !members.isEmpty,
                  members.allSatisfy({ UUID(uuidString: $0.user.id) != nil && ["owner", "editor", "viewer"].contains($0.role ?? "") }),
                  Set(members.map { $0.user.id.lowercased() }).count == members.count,
                  members.contains(where: { $0.role == "owner" }),
                  let actual = members.first(where: { $0.user.id.lowercased() == userID.lowercased() })?.role else { return false }
            role = actual
        } else {
            guard let legacyOwnerID, !legacyOwnerID.isEmpty, legacyOwnerID.lowercased() == userID.lowercased() else { return false }
            role = "owner"
        }
        switch permission {
        case .update, .assets: return role == "owner" || role == "editor"
        case .delete: return role == "owner"
        }
    }
}

/// 实际管理入口的五种单相簿意图；只复用已有方法，写前必须读取当前完整角色，不影响备份上传通道。
nonisolated enum ManagedAlbumMutation: Sendable {
    case rename(id: String, name: String), delete(id: String)
    case cover(id: String, assetID: String), add(id: String, assetID: String), remove(id: String, assetID: String)

    /// 返回用户明确选择的相簿身份；资源ID和名称从不代替授权目标。
    var albumID: String {
        switch self {
        case let .rename(id, _), let .delete(id), let .cover(id, _), let .add(id, _), let .remove(id, _): id
        }
    }

    /// 返回官方ACL动作；封面/改名属于update，加入/移出属于成员，只有整个相簿删除要求owner。
    var permission: ManagedAlbumPermission {
        switch self {
        case .rename, .cover: .update
        case .add, .remove: .assets
        case .delete: .delete
        }
    }
}
