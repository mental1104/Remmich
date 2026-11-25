import Foundation
import Testing
@testable import Remmich

/// 管理读取必须每次发真实新GET，同时绑定原repo代际，不能因脱离缓存而绕过账号生命周期。
@Suite("Management foreground timeline")
struct ManagementFreshTimelineTests {
    /// 同一范围重复读取桶与资产仍调用前台loader，第二个桶响应变化可观察；不复用已完成GET结果。
    @Test func repeatedReadsReachTheCurrentForegroundSource() async throws {
        let session = managementReadSession("first")
        let transport = FreshManagementGET(expected: Array(repeating: .init(endpoint: session.apiURL, token: session.accessToken), count: 4),
                                           albumID: "11111111-1111-4111-8111-111111111111")
        let source = ImmichTimelineRepository(readLoader: { request, operation in try await transport.load(request, operation: operation) })
        await source.configure(session: session, activeEndpoint: session.apiURL)
        let reader = try await source.managementTimelineReader()
        let query = TimelineQuery(albumID: "11111111-1111-4111-8111-111111111111", visibility: nil, includesStacks: true, includesPartners: false)
        #expect(try await reader.bucketSummaries(query: query).map(\.assetCount) == [1])
        #expect(try await reader.bucketSummaries(query: query).map(\.assetCount) == [2])
        #expect(try await reader.assets(in: .init(rawValue: "2026-11-01"), query: query).isEmpty)
        #expect(try await reader.assets(in: .init(rawValue: "2026-11-01"), query: query).isEmpty)
        #expect(try await reader.memories().isEmpty)
        #expect(await transport.operations == ["getTimeBuckets", "getTimeBuckets", "getTimeBucket", "getTimeBucket"])
    }

    /// change覆盖账号、端点及清会话；旧真实HTTP已在途时切换，新读取先成功，旧结果和旧facade均拒绝。
    @Test(arguments: ["account", "endpoint", "clear"])
    func rejectsOldFacadeAndItsLateResponse(_ change: String) async throws {
        let first = managementReadSession("first")
        let next = change == "endpoint" ? first : managementReadSession("second")
        let endpoint = change == "endpoint" ? URL(string: "https://fallback.example.invalid/api")! : next.apiURL
        let transport = FreshManagementGET(expected: [.init(endpoint: first.apiURL, token: first.accessToken),
                                                      .init(endpoint: endpoint, token: next.accessToken)], holdsFirst: true)
        let source = ImmichTimelineRepository(readLoader: { request, operation in try await transport.load(request, operation: operation) })
        await source.configure(session: first, activeEndpoint: first.apiURL)
        let oldReader = try await source.managementTimelineReader()
        let pending = Task {
            do { return try await oldReader.bucketSummaries(query: .init()) }
            catch { await transport.failedBeforeGate(); throw error }
        }
        guard await transport.waitForFirst() else {
            _ = try await pending.value
            Issue.record("The old management GET must enter its gate")
            return
        }
        if change == "clear" {
            await source.clear()
        }
        await source.configure(session: next, activeEndpoint: endpoint)
        let currentReader = try await source.managementTimelineReader()
        let current = await Task { try await currentReader.bucketSummaries(query: .init()) }.result
        await transport.releaseFirst()
        await #expect(throws: TimelineReadError.staleGeneration) { try await pending.value }
        #expect(try current.get().map(\.assetCount) == [2])
        await #expect(throws: TimelineReadError.staleGeneration) { try await oldReader.bucketSummaries(query: .init()) }
        await #expect(throws: TimelineReadError.staleGeneration) { try await oldReader.assets(in: .init(rawValue: "2026-11-01"), query: .init()) }
        await #expect(throws: TimelineReadError.staleGeneration) { try await oldReader.memories() }
        #expect(await transport.operations.count == 2)
    }

