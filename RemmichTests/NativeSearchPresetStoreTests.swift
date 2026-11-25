import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实Store→Management.perform→MutationClient链路只接收本地HTTP字节，验证登记生命周期与发布权。
@Suite("Saved search lifecycle")
struct NativeSearchPresetStoreTests {
    /// 409不能被确认成功或自动重放；重新读取前任何新写入均拒绝，重载成功后才允许明确再试。
    @Test @MainActor func conflictRequiresReloadBeforeAnotherWrite() async throws {
        let session = presetSession("first")
        let created = try presetRecord("Saved", conditions: #"{"city":"Synthetic City"}"#)
        let script = PresetHTTPScript([
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[]"),
            .init(method: "POST", url: presetURL(session.apiURL), token: session.accessToken, status: 409, json: "{}"),
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[]"),
            .init(method: "POST", url: presetURL(session.apiURL), token: session.accessToken, status: 201, json: created),
        ])
        let manager = makePresetManager(script, endpoints: [session.apiURL])
        defer { clearPresetManager(manager, endpoints: [session.apiURL]) }
        manager.configure(session: session, endpoint: session.apiURL)
        let store = NativeSearchPresetStore()
        var query = NativeSearchQuery()
        query.city = "Synthetic City"
        await store.load(manager: manager)
        #expect(store.supported == true && store.hasFreshData)

        let confirmed = await store.create(name: " Saved ", query: query, manager: manager)
        #expect(!confirmed)
        #expect(store.error?.contains("already exists") == true)
        #expect(!store.hasFreshData && store.presets.isEmpty && !store.busy && !manager.busy)
        #expect(await script.requests().count == 2)
        #expect(await !(store.create(name: "Saved", query: query, manager: manager)))
        #expect(await script.requests().count == 2)
        #expect(store.error == "Reload saved searches before editing.")

        await store.load(manager: manager)
        #expect(store.hasFreshData && store.error == nil)
        #expect(await store.create(name: " Saved ", query: query, manager: manager))
        #expect(store.presets.map(\.name) == ["Saved"])
        let requests = await script.requests()
        try #require(requests.count == 4)
        try expectPresetBody(requests[1], name: "Saved", conditions: #"{"city":"Synthetic City"}"#)
        try expectPresetBody(requests[3], name: "Saved", conditions: #"{"city":"Synthetic City"}"#)
        #expect(manager.revision == 0)
        // Panel只有收到true才清除名称草稿；本用例证明返回值/门禁，未声称执行了SwiftUI输入流程。
    }

    /// 改名必须先重读并发送服务端最新完整条件，包含null和本地旧行没有的设备/媒体/参考图字段。
    @Test @MainActor func renameRetainsLatestCompleteServerConditions() async throws {
        let session = presetSession("rename")
        let stale = try presetRecord("Old name", conditions: #"{"city":"Old City"}"#)
        let current = try presetRecord("Changed elsewhere", conditions: completePresetConditions)
        let renamed = try presetRecord("Renamed", conditions: completePresetConditions)
        let script = PresetHTTPScript([
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[\(stale)]"),
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[\(current)]"),
            .init(method: "PATCH", url: presetURL(session.apiURL, id: presetID), token: session.accessToken, status: 200, json: renamed),
        ])
        let manager = makePresetManager(script, endpoints: [session.apiURL])
        defer { clearPresetManager(manager, endpoints: [session.apiURL]) }
        manager.configure(session: session, endpoint: session.apiURL)
        let store = NativeSearchPresetStore()
        await store.load(manager: manager)
        let original = try #require(store.presets.first)
        #expect(await store.rename(original, name: "Renamed", manager: manager))
        let requests = await script.requests()
        try #require(requests.count == 3)
        try expectPresetBody(requests[2], name: "Renamed", conditions: completePresetConditions)
        #expect(store.presets.map(\.name) == ["Renamed"])
        #expect(store.hasFreshData && store.error == nil && !manager.busy)
        #expect(manager.revision == 0)
    }

    /// 替换条件不能恢复旧名称；重读后的名称与点击时完整查询一起进入真实PATCH请求。
    @Test @MainActor func replacementKeepsLatestNameAndUsesCompleteQuery() async throws {
        let session = presetSession("replace")
        let old = try presetRecord("Old name", conditions: #"{"city":"Old City"}"#)
        let current = try presetRecord("Latest name", conditions: completePresetConditions)
        let expected = #"{"query":{"value":"Replacement","type":"smart"},"city":"Replacement City","tagIds":null,"rating":null,"deviceModels":["Synthetic Model","Synthetic Alias"],"mediaType":"video","mediaCategory":"phone-video","resolution":"4k","isPanorama":true,"isFavorite":true,"albumStatus":"notIn","orientation":"landscape"}"#
        let replaced = try presetRecord("Latest name", conditions: expected)
        let script = PresetHTTPScript([
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[\(old)]"),
            .init(method: "GET", url: presetURL(session.apiURL), token: session.accessToken, status: 200, json: "[\(current)]"),
            .init(method: "PATCH", url: presetURL(session.apiURL, id: presetID), token: session.accessToken, status: 200, json: replaced),
        ])
        let manager = makePresetManager(script, endpoints: [session.apiURL])
        defer { clearPresetManager(manager, endpoints: [session.apiURL]) }
        manager.configure(session: session, endpoint: session.apiURL)
        let store = NativeSearchPresetStore()
        await store.load(manager: manager)
        let original = try #require(store.presets.first)
        var query = NativeSearchQuery()
        query.mode = .smart
        query.text = "Replacement"
        query.city = "Replacement City"
        query.tags = .untagged
        query.rating = .unrated
        query.deviceModels = ["Synthetic Model", "Synthetic Alias"]
        query.media = .video
        query.mediaCategory = .phoneVideo
        query.resolution = .fourK
        query.panoramasOnly = true
        query.favoritesOnly = true
        query.hasAlbums = false
        query.orientation = .landscape
        #expect(await store.replace(original, query: query, manager: manager))
        let requests = await script.requests()
        try #require(requests.count == 3)
        try expectPresetBody(requests[2], name: "Latest name", conditions: expected)
        #expect(store.presets.map(\.name) == ["Latest name"])
        #expect(store.hasFreshData && store.error == nil && manager.revision == 0)
    }

    /// change指定账号或同账号端点变化；正在读取的旧会话真实取消，当前列表不能被迟到的旧200覆盖。
    @Test(arguments: ["account", "endpoint"])
    @MainActor func contextChangeRejectsAnObsoleteStoreLoad(_ change: String) async throws {
        let first = presetSession("first")
        let second = change == "account" ? presetSession("second", endpoint: first.apiURL) : first
        let nextEndpoint = change == "endpoint" ? presetEndpoint("fallback") : first.apiURL
        let endpoints = Array(Set([first.apiURL, nextEndpoint]))
        let obsolete = try presetRecord("Obsolete", conditions: #"{"city":"Old City"}"#)
        let current = try presetRecord("Current", conditions: #"{"city":"New City"}"#)
        let script = PresetHTTPScript([
            .init(method: "GET", url: presetURL(first.apiURL), token: first.accessToken, status: 200, json: "[\(obsolete)]", held: true),
            .init(method: "GET", url: presetURL(nextEndpoint), token: second.accessToken, status: 200, json: "[\(current)]"),
        ])
        let manager = makePresetManager(script, endpoints: endpoints)
        defer { clearPresetManager(manager, endpoints: endpoints) }
        manager.configure(session: first, endpoint: first.apiURL)
        let store = NativeSearchPresetStore()
        let pending = Task {
            await store.load(manager: manager)
            await script.storeLoadFinished()
        }
        let reachedGate = await script.waitForHeldRequest()
        try #require(reachedGate, "The obsolete authenticated GET must reach its response gate")
        #expect(store.busy && manager.busy)

        // 这与真实Panel的manager.generation监听一致；不能只更改测试内部generation来模拟换号。
        manager.configure(session: second, endpoint: nextEndpoint)
        store.invalidate()
        await store.load(manager: manager)
        #expect(store.presets.map(\.name) == ["Current"])
        await script.releaseHeldResponse()
        await pending.value
        #expect(store.presets.map(\.name) == ["Current"])
        #expect(store.hasFreshData && store.supported == true && store.error == nil)
        #expect(!store.busy && !manager.busy && manager.revision == 0)
        #expect(await script.requests().count == 2)
    }

    /// 真正HTTP201已经解码后再挂起操作；change发生后释放该成功值，perform必须拒绝跨代际成功。
    @Test(arguments: ["account", "endpoint"])
    @MainActor func managementRejectsDecodedSuccessAfterContextChange(_ change: String) async throws {
        let first = presetSession("first")
        let second = change == "account" ? presetSession("second", endpoint: first.apiURL) : first
        let nextEndpoint = change == "endpoint" ? presetEndpoint("fallback") : first.apiURL
        let endpoints = Array(Set([first.apiURL, nextEndpoint]))
        let created = try presetRecord("Decoded old success", conditions: #"{"city":"Old City"}"#)
        let current = try presetRecord("Current", conditions: #"{"city":"New City"}"#)
        let script = PresetHTTPScript([
            .init(method: "POST", url: presetURL(first.apiURL), token: first.accessToken, status: 201, json: created),
            .init(method: "GET", url: presetURL(nextEndpoint), token: second.accessToken, status: 200, json: "[\(current)]"),
        ])
        let manager = makePresetManager(script, endpoints: endpoints)
        defer { clearPresetManager(manager, endpoints: endpoints) }
        manager.configure(session: first, endpoint: first.apiURL)
        let owner = manager.generation
        let gate = PresetDecodedSuccessGate()
        let conditions = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: Data(#"{"city":"Old City"}"#.utf8))
        let pending = Task {
            do {
                return try await manager.perform(publishChange: false) { client in
                    let result = try await client.createSearchPreset(name: "Decoded old success", conditions: conditions)
                    #expect(result.name == "Decoded old success")
                    await gate.suspendDecodedSuccess()
                    return result
                }
            } catch {
                // 真实解码/请求失败也要唤醒观察者，不能把失败变成等待gate的CI死锁。
                await gate.operationFailed()
                throw error
            }
        }
        guard await gate.waitUntilDecoded() else {
            _ = try await pending.value
            Issue.record("The authenticated POST must decode successfully before the context changes")
            return
        }
        #expect(manager.busy)
        manager.configure(session: second, endpoint: nextEndpoint)
        let store = NativeSearchPresetStore()
        await store.load(manager: manager)
        await gate.release()
        do {
            _ = try await pending.value
            Issue.record("Decoded success from an obsolete context must be rejected")
        } catch LibraryWriteError.changedAccount {}
        #expect(manager.generation != owner)
        #expect(store.presets.map(\.name) == ["Current"])
        #expect(store.hasFreshData && !store.busy && !manager.busy && manager.revision == 0)
        #expect(await script.requests().count == 2)
    }
}

/// 合成登记身份，与服务端UUID格式一致；不引用任何真实账号资料。
private nonisolated let presetID = "11111111-1111-4111-8111-111111111111"

/// 覆盖登记可保存的完整扩展字段及两个显式null；改名不经UI子集转换，必须原样保留。
private nonisolated let completePresetConditions = #"{"queryAssetId":"22222222-2222-4222-8222-222222222222","personIds":["33333333-3333-4333-8333-333333333333"],"tagIds":null,"country":"Synthetic Country","state":"Synthetic State","city":"Latest City","make":"Synthetic Make","model":"Synthetic Model","lensModel":"Synthetic Lens","deviceModels":["Synthetic Model","Synthetic Alias"],"takenAfter":"2026-01-01","takenBefore":"2026-11-24","isArchive":true,"isFavorite":true,"albumStatus":"notIn","mediaType":"video","isPanorama":true,"mediaCategory":"phone-video","resolution":"4k","orientation":"landscape","rating":null,"exifConditions":[{"field":"iso","operator":"gte","value":400}]}"#

/// user区分合成身份，endpoint默认使用独立随机host；返回真实AccountSession以驱动生产生命周期。
private nonisolated func presetSession(_ user: String, endpoint: URL? = nil) -> AccountSession {
    .init(apiURL: endpoint ?? presetEndpoint(user), accessToken: "synthetic-\(user)", userID: user,
          userEmail: "\(user)@example.invalid", name: user, isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// name为纯测试标识；随机host隔离并行测试，所有配置请求均由本地URLProtocol拦截。
private nonisolated func presetEndpoint(_ name: String) -> URL {
    URL(string: "https://\(name)-\(UUID().uuidString.lowercased()).preset-lifecycle.invalid/immich/api")!
}

/// endpoint为API根，id可选指定登记；返回准确路由以独立核对真实客户端请求。
private nonisolated func presetURL(_ endpoint: URL, id: String? = nil) -> URL {
    let route = endpoint.appending(path: "fork/search-presets")
    return id.map { route.appending(path: $0) } ?? route
}

/// name/conditions是合成响应内容；经标准JSON编码生成完整登记，非法JSON直接令测试失败。
private nonisolated func presetRecord(_ name: String, conditions: String) throws -> String {
    let object: [String: Any] = try ["id": presetID, "name": name,
                                     "conditions": JSONSerialization.jsonObject(with: Data(conditions.utf8))]
    return try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
}

/// script提供固定HTTP字节，endpoints为此测试独占host；返回真实manager，生产鉴权与取消链路均保留。
@MainActor private func makePresetManager(_ script: PresetHTTPScript, endpoints: [URL]) -> LibraryManagementController {
    for endpoint in endpoints {
        PresetLifecycleProtocol.install(script, endpoint: endpoint)
    }
    return LibraryManagementController(configurationFactory: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresetLifecycleProtocol.self]
        return configuration
    })
}

/// manager为待清理真实通道，endpoints为测试独占host；关闭会话并移除本地注册，不修改全局URLProtocol列表。
@MainActor private func clearPresetManager(_ manager: LibraryManagementController, endpoints: [URL]) {
    manager.configure(session: nil, endpoint: nil)
    for endpoint in endpoints {
        PresetLifecycleProtocol.remove(endpoint: endpoint)
    }
}

/// request是已认证客户端实际发送的字节；name/conditions为独立期望，比较完整JSON而非只检查字段存在。
private nonisolated func expectPresetBody(_ request: PresetCapturedRequest, name: String, conditions: String) throws {
    let data = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["name", "conditions"]))
    #expect(object["name"] as? String == name)
    let actual = try #require(object["conditions"] as? NSDictionary)
    let expected = try #require(JSONSerialization.jsonObject(with: Data(conditions.utf8)) as? NSDictionary)
    #expect(actual.isEqual(expected))
}

/// URLSession真实请求的不可变快照；从Foundation流转成Sendable字节后才交给测试actor。
private nonisolated struct PresetCapturedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let body: Data?

    /// request来自本地URLProtocol；完整读取有限合成请求体，流错误通过URLError报告。
    init(_ request: URLRequest) throws {
        method = try #require(request.httpMethod)
        url = try #require(request.url)
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = data
        } else {
            body = nil
        }
    }
}

/// 一次预定HTTP交换：固定方法、URL、Bearer及返回字节；held只暂停传输，不实现保存业务。
private nonisolated struct PresetHTTPExchange: Sendable {
    let method: String
    let url: URL
    let token: String
    let status: Int
    let json: String
    var held = false
}

/// 顺序返回独立声明的HTTP响应，记录实际字节；额外请求立即失败，不会落到真实网络。
private actor PresetHTTPScript {
    private let exchanges: [PresetHTTPExchange]
    private var captured: [PresetCapturedRequest] = []
    private var heldResponse: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Bool, Never>?
    private var heldRequestObserved = false
    private var finishedWithoutHeldRequest = false

    /// exchanges为完整预期序列；不推断客户端当前状态或替代Store逻辑。
    init(_ exchanges: [PresetHTTPExchange]) {
        self.exchanges = exchanges
    }

    /// request为真实客户端快照；先核对鉴权/路由再安装可选gate，返回固定HTTP交换供URLSession解码。
    func response(for request: PresetCapturedRequest) async throws -> PresetHTTPExchange {
        let index = captured.count
        captured.append(request)
        guard exchanges.indices.contains(index) else { throw URLError(.badServerResponse) }
        let exchange = exchanges[index]
        guard request.method == exchange.method, request.url == exchange.url,
              request.authorization == "Bearer \(exchange.token)"
        else { throw URLError(.badServerResponse) }
        if exchange.method == "POST" || exchange.method == "PATCH" {
            guard request.contentType == "application/json" else { throw URLError(.badServerResponse) }
        } else {
            guard request.body == nil else { throw URLError(.badServerResponse) }
        }
        if exchange.held {
            await withCheckedContinuation { continuation in
                heldRequestObserved = true
                heldResponse = continuation
                heldWaiter?.resume(returning: true)
                heldWaiter = nil
            }
        }
        return exchange
    }

    /// 在调用测试的Task上下文核对真实路由/鉴权并返回快照；用于证明409后没有额外网络写。
    func requests() -> [PresetCapturedRequest] {
        #expect(captured.count <= exchanges.count)
        for (request, exchange) in zip(captured, exchanges) {
            #expect(request.method == exchange.method)
            #expect(request.url == exchange.url)
            #expect(request.authorization == "Bearer \(exchange.token)")
            if exchange.method == "POST" || exchange.method == "PATCH" {
                #expect(request.contentType == "application/json")
            } else {
                #expect(request.body == nil)
            }
        }
        return captured
    }

    /// 返回旧请求是否已安装gate；若真实读取先失败则返回false，避免测试无限等待。
    func waitForHeldRequest() async -> Bool {
        if heldRequestObserved {
            return true
        }
        if finishedWithoutHeldRequest {
            return false
        }
        return await withCheckedContinuation { heldWaiter = $0 }
    }

    /// Store读取已经结束；未进入gate说明真实捕获/HTTP读取提前失败，必须释放等待中的测试。
    func storeLoadFinished() {
        guard !heldRequestObserved else { return }
        finishedWithoutHeldRequest = true
        heldWaiter?.resume(returning: false)
        heldWaiter = nil
    }

    /// 释放预定旧200；URLSession取消保护仍生效，此处不绕过stopLoading或强制发布到业务层。
    func releaseHeldResponse() {
        guard let heldResponse else {
            Issue.record("An obsolete HTTP response must be held before release")
            return
        }
        heldResponse.resume()
        self.heldResponse = nil
    }
}

/// 仅配置到测试独有URLSession的本地HTTP响应器；每个host独立注册，绝不注册全局协议或建立连接。
private final nonisolated class PresetLifecycleProtocol: URLProtocol, @unchecked Sendable {
    /// 单次协议读取的取消状态；锁保护URLSession回调线程和异步fixture任务之间的访问。
    private struct LoadingState: Sendable {
        var stopped = false
        var task: Task<Void, Never>?
    }

    private static let scripts = Mutex<[String: PresetHTTPScript]>([:])
    private let loading = Mutex(LoadingState())

    /// script归属endpoint的独占host；只更改本测试类的注册表，不影响其他会话。
    static func install(_ script: PresetHTTPScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = script }
    }

    /// endpoint的测试已结束；删除对应响应来源以释放actor。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 此协议仅存在于隔离会话；拦截全部请求，使任何意外host也无法访问真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// request保持原URL/方法/头，避免fixture规范化掩盖实际客户端错误。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 捕获真实HTTP字节并异步服务固定响应；缺少注册或非法输入直接让URLSession失败。
    override func startLoading() {
        do {
            let capturedRequest = try PresetCapturedRequest(request)
            let script = try #require(Self.scripts.withLock { $0[capturedRequest.url.host ?? ""] })
            // 显式发送不可变快照与actor，不让Task推断捕获URLProtocol的继承隔离上下文。
            let task = Task { @Sendable [weak self, script, capturedRequest] in
                do {
                    let exchange = try await script.response(for: capturedRequest)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    let response = try #require(HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status,
                                                                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(exchange.json.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            loading.withLock {
                $0.task = task
                if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 生产客户端invalidateAndCancel必须真正停止传输回调；不为迟到响应测试忽略取消。
    override func stopLoading() {
        let task = loading.withLock {
            $0.stopped = true
            return $0.task
        }
        task?.cancel()
    }
}

/// 仅在真实HTTP201已成功解码之后挂起perform的返回值，独立验证代际守卫而非依赖URLSession取消。
private actor PresetDecodedSuccessGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false

    /// 成功对象已由调用方持有；安装gate后通知测试，直到身份/端点切换完成才继续。
    func suspendDecodedSuccess() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume(returning: true)
            waiter = nil
        }
    }

    /// 返回是否已解码成功；真实请求或解码提前抛错时返回false，由测试转交原始失败。
    func waitUntilDecoded() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// operation在gate之前失败也要通知观察者；不篡改manager/store，也不把失败当作成功。
    func operationFailed() {
        failed = true
        waiter?.resume(returning: false)
        waiter = nil
    }

    /// 放行旧代际的成功返回值；不修改manager/store的状态，也不取消任务来掩盖发布检查。
    func release() {
        pending?.resume()
        pending = nil
    }
}
