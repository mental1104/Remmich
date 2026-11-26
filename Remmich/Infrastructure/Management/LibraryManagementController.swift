import Foundation
import Observation

/// 当前账号显式写入通道的发布边界；身份或端点变化关闭旧客户端，并拒绝旧代际的完成值。
@MainActor
@Observable
final class LibraryManagementController {
    private(set) var client: LibraryMutationClient?
    private(set) var generation = UUID()
    private(set) var revision = 0
    private(set) var busy = false
    /// 只有应用已接入接受索引的日期刷新链时启用；孤立管理宿主不能假称已通知时间线。
    var metadataDateRefreshAvailable = false
    private var metadataDateProjections: [String: AssetMetadataDateProjection] = [:]
    private var partnerTimelineRefreshRequested = false
    private var account: AccountSession?
    private let configurationFactory: (() -> URLSessionConfiguration)?

    /// 只暴露当前认证身份的持久namespace，不向备份UI传递token；端点临时不可用时不启动任务。
    var backupScope: MediaAccountScope? {
        guard client != nil, let account else { return nil }
        return MediaAccountScope(session: account)
    }

    /// configurationFactory可为每个客户端提供隔离会话配置；nil保持现有生产构造与取消行为。
    /// 注入配置仅改变传输来源，不替换LibraryMutationClient的鉴权、序列化、状态码或代际检查。
    init(configurationFactory: (() -> URLSessionConfiguration)? = nil) {
        self.configurationFactory = configurationFactory
    }

    /// session/endpoint为当前已验证上下文；任一变化使旧操作失效，缺省值清除通道。
    func configure(session: AccountSession?, endpoint: URL?) {
        guard account != session || client?.apiURL != endpoint else { return }
        client?.cancel()
        account = session
        generation = UUID()
        metadataDateProjections.removeAll()
        partnerTimelineRefreshRequested = false
        busy = false
        client = if let session, let endpoint {
            if let configurationFactory {
                LibraryMutationClient(apiURL: endpoint, token: session.accessToken, userID: session.userID,
                                      configuration: configurationFactory())
            } else {
                LibraryMutationClient(apiURL: endpoint, token: session.accessToken, userID: session.userID)
            }
        } else {
            nil
        }
    }

    /// 账户或路由变更会立即关闭旧会话，旧结果不能提交到新账户界面。
    func perform<Value: Sendable>(publishChange: Bool = true, _ operation: @Sendable (LibraryMutationClient) async throws -> Value) async throws -> Value {
        guard let client else { throw LibraryWriteError.unavailable }
        guard !busy else { throw LibraryWriteError.busy }
        let owner = generation
        busy = true
        defer {
            if owner == generation {
                busy = false
            }
        }
        let value = try await operation(client)
        try Task.checkCancellation()
        guard owner == generation else { throw LibraryWriteError.changedAccount }
        if publishChange {
            revision += 1
        }
        return value
    }

    func publishChanges(ifGeneration owner: UUID) {
        if owner == generation {
            revision += 1
        }
    }

    /// 伙伴时间线写入已确认或结果未知时仅请求重新读取；代际不符不把旧账号意图发给当前索引。
    func publishPartnerTimelineChange(ifGeneration owner: UUID) {
        guard owner == generation else { return }
        partnerTimelineRefreshRequested = true; revision += 1
    }

    /// 原AppShell管理观察器消费一次调度意图；持久正确性由查询policy/accepted代际证书承担，不依赖此内存bool。
    func takePartnerTimelineRefreshRequest() -> Bool {
        let result = partnerTimelineRefreshRequested; partnerTimelineRefreshRequested = false; return result
    }

    /// projection为fresh详情已核对的当前日期投影；同账号保存需求后复用既有revision通知，不建立通用事件队列。
    func requestMetadataDateRefresh(_ projection: AssetMetadataDateProjection) -> Bool {
        guard metadataDateRefreshAvailable, projection.accountGeneration == generation,
              projection.ownerID.lowercased() == client?.userID.lowercased() else { return false }
        metadataDateProjections[projection.assetID.lowercased()] = projection
        revision += 1
        return true
    }

    /// 仅既有App索引桥接消费本账号已验证需求；索引控制器接管后仍须保留活跃同步中的后续刷新。
    func takeMetadataDateProjections() -> [AssetMetadataDateProjection] {
        let values = Array(metadataDateProjections.values)
        metadataDateProjections.removeAll()
        return values
    }
}