    /// 在真实前台GET挂起后取消；有效响应最后返回也必须传播取消，不能被当成成功桶列表。
    @Test func cancelledForegroundReadDoesNotReturnLateData() async throws {
        let session = managementReadSession("cancelled")
        let transport = FreshManagementGET(expected: [.init(endpoint: session.apiURL, token: session.accessToken)], holdsFirst: true)
        let source = ImmichTimelineRepository(readLoader: { request, operation in try await transport.load(request, operation: operation) })
        await source.configure(session: session, activeEndpoint: session.apiURL)
        let reader = try await source.managementTimelineReader()
        let pending = Task {
            do { return try await reader.bucketSummaries(query: .init()) }
            catch { await transport.failedBeforeGate(); throw error }
        }
        guard await transport.waitForFirst() else {
            _ = try await pending.value
            Issue.record("The foreground GET must enter its gate before cancellation")
            return
        }
        pending.cancel()
        await transport.releaseFirst()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
}

/// user只区分合成身份，真实SDK须在请求里保留该token；不读取Keychain或生产地址。
private nonisolated func managementReadSession(_ user: String) -> AccountSession {
    .init(apiURL: URL(string: "https://synthetic.example.invalid/api")!, accessToken: "synthetic-\(user)", userID: user,
          userEmail: "\(user)@example.invalid", name: user, isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 每个预期GET的当前端点与合成身份，独立于仓库实现声明，防止旧凭据在新代际请求中复用。
private nonisolated struct ManagementReadContext: Sendable {
    let endpoint: URL
    let token: String
}

/// 验证真正SDK前台GET并返回有效时间线JSON；可暂停首次响应以证明原repo代际的前后边界。
private actor FreshManagementGET {
    private let expected: [ManagementReadContext]
    private let albumID: String?
    private let holdsFirst: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false
    private(set) var operations: [String] = []
    private var bucketRequests = 0

    /// expected按请求序列定义真实端点/身份；albumID指定应完整保留的管理相簿范围，nil不额外限制。
    /// holdsFirst为true时仅首个GET挂起，后续立即成功。
    init(expected: [ManagementReadContext], albumID: String? = nil, holdsFirst: Bool = false) {
        self.expected = expected
        self.albumID = albumID
        self.holdsFirst = holdsFirst
    }

    /// request/operation是认证后的真实SDK请求；返回桶计数随调用改变或完整空资产列，绝不建立网络。
    func load(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        let index = operations.count
        operations.append(operation)
        let context = try #require(expected.indices.contains(index) ? expected[index] : nil)
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(context.token)")
        let url = try #require(request.url)
        #expect(url.host == context.endpoint.host)
        #expect(url.path == (operation == "getTimeBuckets" ? "/api/timeline/buckets" : "/api/timeline/bucket"))
        if let albumID {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains { $0.name == "albumId" && $0.value == albumID })
            #expect(items.contains { $0.name == "withStacked" && $0.value == "true" })
            #expect(items.contains { $0.name == "withPartners" && $0.value == "false" })
            #expect(items.contains { $0.name == "isTrashed" && $0.value == "false" })
            #expect(!items.contains { $0.name == "visibility" })
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"]))
        let json: String
        if operation == "getTimeBuckets" {
            bucketRequests += 1
            json = "[{\"count\":\(bucketRequests),\"timeBucket\":\"2026-11-01\"}]"
        } else {
            #expect(operation == "getTimeBucket")
            json = #"{"createdAt":[],"duration":[],"fileCreatedAt":[],"id":[],"isFavorite":[],"isImage":[],"isTrashed":[],"livePhotoVideoId":[],"localOffsetHours":[],"ownerId":[],"projectionType":[],"ratio":[],"thumbhash":[],"visibility":[]}"#
        }
        if holdsFirst, operations.count == 1 {
            await withCheckedContinuation { continuation in pending = continuation; waiter?.resume(returning: true); waiter = nil }
        }
        return (Data(json.utf8), response)
    }

    /// 如果请求在安装gate前就失败，通知测试并交回原始错误，防止等待超时掩盖契约失败。
    func failedBeforeGate() {
        failed = true
        waiter?.resume(returning: false)
        waiter = nil
    }

    /// 返回是否已到达真正的旧GET；请求提前失败时立即返回false。
    func waitForFirst() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 仅在新上下文读取结束后释放合法旧响应，原仓库必须在映射结果前拒绝它。
    func releaseFirst() {
        pending?.resume(); pending = nil
    }
}
