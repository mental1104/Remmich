import Foundation

/// 官方原生stack可见快照，与Fork场景叠栈无关；成员仅表示官方响应可见且未删除的部分。
nonisolated struct ManagedNativeStack: Identifiable, Hashable, Sendable {
    let id: String
    let primaryAssetID: String
    let assets: [TimelineAssetSummary]

    /// 主图缺失或可见成员不足时保留只读展示，不能把受限响应冒充可安全修改的完整堆叠。
    var canManage: Bool {
        assets.count >= 2 && assets.contains { $0.id == primaryAssetID }
    }

    /// 用于预检用户确认的可见成员/主图；不承诺消除无If-Match API的并发窗口。
    func matches(_ other: ManagedNativeStack) -> Bool {
        id == other.id && primaryAssetID == other.primaryAssetID && Set(assets.map(\.id)) == Set(other.assets.map(\.id))
    }
}

/// 每个动作只对应一次官方写入，不提供删原片/清理其他照片或客户端模拟的场景堆叠。
nonisolated enum NativeStackChange: Sendable {
    case create(assetIDs: [String], addingTo: ManagedNativeStack?)
    case primary(ManagedNativeStack, assetID: String)
    case remove(ManagedNativeStack, assetID: String)
    case dissolve(ManagedNativeStack)
}

/// stack范围或回执不明时停止，要求fresh读取后重新确认，不自动重放POST/PUT/DELETE。
nonisolated enum NativeStackError: LocalizedError, Equatable, Sendable {
    case changed, unavailableMembers, invalidSelection, unconfirmed

    /// 仅展示固定安全文本；不泄露服务器原始正文、文件路径或凭据。
    var errorDescription: String? {
        switch self {
        case .changed: "The stack or selected photo changed. Reload before confirming again."
        case .unavailableMembers: "This stack does not expose its representative and at least two visible members. It is read-only here."
        case .invalidSelection: "Select your own unstacked visible photos. Existing stacks cannot be silently merged here."
        case .unconfirmed: "The server did not confirm the expected stack change. It may have changed records. Reload before another change."
        }
    }
}

/// 官方stack管理的原仓库边界；读取前台fresh，选图保留真实metadata cursor，写入绑定账号/端点代际。
nonisolated protocol NativeStackManaging: Sendable {
    /// 官方GET/stacks是无分页数组；返回全部当前账号可读堆叠，不制造Load more游标。
    func managementStacks() async throws -> [ManagedNativeStack]
    /// 从真实metadata搜索返回一页本人照片和原续页令牌；由界面排除已知堆叠成员，写前仍须逐项预检。
    func stackCandidates(continuation: NativeSearchContinuation?) async throws -> NativeSearchPage
    /// change为明确确认的不可变载荷；每次仅一个官方写入，随后确认当前服务端状态。
    func changeNativeStack(_ change: NativeStackChange) async throws
}
