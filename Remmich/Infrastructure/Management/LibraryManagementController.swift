import Foundation
import Observation

@MainActor
@Observable
final class LibraryManagementController {
    private(set) var client: LibraryMutationClient?
    private(set) var generation = UUID()
    private(set) var revision = 0
    private(set) var busy = false
    private var account: AccountSession?

    func configure(session: AccountSession?, endpoint: URL?) {
        guard account != session || client?.apiURL != endpoint else { return }
        client?.cancel()
        account = session
        generation = UUID()
        busy = false
        client = if let session, let endpoint {
            LibraryMutationClient(apiURL: endpoint, token: session.accessToken, userID: session.userID)
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
