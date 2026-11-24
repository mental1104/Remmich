import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 使用真实repo/SDK/URLSession和合成HTTP验证人物契约，不接触私人识别数据或真实服务器。
@Suite("People management HTTP contracts")
struct PeopleManagementContractTests {
    /// 真正Store→原repo→SDK读取→GET预检→PUT→新GET闭环，不能以局部回执冒充列表已更新。
    @Test @MainActor func nativeStateUsesTheRealFreshRenameFlow() async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: [
            "GET /prefix/api/people?page=1": [.init(json: peoplePage([personJSON(peopleA, name: "Before")], hasNext: false)),
                                              .init(json: peoplePage([personJSON(peopleA, name: "After")], hasNext: false))],
            "GET /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA, name: "Before"))],
            "PUT /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA, name: "After"))],
        ])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let repo = ImmichTimelineRepository(readLoader: { request, operation in
            #expect(operation == "getAllPeople")
            let captured = try PeopleCapturedRequest(request)
            return try await fixture.response(captured).response(url: captured.url)
        }, peopleConfigurationFactory: { peopleConfiguration() })
        await repo.configure(session: peopleSession(endpoint), activeEndpoint: endpoint)
        let store = PeopleManagementStore()
        await store.reload(source: repo)
        let expected = try #require(store.people.first)
        await store.rename(expected, name: "After", source: repo)
        #expect(store.people.map(\.name) == ["After"] && !store.needsReload && store.error == nil)
        let requests = await fixture.requests
        #expect(requests.map(\.method) == ["GET", "GET", "PUT", "GET"])
        #expect(requests.allSatisfy { $0.authorization == "Bearer synthetic" })
        let write = try #require(requests.first { $0.method == "PUT" })
        #expect(try write.jsonBody().isEqual(to: ["name": "After", "userId": peopleUser]))
        await repo.clear()
    }

    /// 人物写仅发送明确字段：姓名限本人、隐藏不带资产visibility、合并保留有向ids并核全部回执。
    @Test func sendsExactScopedBodiesAndOrderedMerge() async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: [
            "GET /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA, name: "Before"))],
            "PUT /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA, name: "After")), .init(json: personJSON(peopleA, name: "After", hidden: true))],
            "POST /prefix/api/people/merge": [.init(json: mergeJSON([peopleA, peopleB]))],
        ])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let client = PeopleMutationClient(apiURL: endpoint, token: "synthetic", userID: peopleUser, configuration: peopleConfiguration())
        defer { client.cancel() }
        #expect(try await client.person(peopleA).name == "Before")
        try await client.rename(peopleA, name: "After")
        try await client.setHidden(peopleA, hidden: true)
        try await client.merge(targetID: peopleA, sourceID: peopleB)
        let requests = await fixture.requests
        #expect(requests.map(\.method) == ["GET", "PUT", "PUT", "POST"])
        #expect(requests.allSatisfy { $0.authorization == "Bearer synthetic" && $0.accept == "application/json" })
        #expect(requests.dropFirst().allSatisfy { $0.contentType == "application/json" })
        #expect(try requests[1].jsonBody().isEqual(to: ["name": "After", "userId": peopleUser]))
        #expect(try requests[2].jsonBody().isEqual(to: ["isHidden": true]))
        #expect(try requests[3].jsonBody().isEqual(to: ["ids": [peopleA, peopleB]]))
    }

    /// 成功状态必须精确200；权限/限流/错误状态保留失败，写入没有自动重试。
    @Test(arguments: [201, 204, 401, 403, 429, 500])
    func rejectsUnexpectedStatusesWithoutReplay(_ status: Int) async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: ["PUT /prefix/api/people/\(peopleA)": [.init(status: status, json: personJSON(peopleA, hidden: true))]])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let client = PeopleMutationClient(apiURL: endpoint, token: "synthetic", userID: peopleUser, configuration: peopleConfiguration())
        defer { client.cancel() }
        do {
            try await client.setHidden(peopleA, hidden: true)
            Issue.record("Unexpected status must fail")
        } catch let error as LibraryWriteError {
            switch error {
            case .malformedResponse: #expect((200 ..< 300).contains(status))
            case let .http(actual): #expect(actual == status && !(200 ..< 300).contains(status))
            default: Issue.record("Status must retain its HTTP or exact-success error")
            }
        }
        #expect(await fixture.requests.count == 1)
    }

    /// HTTP200也可能部分成功；缺失/重复/其他ID和失败回执都不能计为完整合并。
    @Test(arguments: ["partial", "error-message", "missing", "duplicate", "wrong-id"])
    func validatesEveryMergeReceipt(_ mode: String) async throws {
        let endpoint = peopleEndpoint()
        let json = switch mode {
        case "partial": #"[{"id":"\#(peopleA)","success":true},{"id":"\#(peopleB)","success":false,"error":"no_permission"}]"#
        case "error-message": #"[{"id":"\#(peopleA)","success":true},{"id":"\#(peopleB)","success":true,"errorMessage":"synthetic error"}]"#
        case "missing": mergeJSON([peopleA])
        case "duplicate": mergeJSON([peopleA, peopleA])
        default: mergeJSON([peopleA, peopleC])
        }
        let fixture = PeopleHTTPFixture(routes: ["POST /prefix/api/people/merge": [.init(json: json)]])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let client = PeopleMutationClient(apiURL: endpoint, token: "synthetic", userID: peopleUser, configuration: peopleConfiguration())
        defer { client.cancel() }
        if mode == "partial" || mode == "error-message" {
            await #expect(throws: PeopleManagementError.incompleteMerge) { try await client.merge(targetID: peopleA, sourceID: peopleB) }
        } else {
            do {
                try await client.merge(targetID: peopleA, sourceID: peopleB)
                Issue.record("Incomplete receipt identities must fail")
            } catch LibraryWriteError.malformedResponse {}
        }
        #expect(await fixture.requests.count == 1)
    }

    /// 每次重载都重新读取官方分页，含隐藏人物且保留日期；相同URL也不能复用completed索引GET。
    @Test func reloadsFreshPaginatedPeopleIncludingHidden() async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: [
            "GET /prefix/api/people?page=1": [.init(json: peoplePage([personJSON(peopleA), personJSON(peopleB, hidden: true)], hasNext: true)),
                                              .init(json: peoplePage([personJSON(peopleA, name: "Fresh")], hasNext: false))],
            "GET /prefix/api/people?page=2": [.init(json: peoplePage([personJSON(peopleC)], hasNext: false))],
        ])
        let repo = ImmichTimelineRepository(readLoader: { request, operation in
            #expect(operation == "getAllPeople")
            let query = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains { $0.name == "withHidden" && $0.value == "true" })
            #expect(query.contains { $0.name == "size" && $0.value == "250" })
            let captured = try PeopleCapturedRequest(request)
            #expect(captured.authorization == "Bearer synthetic")
            let reply = try await fixture.response(captured)
            return try reply.response(url: captured.url)
        })
        await repo.configure(session: peopleSession(endpoint), activeEndpoint: endpoint)
        let first = try await repo.managementPeople()
        #expect(Set(first.map(\.id)) == Set([peopleA, peopleB, peopleC]))
        #expect(first.first { $0.id == peopleB }?.isHidden == true)
        #expect(first.allSatisfy { $0.updatedAt != nil })
        #expect(try await repo.managementPeople().map(\.name) == ["Fresh"])
        #expect(await fixture.requests.count == 3)
    }

    /// 确认后服务器字段已变时，只做真实GET并拒绝PUT，不能盲目覆盖新状态。
    @Test func stopsWhenFreshPreflightDiffers() async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: ["GET /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA, name: "Changed"))]])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let repo = ImmichTimelineRepository(peopleConfigurationFactory: { peopleConfiguration() })
        await repo.configure(session: peopleSession(endpoint), activeEndpoint: endpoint)
        await #expect(throws: PeopleManagementError.changedPerson) {
            try await repo.renamePerson(.init(id: peopleA, name: "Before", isHidden: false), name: "After")
        }
        #expect(await fixture.requests.map(\.method) == ["GET"])
        await repo.clear()
    }

    /// 真实预检GET在途时撤销账号/端点/会话，旧响应不得继续启动PUT，也不得重放到新身份。
    @Test(arguments: ["account", "endpoint", "clear"])
    func cancelsPreflightBeforeAnyWrite(_ change: String) async throws {
        let endpoint = peopleEndpoint()
        let fixture = PeopleHTTPFixture(routes: ["GET /prefix/api/people/\(peopleA)": [.init(json: personJSON(peopleA), held: true)]])
        PeopleHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { PeopleHTTPProtocol.remove(endpoint: endpoint) }
        let repo = ImmichTimelineRepository(peopleConfigurationFactory: { peopleConfiguration() })
        await repo.configure(session: peopleSession(endpoint), activeEndpoint: endpoint)
        let pending = Task {
            do { try await repo.setPersonHidden(.init(id: peopleA, name: "Synthetic", isHidden: false), hidden: true) }
            catch { await fixture.failedBeforeGate(); throw error }
        }
        guard await fixture.waitForRequest() else {
            try await pending.value
            Issue.record("Person preflight must enter its gate")
            return
        }
        switch change {
        case "account": await repo.configure(session: peopleSession(endpoint, user: peopleB, token: "new"), activeEndpoint: endpoint)
        case "endpoint": await repo.updateRoute(peopleEndpoint())
        default: await repo.clear()
        }
        await fixture.release()
        await #expect(throws: TimelineReadError.staleGeneration) { try await pending.value }
        #expect(await fixture.requests.map(\.method) == ["GET"])
        await repo.clear()
    }
}

