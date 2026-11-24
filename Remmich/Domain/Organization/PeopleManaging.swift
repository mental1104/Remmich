import Foundation

/// 当前账号新鲜读取的人物记录；隐藏属于人物显示设置，不代表删除照片或改变照片隐私。
nonisolated struct ManagedPerson: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isHidden: Bool
    var updatedAt: Date?

    /// 空姓名沿用原生人物浏览的Unnamed展示，不伪造真实姓名。
    var displayName: String {
        name.isEmpty ? "Unnamed" : name
    }

    /// 预检只比较本切片会修改或展示的字段；服务端无If-Match保证，不能宣称消除了并发窗口。
    func matchesEditableFields(_ other: ManagedPerson) -> Bool {
        id.lowercased() == other.id.lowercased() && name == other.name && isHidden == other.isHidden
    }
}

/// 人物变更失败保持可读且安全；任何写入异常后都先Reload，尤其不能重放可能部分完成的合并。
nonisolated enum PeopleManagementError: LocalizedError, Equatable, Sendable {
    case changedPerson, incompleteMerge

    /// 不包含服务器原文、凭据或私人识别结果；说明用户需要重新读取而不是重复提交。
    var errorDescription: String? {
        switch self {
        case .changedPerson: "This person changed. Reload people before confirming again."
        case .incompleteMerge: "The server did not confirm every merge result. Some records may have changed. Reload before another change."
        }
    }
}

/// 原仓库提供前台人物读取和窄写入，方法均须绑定同一账号/端点代际；无自动重试写操作。
/// 与其他读取协议一样显式nonisolated，供后台repo/test actor实现，不依赖应用默认MainActor推断。
nonisolated protocol PeopleManaging: Sendable {
    /// 返回含隐藏人物的完整新鲜列表，保留官方分页，不消费已完成索引GET。
    func managementPeople() async throws -> [ManagedPerson]
    /// expected是确认时记录；仅修改当前账号姓名，不修改共享用户姓名或生日。
    func renamePerson(_ expected: ManagedPerson, name: String) async throws
    /// expected是确认时记录；隐藏/取消隐藏不删除任何照片。
    func setPersonHidden(_ expected: ManagedPerson, hidden: Bool) async throws
    /// target优先保留姓名/生日，source合入target；服务端可能连带合并共享群记录，不自动重试。
    func mergePeople(target: ManagedPerson, source: ManagedPerson) async throws
}
