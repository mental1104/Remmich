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
    private var account: AccountSession?
    private let configurationFactory: (() -> URLSessionConfiguration)?

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
}
