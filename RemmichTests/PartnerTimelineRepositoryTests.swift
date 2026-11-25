import Foundation
import Testing
@testable import Remmich

/// 原仓库policy读取的Loader端口回归；不把此合成字节测试称为真实URLSession/服务端HTTP验收。
@Suite("Partner timeline repository policy")
@MainActor struct PartnerTimelineRepositoryTests {
    /// 两次policy读取都真正进入既有Loader，认证/必需direction/操作ID明确，不能从Library伙伴卡或持久GET复用。
    @Test func readsFreshPolicyThroughTheOriginalRepositoryContext() async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: [policyExchange(), policyExchange()]); defer { fixture.close() }
        let repository = policyRepository(fixture)
        let session = checksumLookupSession(endpoint: fixture.endpoint); let scope = MediaAccountScope(session: session)
        _ = await repository.configure(session: session, activeEndpoint: fixture.endpoint)
        let first = try await repository.partnerTimelinePolicy(scope: scope)
        let second = try await repository.partnerTimelinePolicy(scope: scope)
        #expect(first == second && first.namespace == scope.cacheNamespace && first.isKnown)
        #expect(first.members.map(\.id) == [policyPartnerID] && first.members.first?.inTimeline == true)
        let requests = await fixture.script.requests()
        #expect(requests.count == 2 && requests.allSatisfy { $0.method == "GET" && $0.body == nil && $0.authorization == "Bearer checksum-owner" })
    }

    /// 缺bool仅为未知；错误HTTP状态不得降为空策略或当作只读卡已缓存的伙伴状态。
    @Test(arguments: ["missing-flag", "bad-status"])
    func unknownAndFailedPolicyReadsStayUnconfirmed(_ variant: String) async throws {
        let exchange = policyExchange(json: variant == "missing-flag" ? #"[{"id":"22222222-2222-4222-8222-222222222222","name":"Synthetic"}]"# : "[]",
                                      status: variant == "bad-status" ? 503 : 200)
        let fixture = ChecksumLookupHTTPFixture(exchanges: [exchange]); defer { fixture.close() }
        let repository = policyRepository(fixture); let session = checksumLookupSession(endpoint: fixture.endpoint)
        _ = await repository.configure(session: session, activeEndpoint: fixture.endpoint)
        if variant == "missing-flag" {
            let policy = try await repository.partnerTimelinePolicy(scope: .init(session: session))
            #expect(!policy.isKnown && policy.members.first?.inTimeline == nil)
        } else {
            do { _ = try await repository.partnerTimelinePolicy(scope: .init(session: session)); Issue.record("Failed policy HTTP must not become an empty policy.") }
            catch TimelineReadError.invalidResponse {}
        }
        #expect(await fixture.script.requests().count == 1)
    }

    /// 读取真挂起Loader后换号或换端点；不合作的旧响应回来时原repo代际必须拒绝，不能签发旧scope策略。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    func latePolicyCannotCrossRepositoryGeneration(_ reason: String) async throws {
        var exchange = policyExchange(); exchange.held = true
        let fixture = ChecksumLookupHTTPFixture(exchanges: [exchange]); defer { fixture.close() }
        let repository = policyRepository(fixture); let session = checksumLookupSession(endpoint: fixture.endpoint)
        _ = await repository.configure(session: session, activeEndpoint: fixture.endpoint)
        let task = Task { try await repository.partnerTimelinePolicy(scope: .init(session: session)) }
        let observer = Task { _ = await task.result; await fixture.script.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld())
                let next = reason == "account" ? checksumLookupSession(endpoint: fixture.endpoint, user: policyPartnerID, token: "new-account") : session
                _ = await repository.configure(session: next, activeEndpoint: reason == "endpoint" ? fixture.endpoint.appending(path: "new-route") : fixture.endpoint)
                await fixture.script.release(); await fixture.script.waitForHeldResponderExit()
                do { _ = try await task.value; Issue.record("A retired repository policy must not be published.") }
                catch TimelineReadError.staleGeneration {}
                #expect(await fixture.script.requests().count == 1)
            } onCancel: { task.cancel(); Task { await fixture.script.stop() } }
        } catch { task.cancel(); await fixture.script.stop(); _ = await task.result; await observer.value; throw error }
        await observer.value; await fixture.script.stop()
    }
}

private nonisolated let policyPartnerID = "22222222-2222-4222-8222-222222222222"

/// 仅用既有会话脚本检查准确请求/控制回调，不从Store或repo内部缓存生成成功数据。
@MainActor private func policyRepository(_ fixture: ChecksumLookupHTTPFixture) -> ImmichTimelineRepository {
    let script = fixture.script; let endpoint = fixture.endpoint
    return .init(readLoader: { request, operation in
        guard operation == "getPartners" else { throw URLError(.unsupportedURL) }
        let captured = try ChecksumLookupRequest(request)
        do {
            let exchange = try await script.response(captured, endpoint: endpoint)
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: exchange.status, httpVersion: nil,
                                                                        headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
            await script.responderExited(captured.id)
            return (Data(exchange.json.utf8), response)
        } catch { await script.responderExited(captured.id); throw error }
    })
}

/// 独立官方GET200响应，仅使用合成ID/名字；query必须是shared-with，不接受另一个方向或无过滤请求。
private nonisolated func policyExchange(json: String = #"[{"id":"22222222-2222-4222-8222-222222222222","name":"Synthetic","inTimeline":true}]"#, status: Int = 200) -> ChecksumLookupExchange {
    .init(method: "GET", path: "partners", status: status, json: json, query: [.init(name: "direction", value: "shared-with")])
}
