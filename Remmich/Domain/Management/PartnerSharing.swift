import Foundation

/// 官方伙伴方向：incoming是别人分享给我，outgoing是我分享给别人；不能从同形响应反向猜测授权。
nonisolated enum PartnerSharingDirection: String, Sendable { case incoming = "shared-with", outgoing = "shared-by" }

/// 伙伴列表的最小用户投影；缺少inTimeline保留未知，不能当作false或宣称本App已读取伙伴照片。
nonisolated struct ManagedPartner: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String?
    let inTimeline: Bool?
}

/// 两个方向分别fresh读取的当前账号快照；只是观察结果，不是服务端原子事务或双向共享推断。
nonisolated struct PartnerSharingSnapshot: Equatable, Sendable {
    let incoming: [ManagedPartner]
    let outgoing: [ManagedPartner]

    /// command为一次明确动作，userID为本人，users为当前已知账户候选；只能撤销本人的outgoing或设置本人的incoming偏好。
    func require(_ command: PartnerSharingCommand, userID: String, users: [AlbumSharingUser]) throws {
        switch command {
        case let .add(id):
            guard id.lowercased() != userID.lowercased(), !outgoing.contains(where: { $0.id.lowercased() == id.lowercased() }),
                  users.contains(where: { $0.id.lowercased() == id.lowercased() }) else { throw PartnerSharingError.permission }
        case let .remove(id):
            guard outgoing.contains(where: { $0.id.lowercased() == id.lowercased() }) else { throw PartnerSharingError.permission }
        case let .timeline(id, enabled):
            guard let value = incoming.first(where: { $0.id.lowercased() == id.lowercased() }),
                  let current = value.inTimeline, current != enabled else { throw PartnerSharingError.permission }
        }
    }

    /// command是已发出的唯一写，receipt是POST/PUT真实响应（DELETE为空）；新快照只允许对应方向的预期变化。
    func confirms(_ command: PartnerSharingCommand, receipt: ManagedPartner?, from baseline: Self) -> Bool {
        var expectedIncoming = baseline.incoming; var expectedOutgoing = baseline.outgoing
        switch command {
        case let .add(id):
            guard let receipt, receipt.id.lowercased() == id.lowercased(), !expectedOutgoing.contains(where: { $0.id.lowercased() == id.lowercased() }) else { return false }
            expectedOutgoing.append(receipt)
        case let .remove(id):
            guard receipt == nil else { return false }
            expectedOutgoing.removeAll { $0.id.lowercased() == id.lowercased() }
        case let .timeline(id, enabled):
            guard let receipt, receipt.id.lowercased() == id.lowercased(), receipt.inTimeline == enabled,
                  let index = expectedIncoming.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return false }
            expectedIncoming[index] = receipt
        }
        return incoming == expectedIncoming.sorted { $0.id.lowercased() < $1.id.lowercased() }
            && outgoing == expectedOutgoing.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }
}

/// 一个用户明确确认的单向共享或接收偏好；没有incoming撤销命令，不会替别人更改其授权。
nonisolated enum PartnerSharingCommand: Sendable {
    case add(String)
    case remove(String)
    case timeline(String, Bool)

    var userID: String {
        switch self { case let .add(id), let .remove(id), let .timeline(id, _): id }
    }
}

/// 固定两个方向基线、目标名称与账号/页面代际；确认不能重放到下次读取或其他服务器。
nonisolated struct PartnerSharingPlan: Identifiable, Sendable {
    let id = UUID()
    let baseline: PartnerSharingSnapshot
    let command: PartnerSharingCommand
    let name: String
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 安全本地错误，不包含用户邮箱、服务端原文或端点；未知写入需要用户fresh重读。
nonisolated enum PartnerSharingError: Error { case reloadRequired, permission, changed }
