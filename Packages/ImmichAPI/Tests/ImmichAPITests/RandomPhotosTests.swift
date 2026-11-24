import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 官方随机入口真实编码为只读POST；每次抽样由服务端执行，不把本地首屏打乱或当成可续页结果。
@Suite("Random photo contracts")
struct RandomPhotosTests {
    /// 两次调用发送同一完整范围但消费不同服务器批次；POST不能进入持久GET loader。
    @Test func refreshesThroughTheOfficialRandomEndpoint() async throws {
        let source = RandomPhotoTransport()
        let transport = ImmichQueuedReadTransport(searchTransport: source) { _, _ in
            Issue.record("Random POST must not enter the durable GET queue")
            throw CancellationError()
        }
        let endpoint = try #require(URL(string: "https://example.invalid/immich/api"))
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"), transport: transport)
        #expect(try await client.randomPhotos().map(\.id) == ["batch-1"])
        #expect(try await client.randomPhotos().map(\.id) == ["batch-2"])
        #expect(await source.requests == 2)
    }

    /// status覆盖鉴权、权限、缺路由和网络端错误；不能伪装为空批次或改走metadata搜索。
    @Test(arguments: [401, 403, 404, 429, 500])
    func preservesHTTPFailures(_ status: Int) async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"),
                                  transport: FixedRandomTransport(status: status, json: "{}"))
        await #expect(throws: ImmichClient.map(status: status)) { try await client.randomPhotos() }
    }

    /// scope表示错误媒体/可见性/回收站或超量；有效JSON也不能突破随机页声明的安全范围。
    @Test(arguments: ["video", "archive", "trash", "overflow"])
    func rejectsResponsesOutsideTheRequestedScope(_ scope: String) async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let first = randomAssetJSON(id: "first", type: scope == "video" ? "VIDEO" : "IMAGE",
                                    visibility: scope == "archive" ? "archive" : "timeline", trashed: scope == "trash")
        let json = scope == "overflow" ? "[\(first),\(randomAssetJSON(id: "second"))]" : "[\(first)]"
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"),
                                  transport: FixedRandomTransport(status: 200, json: json))
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.randomPhotos(size: 1) }
    }

    /// 未认证或越界size在传输前拒绝；精确操作/路径策略不能被其他POST或方法冒用。
    @Test func rejectsInvalidCallsBeforeTransport() async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let source = RandomNeverSendTransport()
        let anonymous = ImmichClient(apiURL: endpoint, transport: source)
        await #expect(throws: ImmichAPIError.unauthorized) { try await anonymous.randomPhotos() }
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"), transport: source)
        for size in [0, 1001] {
            await #expect(throws: ImmichAPIError.invalidResponse) { try await client.randomPhotos(size: size) }
        }
        for request in [HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/assets"),
                        HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/search/random")]
        {
            #expect(throws: ImmichAPIError.readOnlyPolicyViolation(operationID: "searchRandom")) {
                try ReadOnlyOperationPolicy.validate(request: request, operationID: "searchRandom")
            }
        }
        try ReadOnlyOperationPolicy.validate(request: .init(method: .post, scheme: nil, authority: nil, path: "/search/random"), operationID: "searchRandom")
    }

    /// 随机操作不能借ID访问写入路径或省略JSON体；持久loader和前台transport均不得收到非法请求。
    @Test func rejectsInvalidQueuedRandomRequests() async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let transport = ImmichQueuedReadTransport(searchTransport: RandomNeverSendTransport()) { _, _ in
            Issue.record("Invalid random POST must not enter the GET loader")
            throw CancellationError()
        }
        for path in ["/assets", "/search/random"] {
            await #expect(throws: ImmichAPIError.invalidResponse) {
                try await transport.send(.init(method: .post, scheme: nil, authority: nil, path: path),
                                         body: path == "/assets" ? HTTPBody("{}") : nil, baseURL: endpoint, operationID: "searchRandom")
            }
        }
    }

    /// 取消发生在实际POST在途后；服务端即使返回有效照片，也不能作为成功结果交给调用方。
    @Test func rejectsLateSuccessAfterCancellation() async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let source = DelayedRandomTransport()
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"), transport: source)
        let pending = Task {
            do { return try await client.randomPhotos() }
            catch { await source.failedBeforeRequest(); throw error }
        }
        guard await source.waitForRequest() else {
            _ = try await pending.value
            Issue.record("The random POST must enter its gate before cancellation")
            return
        }
        pending.cancel()
        await source.release()
        await #expect(throws: ImmichAPIError.cancelled) { try await pending.value }
    }
}

