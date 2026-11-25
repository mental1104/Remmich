import Foundation
import Testing
@testable import Remmich

/// 用真实repository生命周期和SDK解码验证标签候选隔离；所有HTTP字节均来自本地合成Loader。
@Suite("Tag candidate ownership")
struct NativeSearchTagIsolationTests {
    /// change区分换账号、同账号换端点与清会话重登；旧请求故意在新请求成功后才返回。
    @Test(arguments: ["account", "endpoint", "sign-out"])
    func rejectsLateCandidatesFromThePreviousContext(_ change: String) async throws {
        let first = tagSession("first")
        let second = tagSession("second")
        let nextSession = change == "endpoint" ? first : second
        let fallback = try #require(URL(string: "https://fallback.example.invalid/api"))
        let nextEndpoint = change == "endpoint" ? fallback : first.apiURL
        let gate = TagCandidateGate(expected: [
            .init(endpoint: first.apiURL, token: first.accessToken),
            .init(endpoint: nextEndpoint, token: nextSession.accessToken),
        ])
        let source = ImmichTimelineRepository(readLoader: { request, operation in
            try await gate.load(request, operation: operation)
        })
        await source.configure(session: first, activeEndpoint: first.apiURL)
        let obsolete = Task { try await source.searchTags() }
        await gate.waitForFirstRequest()

        // 只调用生产账号/路由生命周期，测试不直接修改generation，也不取消旧传输来隐藏泄漏。
        switch change {
        case "endpoint": await source.updateRoute(nextEndpoint)
        case "sign-out":
            await source.clear()
            await #expect(throws: TimelineReadError.routeUnavailable) { try await source.searchTags() }
            await source.configure(session: nextSession, activeEndpoint: nextEndpoint)
        default: await source.configure(session: nextSession, activeEndpoint: nextEndpoint)
        }
        let current = await Task { try await source.searchTags() }.result
        await gate.releaseFirst()
        await #expect(throws: TimelineReadError.staleGeneration) { try await obsolete.value }
        let tags = try current.get()
        #expect(tags.map(\.id) == ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
        #expect(tags.map(\.value) == ["Current/Tag"])
        #expect(await gate.requestCount == 2)
    }
}

/// user只区分测试身份；使用相同API根证明账号切换不依赖URL变化，没有真实凭据。
private nonisolated func tagSession(_ user: String) -> AccountSession {
    .init(apiURL: URL(string: "https://synthetic.example.invalid/api")!, accessToken: "synthetic-\(user)", userID: user,
          userEmail: "\(user)@example.invalid", name: user, isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 每次真实SDK GET预期的端点和合成Bearer，避免注入Loader绕过路径或鉴权断言。
private nonisolated struct ExpectedTagRead: Sendable {
    let endpoint: URL
    let token: String
}

/// 暂停首个有效GET响应并立即服务第二个；明确握手不依赖sleep、全局URLProtocol或网络。
private actor TagCandidateGate {
    private let expected: [ExpectedTagRead]
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var firstResponse: (Data, HTTPURLResponse)?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    /// expected按实际请求顺序记录端点/身份，至少包含旧、新两次读取。
    init(expected: [ExpectedTagRead]) {
        self.expected = expected
    }

    /// request和operation来自认证后的SDK；返回合法标签JSON，首响应暂停直到releaseFirst。
    func load(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        let index = requestCount
        requestCount += 1
        #expect(operation == "getAllTags")
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        let owner = try #require(expected.indices.contains(index) ? expected[index] : nil)
        #expect(request.url == owner.endpoint.appending(path: "tags"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(owner.token)")
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"]))
        let id = index == 0 ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" : "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let value = index == 0 ? "Obsolete/Tag" : "Current/Tag"
        let json = #"[{"id":"\#(id)","name":"Tag","value":"\#(value)","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}]"#
        let result = (Data(json.utf8), response)
        guard index == 0 else { return result }
        firstResponse = result
        return await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// 等待旧请求完成鉴权及路径检查，确保生命周期变更发生在真实SDK读取期间。
    func waitForFirstRequest() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 释放完整有效的旧标签响应；即使新上下文已加载，也不能让旧结果穿过repository发布边界。
    func releaseFirst() {
        guard let pending, let firstResponse else {
            Issue.record("The obsolete tag response must be waiting before release")
            return
        }
        pending.resume(returning: firstResponse)
        self.pending = nil
        self.firstResponse = nil
    }
}
