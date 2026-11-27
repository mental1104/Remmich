import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实LibraryMutationClient/URLSession字节边界；只替换HTTP协议来源，不复制decoder或绕过鉴权/请求构造。
@Suite("Local media metadata HTTP sequence")
@MainActor struct LocalMediaMetadataHTTPTests {
    /// 批量浏览恢复必须走有鉴权的标准身份OR过滤；额外ID、重复项和截断分页均不能保存为关联证据。
    @Test(arguments: ["ok", "foreign", "duplicate", "cursor"])
    func batchAssetEvidenceRejectsUnboundedOrForeignResponses(_ mode: String) async throws {
        let id = try #require(UUID(uuidString: metadataHTTPAssetA))
        let item: [String: Any] = ["id": mode == "foreign" ? metadataHTTPAssetB : metadataHTTPAssetA,
                                   "ownerId": metadataHTTPAssetA, "type": "IMAGE", "isTrashed": false, "isOffline": false,
                                   "isEdited": false, "checksum": Data(repeating: 1, count: 20).base64EncodedString(),
                                   "updatedAt": "2026-11-27T00:00:00Z"]
        var page: [String: Any] = ["items": mode == "duplicate" ? [item, item] : [item]]
        if mode == "cursor" {
            page["nextCursor"] = "unexpected-more"
        }
        let data = try JSONSerialization.data(withJSONObject: ["assets": page])
        let fixture = LocalMetadataHTTPFixture([.init(chunks: [data])])
        defer { fixture.close() }
        if mode == "ok" {
            let result = try await fixture.client.localMediaAssets([id])
            #expect(result.map(\.id) == [id])
        } else {
            await #expect(throws: LibraryWriteError.malformedResponse) { _ = try await fixture.client.localMediaAssets([id]) }
        }
        let requests = await fixture.script.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1 && request.method == "POST" && request.url.path == "/prefix/api/search/metadata")
        #expect(request.authorization == "Bearer synthetic-local-read")
        let body = try #require(JSONSerialization.jsonObject(with: #require(request.body)) as? [String: Any])
        let filter = try #require(body["filter"] as? [String: Any])
        let branches = try #require(filter["or"] as? [[String: [String: String]]])
        #expect(branches == [["id": ["eq": id.uuidString]]])
        #expect(body["size"] as? Int == 2 && body["withExif"] as? Bool == false)
    }

    /// 官方JSONL envelope/ack形状保持完整opaque ID和重复候选；只读GET→POST，绝不reset/ACK/读取媒体。
    @Test(arguments: [false, true]) func fullGoldenStreamUsesOnlyFixedReadSequence(_ fullIndex: Bool) async throws {
        let fixture = LocalMetadataHTTPFixture([
            .ack(#"[{"type":"AssetV2","ack":"AssetV2|previous-checkpoint"}]"#),
            .stream(metadataHTTPGolden, mime: "Application/Jsonlines+Json; charset=UTF-8"),
        ])
        defer { fixture.close() }
        let result = try await fullIndex ? fixture.client.localMediaMetadataSnapshot() : fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        let expectedA = try #require(UUID(uuidString: metadataHTTPAssetA))
        let expectedB = try #require(UUID(uuidString: metadataHTTPAssetB))
        let foreign = try #require(UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"))
        #expect(result.map(\.assetID) == (fullIndex ? [foreign, expectedA, expectedB] : [expectedA, expectedB]))
        for record in result {
            let json = try JSONSerialization.jsonObject(with: record.value)
            let body = try #require(json as? [String: String])
            #expect(body == ["iCloudId": record.assetID == foreign ? metadataHTTPOpaqueID + "-foreign" : metadataHTTPOpaqueID, "createdAt": "2020-01-02T03:04:05Z", "latitude": "0", "longitude": "0"])
        }
        let requests = await fixture.script.requests
        try metadataHTTPAssertSequence(requests, endpoint: fixture.endpoint, count: 2)
    }

    /// 相同client每次重新读真实ack/stream，第二次空完整响应不能重放上一批候选或复用completed GET。
    @Test func repeatedReadsRemainFreshAndDoNotAcknowledge() async throws {
        let fixture = LocalMetadataHTTPFixture([.ack(), .stream(metadataHTTPGolden), .ack(), .stream(metadataHTTPComplete)])
        defer { fixture.close() }
        let first = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        let second = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        #expect(first.count == 2 && second.isEmpty)
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 4)
    }

    /// 空输入不做能力/ready探针，无效不透明标识在任何HTTP前失败。
    @Test(arguments: [false, true])
    func emptyOrInvalidInputDoesNotSendRequests(_ invalid: Bool) async throws {
        let fixture = LocalMetadataHTTPFixture([])
        defer { fixture.close() }
        if invalid {
            await #expect(throws: LocalMediaMetadataStreamError.invalidInput) { _ = try await fixture.client.localMediaMetadata(cloudIDs: [""]) }
        } else {
            #expect(try await fixture.client.localMediaMetadata(cloudIDs: []).isEmpty)
        }
        #expect(await fixture.script.requests.isEmpty)
    }

    /// 已有metadata检查点只会增量；真实GET后停止，不能追加stream/reset/delete-ack伪造全量成功。
    @Test(arguments: ["AssetMetadataV1", "AssetMetadataDeleteV1"])
    func metadataCheckpointStopsBeforeStream(_ type: String) async throws {
        let fixture = LocalMetadataHTTPFixture([.ack("[{\"type\":\"\(type)\",\"ack\":\"\(type)|previous\"}]")])
        defer { fixture.close() }
        await #expect(throws: LocalMediaMetadataStreamError.metadataCheckpointExists) {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 1)
    }

    /// ACK必须精确200；错误或其他2xx都不能开始流读取，保持服务器会话进度不变。
    @Test(arguments: [201, 204, 401, 403, 500])
    func ackStatusFailureCannotStartStream(_ status: Int) async throws {
        let fixture = LocalMetadataHTTPFixture([.init(status: status, chunks: [Data("[]".utf8)])])
        defer { fixture.close() }
        do {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID]); Issue.record("ACK must require exactly HTTP200")
        } catch LibraryWriteError.malformedResponse { #expect((200 ..< 300).contains(status)) }
        catch let LibraryWriteError.http(actual) { #expect(actual == status && !(200 ..< 300).contains(status)) }
        catch { Issue.record("Unexpected ACK failure: \(error)") }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 1)
    }

    /// Stream同样要求200，不能把201/204或鉴权/服务器错误当作空匹配。
    @Test(arguments: [201, 204, 401, 403, 503])
    func streamStatusFailureCannotReturnCandidates(_ status: Int) async throws {
        let fixture = LocalMetadataHTTPFixture([.ack(), .init(status: status, mime: "application/jsonlines+json", chunks: [Data(metadataHTTPGolden.utf8)])])
        defer { fixture.close() }
        do {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID]); Issue.record("Stream must require exactly HTTP200")
        } catch let LibraryWriteError.http(actual) { #expect(actual == status) }
        catch { Issue.record("Unexpected stream status failure: \(error)") }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 2)
    }

    /// 有效JSONL字节不能掩盖错误/缺失MIME，客户端必须在发布任何候选前拒绝。
    @Test(arguments: ["application/json", "text/plain", "missing"])
    func wrongStreamMimeCannotReturnCandidates(_ mime: String) async throws {
        let fixture = LocalMetadataHTTPFixture([.ack(), .stream(metadataHTTPGolden, mime: mime == "missing" ? nil : mime)])
        defer { fixture.close() }
        await #expect(throws: LocalMediaMetadataStreamError.invalidResponse) {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 2)
    }

    /// 真正URLSession正常EOF/半终止行/传输断开三种截断均不交出已经收到的候选。
    @Test(arguments: ["no-complete", "partial-complete", "disconnect"])
    func truncatedTransportNeverReturnsPartialCandidates(_ mode: String) async throws {
        var text = metadataHTTPFirstRow
        if mode == "partial-complete" {
            text += String(metadataHTTPComplete.dropLast())
        }
        var exchange = MetadataHTTPExchange.stream(text)
        if mode == "disconnect" {
            exchange.error = .networkConnectionLost
        }
        let fixture = LocalMetadataHTTPFixture([.ack(), exchange])
        defer { fixture.close() }
        do {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID]); Issue.record("Truncated HTTP must not return a partial match")
        } catch LocalMediaMetadataStreamError.incomplete { #expect(mode != "disconnect") }
        catch { #expect(mode == "disconnect" && (error as? URLError)?.code == .networkConnectionLost) }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 2)
    }

    /// SyncReset来自实际HTTP流，已有候选也不能返回，更不能追加reset或确认同步的写请求。
    @Test func resetRequiredRemainsFailureWithoutMutatingCheckpoints() async throws {
        let reset = #"{"type":"SyncResetV1","data":{},"ack":"SyncResetV1|reset"}"# + "\n"
        let fixture = LocalMetadataHTTPFixture([.ack(), .stream(metadataHTTPFirstRow + reset)])
        defer { fixture.close() }
        await #expect(throws: LocalMediaMetadataStreamError.resetRequired) {
            _ = try await fixture.client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID])
        }
        try await metadataHTTPAssertSequence(fixture.script.requests, endpoint: fixture.endpoint, count: 2)
    }

    /// 已取消Task在真实request构造前失败，不触发任何网络或会话进度操作。
    @Test func cancelledBeforeEntryCannotSendAck() async {
        let fixture = LocalMetadataHTTPFixture([])
        defer { fixture.close() }
        let client = fixture.client
        let pending = Task { try await client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID]) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(await fixture.script.requests.isEmpty)
    }

    /// 在ACK或已交付候选的stream挂起边界取消；释放迟到字节只用于收尾，不能使原调用得到成功/部分值。
    @Test(arguments: ["ack", "stream"], ["task", "session"])
    func cancellationAtActualHttpGateCannotPublishOrWrite(_ stage: String, _ cancellation: String) async throws {
        var ack = MetadataHTTPExchange.ack()
        var stream = MetadataHTTPExchange.stream(metadataHTTPGolden)
        if stage == "ack" {
            ack.held = true
        } else {
            stream.held = true
        }
        let fixture = LocalMetadataHTTPFixture([ack, stream])
        defer { fixture.close() }
        let client = fixture.client; let script = fixture.script
        let pending = Task { try await client.localMediaMetadata(cloudIDs: [metadataHTTPOpaqueID]) }
        let watcher = Task { _ = await pending.result; await script.operationFinished() }
        guard await script.waitForHeldRequest() else {
            await watcher.value; Issue.record("Real URLSession request did not enter the held response"); return
        }
        if cancellation == "task" {
            pending.cancel()
        } else {
            client.cancel()
        }
        await script.release(); await watcher.value
        do { _ = try await pending.value; Issue.record("Cancelled HTTP must not return candidates") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        try await metadataHTTPAssertSequence(script.requests, endpoint: fixture.endpoint, count: stage == "ack" ? 1 : 2)
    }
}