/// 合成人物/用户UUID，不映射任何真实账户或人脸。
private nonisolated let peopleA = "11111111-1111-4111-8111-111111111111"
private nonisolated let peopleB = "22222222-2222-4222-8222-222222222222"
private nonisolated let peopleC = "33333333-3333-4333-8333-333333333333"
private nonisolated let peopleUser = "44444444-4444-4444-8444-444444444444"

/// 每个测试独占host和API前缀，避免并行测试共享注册/请求。
private nonisolated func peopleEndpoint() -> URL {
    URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/prefix/api")!
}

/// endpoint/user/token为合成认证上下文；真实repo仍负责配置和代际撤销。
private nonisolated func peopleSession(_ endpoint: URL, user: String = peopleUser, token: String = "synthetic") -> AccountSession {
    .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 专用前台session拦截全部HTTP；不全局注册协议，任何意外host也不会访问网络。
private nonisolated func peopleConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PeopleHTTPProtocol.self]
    return config
}

/// id/name/hidden为合成字段；提供SDK实际PersonResponseDto必需字段和带毫秒日期。
private nonisolated func personJSON(_ id: String, name: String = "Synthetic", hidden: Bool = false) -> String {
    #"{"id":"\#(id)","name":"\#(name)","isHidden":\#(hidden),"birthDate":null,"thumbnailPath":"/synthetic","updatedAt":"2026-11-24T00:00:00.123Z"}"#
}

