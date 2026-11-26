import Foundation

/// 官方已有账户的共享身份；ID而非email用于写入，不构造邀请或接受邀请流程。
nonisolated struct AlbumSharingUser: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String?
}

/// 官方有序成员记录；保留未知role原值用于只读显示，不能把未来权限默认为editor。
nonisolated struct AlbumSharingMember: Decodable, Identifiable, Equatable, Sendable {
    let user: AlbumSharingUser
    let role: String
    var id: String {
        user.id
    }
}

/// 本轮允许选择的角色与官方Web一致；owner仅从响应读取，不提供新owner推广或直接添加。
nonisolated enum AlbumSharingRole: String, Codable, CaseIterable, Hashable, Sendable { case editor, viewer }

/// 官方完整成员快照，不依赖不存在的ownerId；顺序保留以保护服务端限制的首位owner角色。
nonisolated struct AlbumSharingSnapshot: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let albumName: String
    let albumUsers: [AlbumSharingMember]

    /// 返回规范ID→role用于变更前后精确比较，成员顺序仍由原数组保留。
    var roles: [String: String] {
        Dictionary(albumUsers.map { ($0.id.lowercased(), $0.role) }, uniquingKeysWith: { first, _ in first })
    }

    var hasKnownRoles: Bool {
        albumUsers.allSatisfy { ["owner", "editor", "viewer"].contains($0.role) }
    }

    /// 响应必须是唯一UUID成员且至少一个owner；空/重复/损坏成员不能用于权限判断或写入。
    func validate() throws {
        guard UUID(uuidString: id) != nil, !albumUsers.isEmpty,
              albumUsers.allSatisfy({ UUID(uuidString: $0.id) != nil }),
              Set(albumUsers.map { $0.id.lowercased() }).count == albumUsers.count,
              albumUsers.contains(where: { $0.role == "owner" }) else { throw LibraryWriteError.malformedResponse }
    }

    /// userID为当前认证身份；实际AlbumShare是owner或editor，不只比较首位owner或单个ownerId。
    func canManage(_ userID: String) -> Bool {
        (try? validate()) != nil && hasKnownRoles && ["owner", "editor"].contains(roles[userID.lowercased()] ?? "")
    }

    /// command为单成员明确意图，users是同账号GET/users结果；拒绝不再存在/无权/未知角色/最后owner操作。
    func require(_ command: AlbumSharingCommand, userID: String, users: [AlbumSharingUser]) throws {
        try validate()
        guard hasKnownRoles, roles[userID.lowercased()] != nil else { throw AlbumSharingError.permission }
        switch command {
        case let .add(id, _):
            guard canManage(userID), roles[id.lowercased()] == nil,
                  users.contains(where: { $0.id.lowercased() == id.lowercased() }) else { throw AlbumSharingError.permission }
        case let .role(id, _):
            guard canManage(userID), roles[id.lowercased()] != nil,
                  albumUsers.first?.id.lowercased() != id.lowercased() else { throw AlbumSharingError.permission }
        case let .remove(id):
            guard let role = roles[id.lowercased()], canManage(userID) || id.lowercased() == userID.lowercased(),
                  role != "owner" || albumUsers.filter({ $0.role == "owner" }).count > 1 else { throw AlbumSharingError.permission }
        }
    }

    /// 已成功写入后仍须fresh确认整份角色集合；额外并发改变不会被误称为用户预期已完整核对。
    func confirms(_ command: AlbumSharingCommand, from baseline: Self) -> Bool {
        guard (try? validate()) != nil, id.lowercased() == baseline.id.lowercased(), hasKnownRoles else { return false }
        var expected = baseline.roles
        switch command {
        case let .add(id, role), let .role(id, role): expected[id.lowercased()] = role.rawValue
        case let .remove(id): expected.removeValue(forKey: id.lowercased())
        }
        return roles == expected
    }
}

/// 每次只有一个成员，避免官方批量逐项写入后半途失败造成部分成功误报；remove明确使用UUID而非deprecated me。
nonisolated enum AlbumSharingCommand: Sendable {
    case add(id: String, role: AlbumSharingRole)
    case role(id: String, role: AlbumSharingRole)
    case remove(id: String)

    var userID: String {
        switch self { case let .add(id, _), let .role(id, _), let .remove(id): id }
    }
}

/// 确认固定完整成员基线和页面/账号代际；旧确认不能被重放到新角色、账号或服务器端点。
nonisolated struct AlbumSharingPlan: Identifiable, Sendable {
    let id = UUID()
    let baseline: AlbumSharingSnapshot
    let command: AlbumSharingCommand
    let memberName: String
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 本地安全状态说明；未知写入不自动再发，重新读取后由用户重新确认。
nonisolated enum AlbumSharingError: LocalizedError {
    case reloadRequired, permission, changed
    var errorDescription: String? {
        switch self {
        case .reloadRequired: "Reload sharing before confirming another change."
        case .permission: "This member action is not allowed with the current album roles."
        case .changed: "Album membership changed. Reload and confirm again."
        }
    }
}
