import Foundation

/// 管理页每次重载都必须取得当前账号的前台读取器，不能把持久GET响应当作写入后的新状态。
nonisolated protocol ManagementTimelineProviding: Sendable {
    /// 返回独立前台时间线读取器；无有效身份/端点时抛错，调用方仍须检查账号代际和任务取消。
    func managementTimelineReader() async throws -> any TimelineReading
}

/// 创建当前账号读取器的窄边界；只读取真实相簿成员，不持久化搜索或凭据。
typealias ManagementTimelineFactory = @Sendable () async throws -> any TimelineReading

/// 本次管理的相簿身份；名称只用于原生确认提示，写请求始终使用id。
nonisolated struct BatchAlbumReference: Hashable, Sendable {
    let id: String
    let name: String

    /// 服务端允许空名称；原生入口使用可读默认标题，写入身份仍取id。
    var title: String {
        name.isEmpty ? "Untitled Album" : name
    }
}

/// 相簿正常成员和回收站成员分开读取，避免把恢复和删除混用在不明状态的选择上。
nonisolated enum BatchAssetScope: String, CaseIterable, Sendable {
    case active, trash

    /// 返回界面名称，不将“回收站”误解为永久删除入口。
    var title: String {
        self == .active ? "Photos and videos" : "In trash"
    }

    /// albumID为当前相簿UUID；包含归档及堆叠成员，保留账号权限，不额外纳入伙伴资源。
    func query(albumID: String) -> TimelineQuery {
        var query = TimelineQuery()
        query.albumID = albumID
        query.visibility = nil
        query.includesStacks = false
        query.includesPartners = false
        query.includesTrashed = self == .trash
        return query
    }
}

/// 用户一次明确确认的批量意图；没有永久删除、原图替换或隐式重放操作。
nonisolated enum BatchAssetAction: Hashable, Sendable {
    case favorite(Bool), archived(Bool), trash, restore
    case addToAlbum(BatchAlbumReference), removeFromAlbum(BatchAlbumReference), albumCover(BatchAlbumReference)

    /// 返回确认及结果页标题；相簿名称来自已加载的真实账号相簿。
    var title: String {
        switch self {
        case .favorite(true): "Favorite selected items"
        case .favorite(false): "Remove favorites"
        case .archived(true): "Archive selected items"
        case .archived(false): "Move back to timeline"
        case .trash: "Move selected items to trash"
        case .restore: "Restore selected items"
        case let .addToAlbum(album): "Add to \(album.title)"
        case let .removeFromAlbum(album): "Remove from \(album.title)"
        case .albumCover: "Use as album cover"
        }
    }

    /// 删除和移出相簿使用破坏性按钮样式，但两者都不永久删除原片。
    var isDestructive: Bool {
        switch self { case .trash, .removeFromAlbum: true; default: false }
    }

    /// 与现有单张管理一致，照片属性/回收站写入只向当前账号拥有的资源开放。
    var requiresAssetOwnership: Bool {
        switch self { case .favorite, .archived, .trash, .restore: true; default: false }
    }

    /// scope为当前真实读取范围；封面只接受单个正常成员，恢复只作用于回收站范围。
    func accepts(scope: BatchAssetScope, count: Int) -> Bool {
        guard count > 0 else { return false }
        switch self {
        case .restore: return scope == .trash
        case .albumCover: return scope == .active && count == 1
        default: return scope == .active
        }
    }
}

/// 已明确拒绝的操作原因；不保存服务端原始响应、URL、照片名称或凭据。
nonisolated enum BatchAssetRejection: Equatable, Sendable {
    case notOwned, invalidInput, unauthorized, forbidden, notFound, conflict, rateLimited, serverStatus(Int)

    /// 返回可安全显示的说明；未知网络结果由另一状态表达，不能包装成确定失败。
    var message: String {
        switch self {
        case .notOwned: "Only items owned by this account can use this action."
        case .invalidInput: "The request was rejected as invalid."
        case .unauthorized: "Sign in again before another operation."
        case .forbidden: "This account does not have permission for this item."
        case .notFound: "This item is no longer available."
        case .conflict: "The server rejected this operation because the item changed."
        case .rateLimited: "The server requested fewer operations. Reload before continuing."
        case let .serverStatus(status): "The server rejected this operation (HTTP \(status))."
        }
    }
}

/// 每个选中资源的独立回执；未确认不等于失败，也不能自动重试可能已生效的写入。
nonisolated enum BatchAssetItemState: Equatable, Sendable {
    case pending, running, succeeded, rejected(BatchAssetRejection), unconfirmed, notAttempted

    /// 逐项显示执行状态，保留已成功结果和没有发送的剩余项。
    var message: String {
        switch self {
        case .pending: "Waiting"
        case .running: "Sending"
        case .succeeded: "Confirmed"
        case let .rejected(reason): reason.message
        case .unconfirmed: "The result is unknown. Reload before deciding whether to try again."
        case .notAttempted: "Not sent"
        }
    }
}

/// 回执身份固定为确认时选中的资产，不因重载或分页改变动作目标。
nonisolated struct BatchAssetItemResult: Identifiable, Equatable, Sendable {
    let asset: TimelineAssetSummary
    var state: BatchAssetItemState

    /// 身份始终来自确认时资产快照；缩略图版本也随快照保留，重载后不猜测新版本。
    var id: String {
        asset.id
    }
}

/// 确认弹窗固定的动作及选择快照；读源或账号代际变化后不能继续提交。
nonisolated struct BatchAssetPlan: Sendable {
    let action: BatchAssetAction
    let assets: [TimelineAssetSummary]
    let album: BatchAlbumReference
    let scope: BatchAssetScope
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 窄管理入口的前置条件错误；失败时没有向服务器发送写请求。
nonisolated enum BatchAssetManagementError: LocalizedError {
    case unavailable, reloadRequired, invalidSelection, wrongScope, invalidResponse

    /// 返回可以直接展示的错误，不携带真实URL或服务端原始诊断。
    var errorDescription: String? {
        switch self {
        case .unavailable: "Connect to the current account before managing album photos."
        case .reloadRequired: "Reload album photos before another operation."
        case .invalidSelection: "Choose valid photos from the loaded album first."
        case .wrongScope: "This action does not apply to the current selection."
        case .invalidResponse: "Album photos could not be understood. Reload before continuing."
        }
    }
}