/// records保留服务器顺序，hasNext按官方页契约显式控制，不以空数组代替失败。
private nonisolated func peoplePage(_ records: [String], hasNext: Bool) -> String {
    #"{"total":3,"hidden":1,"people":[\#(records.joined(separator: ","))],"hasNextPage":\#(hasNext)}"#
}

/// ids为服务器明确确认的全部请求ID，用于验证有向合并和回执集合。
private nonisolated func mergeJSON(_ ids: [String]) -> String {
    "[" + ids.map { #"{"id":"\#($0)","success":true}"# }.joined(separator: ",") + "]"
}

/// 单次真实HTTP字节的Sendable快照；流体完整收集且有上限，避免URLProtocol遗漏POST正文。
private nonisolated struct PeopleCapturedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let accept: String?
    let contentType: String?
    let body: Data?

    /// request为实际URLSession/SDK输出；不改路径、查询、鉴权或JSON。
    init(_ request: URLRequest) throws {
        method = try #require(request.httpMethod)
        url = try #require(request.url)
        authorization = request.value(forHTTPHeaderField: "Authorization")
        accept = request.value(forHTTPHeaderField: "Accept")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        if let bytes = request.httpBody {
            body = bytes
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = bytes
        } else {
            body = nil
        }
    }

    /// 返回整个JSON字典供精确字段/顺序比较，缺正文或解码失败直接使测试失败。
    func jsonBody() throws -> NSDictionary {
        // 分开展开两个宏，避免Swift Testing把嵌套#require判定为递归；两个必要断言均保留。
        let bytes = try #require(body)
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try #require(object as? NSDictionary)
    }
}