/// id/type/visibility/trashed仅描述本地合成资产；返回真实AssetResponseDto所需JSON，不读取文件。
private func randomAssetJSON(id: String, type: String = "IMAGE", visibility: String = "timeline", trashed: Bool = false) -> String {
    #"{"id":"\#(id)","originalPath":"/synthetic/\#(id).jpg","checksum":"synthetic","createdAt":"2026-11-01T00:00:00Z","fileCreatedAt":"2026-11-01T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"isTrashed":\#(trashed),"localDateTime":"2026-11-01T00:00:00Z","originalFileName":"synthetic.jpg","ownerId":"synthetic","type":"\#(type)","updatedAt":"2026-11-01T00:00:00Z","visibility":"\#(visibility)"}"#
}

/// 每次合法随机请求返回新合成批次；记录调用次数以证明真正再次访问官方随机入口。
private actor RandomPhotoTransport: ClientTransport {
    private(set) var requests = 0

    /// request/body为真实SDK输出，baseURL保留API前缀；检查所有范围且拒绝虚构分页字段。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        requests += 1
        #expect(operationID == "searchRandom" && request.method == .post && request.path == "/search/random")
        #expect(baseURL.path == "/immich/api")
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        let bytes = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(json["size"] as? Int == 60)
        #expect(json["withExif"] as? Bool == true)
        #expect(json["cursor"] == nil && json["page"] == nil && json["type"] == nil)
        let filter = try #require(json["filter"] as? [String: Any])
        #expect((filter["type"] as? [String: String])?["eq"] == "IMAGE")
        #expect((filter["visibility"] as? [String: String])?["eq"] == "timeline")
        #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody("[\(randomAssetJSON(id: "batch-\(requests)"))]"))
    }
}

/// status/json是固定合成响应；不转换请求，也不访问网络。
private struct FixedRandomTransport: ClientTransport {
    let status: Int
    let json: String

    /// 所有请求均只读；返回指定HTTP状态与原始JSON以覆盖SDK解码和错误映射。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        (HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]), HTTPBody(json))
    }
}

/// 前置校验失败时任何实际发送都代表契约回归。
private struct RandomNeverSendTransport: ClientTransport {
    /// 参数不应到达传输；记录失败并抛取消，绝不建立连接。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Invalid random photo request must fail before transport")
        throw CancellationError()
    }
}

/// 以明确gate暂停有效随机响应，测试取消不依赖sleep或取消传输替身。
private actor DelayedRandomTransport: ClientTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false

    /// 暂停真实SDK发送后返回有效照片；故意不遵循取消，由SDK的发布边界拒绝迟到成功。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        await withCheckedContinuation { continuation in pending = continuation; waiter?.resume(returning: true); waiter = nil }
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody("[\(randomAssetJSON(id: "late"))]"))
    }

    /// 确保请求已在途，防止尚未开始的任务被误当成迟到响应场景。
    func waitForRequest() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 请求前置编码若失败也必须唤醒测试，由调用方传播真实错误，不将失败变为永远等待。
    func failedBeforeRequest() {
        failed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 释放一次有效响应，不替代SDK或原生状态机检查取消。
    func release() {
        pending?.resume(); pending = nil
    }
}