private nonisolated let metadataHTTPOpaqueID = "opaque:AbC/路径 %2F|completeSuffix"
private nonisolated let metadataHTTPAssetA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let metadataHTTPAssetB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let metadataHTTPComplete = #"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|11111111-1111-4111-8111-111111111111"}"# + "\n"
private nonisolated let metadataHTTPFirstRow = #"{"type":"AssetMetadataV1","data":{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"mobile-app","value":{"iCloudId":"opaque:AbC/路径 %2F|completeSuffix","createdAt":"2020-01-02T03:04:05Z","latitude":"0","longitude":"0"}},"ack":"AssetMetadataV1|22222222-2222-4222-8222-222222222222"}"# + "\n"

/// golden直接对应官方serialize({type,data,ids}) envelope，不调用生产encoder，也不把完整opaque ID截成前缀。
private nonisolated let metadataHTTPGolden = #"""
{"type":"AssetMetadataDeleteV1","data":{"assetId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","key":"mobile-app"},"ack":"AssetMetadataDeleteV1|33333333-3333-4333-8333-333333333333"}
{"type":"AssetMetadataV1","data":{"assetId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","key":"mobile-app","value":{"iCloudId":"opaque:AbC/路径 %2F|completeSuffix-foreign","createdAt":"2020-01-02T03:04:05Z","latitude":"0","longitude":"0"}},"ack":"AssetMetadataV1|44444444-4444-4444-8444-444444444444"}
{"type":"AssetMetadataV1","data":{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"mobile-app","value":{"iCloudId":"opaque:AbC/路径 %2F|completeSuffix","createdAt":"2020-01-02T03:04:05Z","latitude":"0","longitude":"0"}},"ack":"AssetMetadataV1|22222222-2222-4222-8222-222222222222"}
{"type":"AssetMetadataV1","data":{"assetId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","key":"mobile-app","value":{"iCloudId":"opaque:AbC/路径 %2F|completeSuffix","createdAt":"2020-01-02T03:04:05Z","latitude":"0","longitude":"0"}},"ack":"AssetMetadataV1|55555555-5555-4555-8555-555555555555"}
{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|11111111-1111-4111-8111-111111111111"}
"""# + "\n"

/// requests来自实际URLSession；精确序列排除任何reset/query/ACK提交/媒体路径，body独立比较完整JSON。
private nonisolated func metadataHTTPAssertSequence(_ requests: [MetadataHTTPRequest], endpoint: URL, count: Int) throws {
    #expect(requests.count == count)
    for (index, request) in requests.enumerated() {
        let ack = index % 2 == 0
        #expect(request.url.host == endpoint.host && request.url.query == nil)
        #expect(request.url.path == "/prefix/api/sync/" + (ack ? "ack" : "stream"))
        #expect(request.method == (ack ? "GET" : "POST"))
        #expect(request.authorization == "Bearer synthetic-local-read")
        if ack {
            #expect(request.body == nil && request.contentType == nil && request.accept == "application/json")
        } else {
            #expect(request.contentType == "application/json" && request.accept == "application/jsonlines+json")
            let data = try #require(request.body)
            let actual = try JSONSerialization.jsonObject(with: data)
            let expected = try JSONSerialization.jsonObject(with: Data(#"{"types":["AssetMetadataV1"]}"#.utf8))
            #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
        }
    }
}

/// 已发送请求的不可变字节快照；bodyStream在回调线程同步读完后才交给actor。
private nonisolated struct MetadataHTTPRequest: Sendable {
    let url: URL
    let method: String
    let authorization: String?
    let contentType: String?
    let accept: String?
    let body: Data?

    /// request是生产client的原请求，body仅容许有限合成JSON，不修正路径、头或错误请求。
    init(_ request: URLRequest) throws {
        url = try #require(request.url)
        method = try #require(request.httpMethod)
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type"); accept = request.value(forHTTPHeaderField: "Accept")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = data
        } else {
            body = nil
        }
    }
}

/// 一次真实HTTP交付；chunks拆开UTF8/JSON行，error表示流已发部分字节后断开，held只控制明确响应边界。
private nonisolated struct MetadataHTTPExchange: Sendable {
    var status = 200
    var mime: String? = "application/json"
    var chunks: [Data] = []
    var error: URLError.Code?
    var held = false

    /// json为独立GET ack正文；默认没有metadata检查点。
    static func ack(_ json: String = "[]") -> Self {
        .init(chunks: [Data(json.utf8)])
    }

    /// json为完整/故意损坏的JSONL，按17字节拆分，真实URLSession.AsyncBytes自行重组。
    static func stream(_ json: String, mime: String? = "application/jsonlines+json") -> Self {
        let data = Data(json.utf8)
        return .init(mime: mime, chunks: stride(from: 0, to: data.count, by: 17).map { Data(data[$0 ..< min($0 + 17, data.count)]) })
    }
}

/// 每个测试仅在自己的随机.invalid host拦截真实URLSession；不创建全局URLProtocol或真实网络会话。
@MainActor private struct LocalMetadataHTTPFixture {
    let endpoint: URL
    let client: LibraryMutationClient
    let script: LocalMetadataHTTPScript
    /// exchanges是有限实际HTTP脚本，缺项会使URLSession失败而非重放旧响应。
    init(_ exchanges: [MetadataHTTPExchange]) {
        endpoint = URL(string: "https://local-metadata-\(UUID().uuidString.lowercased()).invalid/prefix/api")!
        script = LocalMetadataHTTPScript(exchanges)
        MetadataHTTPProtocol.install(script, host: endpoint.host!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataHTTPProtocol.self]
        client = LibraryMutationClient(apiURL: endpoint, token: "synthetic-local-read", userID: metadataHTTPAssetA, configuration: configuration)
    }

    /// 取消本fixture原URLSession，移除自己的host；不改正常全局网络或任何账号设置。
    func close() {
        client.cancel(); MetadataHTTPProtocol.remove(host: endpoint.host!)
    }
}

/// 记录不可变请求/有限响应及真实hold入口，不把状态或decoder结果预先注入到client。
private actor LocalMetadataHTTPScript {
    private var exchanges: [MetadataHTTPExchange]
    private(set) var requests: [MetadataHTTPRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var finished = false
    /// exchanges逐次消费，缺项必须报错。
    init(_ exchanges: [MetadataHTTPExchange]) {
        self.exchanges = exchanges
    }

    /// 请求真实到达后才记入，未知或额外调用不会落回网络。
    func response(_ request: MetadataHTTPRequest) throws -> MetadataHTTPExchange {
        requests.append(request)
        guard !exchanges.isEmpty else { throw URLError(.badServerResponse) }
        return exchanges.removeFirst()
    }

    /// header/chunks已经交给URLSession后才安装gate，证明取消发生于实际HTTP传输边界。
    func hold() async {
        await withCheckedContinuation { pending = $0; observer?.resume(returning: true); observer = nil }
    }

    /// 原调用若提前结束，观察者返回false报告错误，不能无限等待或冒充到达gate。
    func waitForHeldRequest() async -> Bool {
        if pending != nil {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { observer = $0 }
    }

    /// 真实client操作结束也唤醒失败等待者，不替它造成功值。
    func operationFinished() {
        finished = true; observer?.resume(returning: false); observer = nil
    }

    /// 测试释放迟到传输用于收尾；URLProtocol取消保护仍有权拒绝交付。
    func release() {
        pending?.resume(); pending = nil
    }
}

/// 只拦截本fixture会话；跨线程取消/发送状态用Mutex保护，弱self不延长已取消URLSession生命周期。
private final nonisolated class MetadataHTTPProtocol: URLProtocol, @unchecked Sendable {
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: LocalMetadataHTTPScript]>([:])
    private let loading = Mutex(Loading())
    /// host为唯一随机.invalid身份，不调用全局registerClass。
    static func install(_ script: LocalMetadataHTTPScript, host: String) {
        scripts.withLock { $0[host] = script }
    }

    /// 只移除本测试host。
    static func remove(host: String) {
        _ = scripts.withLock { $0.removeValue(forKey: host) }
    }

    /// 包括错误host也截住，禁止真正连接网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原请求不修正，错误body/path照实交给断言。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 明确Sendable capturedRequest/script沿用已验证fixture模式，真正通过Foundation交付响应和多个字节块。
    override func startLoading() {
        do {
            let capturedRequest = try MetadataHTTPRequest(request)
            let script = try #require(Self.scripts.withLock { $0[capturedRequest.url.host ?? ""] })
            let task = Task { @Sendable [weak self, capturedRequest, script] in
                do {
                    let exchange = try await script.response(capturedRequest)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    let headers = exchange.mime.map { ["Content-Type": $0] } ?? [:]
                    let response = try #require(HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status, httpVersion: nil, headerFields: headers))
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    for chunk in exchange.chunks {
                        guard !Task.isCancelled, !loading.withLock({ $0.stopped }) else { return }
                        client?.urlProtocol(self, didLoad: chunk)
                        await Task.yield()
                    }
                    if exchange.held {
                        await script.hold()
                    }
                    guard !Task.isCancelled, !loading.withLock({ $0.stopped }) else { return }
                    if let error = exchange.error {
                        client?.urlProtocol(self, didFailWithError: URLError(error))
                    } else {
                        client?.urlProtocolDidFinishLoading(self)
                    }
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

    /// 客户端取消必须停止真实后续交付，不能故意忽略stopLoading来测试一个不存在的网络行为。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}