/// 明确HTTP状态/原始JSON及可选gate；用于真实请求而非替换repo操作返回值。
private nonisolated struct PeopleHTTPReply: Sendable {
    var status = 200
    let json: String
    var held = false

    /// url沿用真实请求，返回有限合成HTTP响应给SDK loader。
    func response(url: URL) throws -> (Data, HTTPURLResponse) {
        try (Data(json.utf8), #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
}

/// 路由响应严格消费一次；缺脚本立即失败，可暂停真实GET并记录是否有额外写/重试。
private actor PeopleHTTPFixture {
    private var routes: [String: [PeopleHTTPReply]]
    private(set) var requests: [PeopleCapturedRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false

    /// routes以方法+路径+可选page定义独立HTTP脚本，合并的两个预检GET不依赖调度先后。
    init(routes: [String: [PeopleHTTPReply]]) {
        self.routes = routes
    }

    /// request为完整真实字节；逐条消费后可挂起，客户端取消由URLProtocol实际处理。
    func response(_ request: PeopleCapturedRequest) async throws -> PeopleHTTPReply {
        requests.append(request)
        let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        let key = request.method + " " + request.url.path + (page.map { "?page=\($0)" } ?? "")
        guard var replies = routes[key], !replies.isEmpty else { failedBeforeGate(); throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        routes[key] = replies
        if reply.held {
            await withCheckedContinuation { pending = $0; waiter?.resume(returning: true); waiter = nil }
        }
        return reply
    }

    /// 编码/路由在gate前失败必须唤醒测试，不能以永远等待掩盖真实失败。
    func failedBeforeGate() {
        failed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 等待实际HTTP进入gate，避免通过sleep推测旧请求已在途。
    func waitForRequest() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 测试在撤销上下文后释放原响应，确认客户端/仓库不能继续写入。
    func release() {
        pending?.resume(); pending = nil
    }
}

/// 只装入本测试session的HTTP适配，遵守真实invalidateAndCancel，不为迟到测试伪造取消行为。
private final nonisolated class PeopleHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let fixtures = Mutex<[String: PeopleHTTPFixture]>([:])
    private let loading = Mutex<(stopped: Bool, task: Task<Void, Never>?)>((false, nil))

    /// endpoint为测试独占host，fixture为其有限响应脚本。
    static func install(_ fixture: PeopleHTTPFixture, endpoint: URL) {
        fixtures.withLock { $0[endpoint.host!] = fixture }
    }

    /// 测试结束释放该host响应器，其他并行会话不受影响。
    static func remove(endpoint: URL) {
        _ = fixtures.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 拦截配置会话的全部请求，阻止未注册host意外联网。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留实际请求，防止规范化掩盖路径/正文错误。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 收集真实请求并提供本地响应；流/脚本错误经URLSession错误路径传播。
    override func startLoading() {
        do {
            let capturedRequest = try PeopleCapturedRequest(request)
            let fixture = try #require(Self.fixtures.withLock { $0[capturedRequest.url.host ?? ""] })
            // 明确捕获Sendable请求和actor，保留原有取消检查与HTTP响应顺序。
            let task = Task { @Sendable [weak self, capturedRequest, fixture] in
                do {
                    let reply = try await fixture.response(capturedRequest)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    let (data, response) = try reply.response(url: capturedRequest.url)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// URLSession撤销真实底层任务；fixture gate由测试释放，之后不会再回调成功。
    override func stopLoading() {
        loading.withLock { $0.stopped = true; $0.task?.cancel() }
    }
}
