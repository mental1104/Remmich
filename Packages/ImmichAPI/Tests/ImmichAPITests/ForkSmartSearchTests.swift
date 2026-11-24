import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 检查独立Fork读取的真实字节、三种分页隔离及错误/取消，不连接照片服务器。
@Suite("Fork smart search contracts")
struct ForkSmartSearchTests {
    /// rating覆盖省略/null/0/5；全部基础及高级条件在首屏和下一页均须完整保留。
    @Test(arguments: [ImmichSearchRating.any, .unrated, .stars(0), .stars(5)])
    func preservesCompleteFiltersAndMapsAssets(_ rating: ImmichSearchRating) async throws {
        let query = try forkQuery(rating: rating)
        let url = try #require(URL(string: "https://example.invalid/immich/api"))
        let transport = ImmichQueuedReadTransport(searchTransport: ForkWireTransport(rating: rating)) { _, _ in
            Issue.record("Fork search POST must not enter the durable GET queue")
            throw CancellationError()
        }
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let first = try await client.search(query)
        #expect(first.assets.map(\.id) == ["first"])
        #expect(first.continuation == .forkCursor("fork-next"))
        let last = try await client.search(query, continuation: first.continuation)
        #expect(last.assets.map(\.id) == ["last"])
        #expect(last.continuation == nil)
    }

    /// rating覆盖参考图组合的评分三态；两页都只发送queryAssetId并完整保留原有过滤。
    @Test(arguments: [ImmichSearchRating.any, .unrated, .stars(0), .stars(5)])
    func preservesReferenceAndCompleteFilters(_ rating: ImmichSearchRating) async throws {
        var query = try forkQuery(rating: rating)
        query.text = ""
        query.queryAssetID = "22222222-2222-4222-8222-222222222222"
        let url = try #require(URL(string: "https://example.invalid/immich/api"))
        let transport = ImmichQueuedReadTransport(searchTransport: ForkWireTransport(rating: rating, referenceID: query.queryAssetID)) { _, _ in
            Issue.record("Reference search POST must not enter the durable GET queue")
            throw CancellationError()
        }
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let first = try await client.search(query)
        #expect(first.assets.map(\.id) == ["first"])
        #expect(first.continuation == .forkCursor("fork-next"))
        let last = try await client.search(query, continuation: first.continuation)
        #expect(last.assets.map(\.id) == ["last"])
        #expect(last.continuation == nil)
    }

    /// 没有其他高级筛选时仍走Fork；服务器参考图读取失败不能退回官方smart或metadata。
    @Test(arguments: [404, 405, 501, 401, 403, 400])
    func routesReferenceAloneWithoutFallback(_ status: Int) async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.queryAssetID = "22222222-2222-4222-8222-222222222222"
        #expect(query.requiresForkSmartSearch)
        let transport = ForkStatusTransport(status: status)
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        await #expect(throws: ImmichClient.map(status: status)) { try await client.search(query) }
        #expect(await transport.calls == 1)
    }

    /// reference为非法UUID、版本或variant；不能向网络发送，也不能通过metadata忽略参考图。
    @Test(arguments: ["", "not-an-asset", "00000000-0000-0000-0000-000000000000",
                      "22222222-2222-5222-8222-222222222222", "22222222-2222-4222-7222-222222222222"])
    func rejectsInvalidReferencesBeforeSending(_ reference: String) async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.queryAssetID = reference
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: ForkNeverSendTransport())
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.metadataSearch(query) }
    }

    /// 参考图与文字/非smart模式冲突时整组拒绝；参考图分页也不能借用其他协议令牌。
    @Test func rejectsMixedReferenceSourcesAndContinuations() async throws {
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: ForkNeverSendTransport())
        var query = ImmichMetadataSearch()
        query.queryAssetID = "22222222-2222-4222-8222-222222222222"
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        query.mode = .smart
        query.text = "synthetic"
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        query.text = ""
        for token in [ImmichSearchContinuation.cursor("metadata"), .page(2)] {
            await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query, continuation: token) }
        }
    }

    /// condition单独选择旧smart不能表达的条件，不能只有多个高级条件同时存在才使用Fork。
    @Test(arguments: ["iso", "orientation", "albums", "zero"])
    func routesEachAdvancedCondition(_ condition: String) async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        switch condition {
        case "iso": query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400)]
        case "orientation": query.orientation = .portrait
        case "albums": query.hasAlbums = true
        default: query.rating = .stars(0)
        }
        let transport = ForkStatusTransport(status: 404)
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        await #expect(throws: ImmichAPIError.notFound) { try await client.search(query) }
        #expect(await transport.calls == 1)
    }

    /// usesReference选择文字/参考图请求；取消后即使传输器返回正常响应，也不能发布成功。
    @Test(arguments: [false, true])
    func rejectsLateResponseAfterCancellation(_ usesReference: Bool) async throws {
        let transport = ForkDelayedTransport()
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        var query = try forkQuery()
        if usesReference {
            query.text = ""
            query.queryAssetID = "22222222-2222-4222-8222-222222222222"
        }
        let task = Task { try await client.search(query) }
        await transport.waitForRequest()
        task.cancel()
        await transport.complete()
        await #expect(throws: ImmichAPIError.cancelled) { try await task.value }
    }

    /// 旧协议令牌不能进入Fork；Fork令牌也不能进入普通metadata/旧smart，拒绝发生在网络前。
    @Test func rejectsMixedContinuationKinds() async throws {
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: ForkNeverSendTransport())
        let query = try forkQuery()
        for token in [ImmichSearchContinuation.cursor("metadata"), .page(2), .forkCursor("")] {
            await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query, continuation: token) }
        }
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(.init(), continuation: .forkCursor("fork-next")) }
        var plain = ImmichMetadataSearch()
        plain.mode = .smart
        plain.text = "synthetic"
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(plain, continuation: .forkCursor("fork-next")) }
    }

    /// status为缺路由/权限/条件/限速/服务器/重定向状态；只发一次，不删条件回退或自动重放。
    @Test(arguments: [404, 405, 501, 401, 403, 400, 429, 500, 302])
    func preservesStatusesWithoutFallback(_ status: Int) async throws {
        let transport = ForkStatusTransport(status: status)
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let query = try forkQuery()
        await #expect(throws: ImmichClient.map(status: status)) { try await client.search(query) }
        #expect(await transport.calls == 1)
    }

    /// 非法响应不能变成成功空页，特别是混合页码或反复相同游标。
    @Test(arguments: ["page", "empty", "repeated", "malformed"])
    func rejectsInvalidResponse(_ shape: String) async throws {
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: ForkInvalidTransport(shape: shape))
        let query = try forkQuery()
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query, continuation: .forkCursor("same")) }
    }

    /// Fork身份必须绑定只读POST路径；操作ID不能授权任意其他路径或方法。
    @Test func bindsPolicyToTheExactForkReadRoute() throws {
        let good = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/fork/search/smart")
        #expect(throws: Never.self) { try ReadOnlyOperationPolicy.validate(request: good, operationID: "forkSearchSmart") }
        for request in [HTTPRequest(method: .delete, scheme: nil, authority: nil, path: "/fork/search/smart"),
                        HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/assets")]
        {
            #expect(throws: ImmichAPIError.readOnlyPolicyViolation(operationID: "forkSearchSmart")) {
                try ReadOnlyOperationPolicy.validate(request: request, operationID: "forkSearchSmart")
            }
        }
    }
}

/// rating为待验证评分三态，返回包含各层筛选的合成高级查询；日期固定UTC日，不读取账号数据。
private func forkQuery(rating: ImmichSearchRating = .stars(0)) throws -> ImmichMetadataSearch {
    var query = ImmichMetadataSearch()
    query.mode = .smart
    query.text = " synthetic "
    query.country = "Synthetic Country"
    query.state = "Synthetic State"
    query.city = "Synthetic City"
    query.cameraMake = "Synthetic Make"
    query.cameraModel = "Synthetic Model"
    query.lensModel = "Synthetic Lens"
    query.media = .image
    query.favoritesOnly = true
    query.rating = rating
    query.personIDs = ["11111111-1111-4111-8111-111111111111"]
    query.orientation = .landscape
    query.hasAlbums = false
    query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400),
                            .init(field: .exposureTime, comparison: .atMost, value: 0.008)]
    query.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    query.takenAfter = Date(timeIntervalSince1970: 0)
    query.takenBefore = Date(timeIntervalSince1970: 0)
    return query
}

/// 断言完整请求，返回带真实AssetResponseDto形状的两页合成记录。
private struct ForkWireTransport: ClientTransport {
    let rating: ImmichSearchRating
    var referenceID: String?

    /// request/body是包装器输出；baseURL必须保留API前缀，operationID是唯一Fork只读身份。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "forkSearchSmart" && request.method == .post && request.path == "/fork/search/smart")
        #expect(baseURL.absoluteString == "https://example.invalid/immich/api")
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        #expect(request.headerFields[.cacheControl] == "no-store")
        let encoded = try #require(body)
        let data = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let referenceID {
            #expect(json["queryAssetId"] as? String == referenceID)
            #expect(json["query"] == nil)
        } else {
            #expect(json["query"] as? String == "synthetic")
            #expect(json["queryAssetId"] == nil)
        }
        #expect(json["page"] == nil && json["orderBy"] == nil && json["rating"] == nil)
        #expect(json["size"] as? Int == 60 && json["withExif"] as? Bool == true)
        let filter = try #require(json["filter"] as? [String: Any])
        for (field, value) in ["city": "Synthetic City", "country": "Synthetic Country", "state": "Synthetic State",
                               "make": "Synthetic Make", "model": "Synthetic Model", "lensModel": "Synthetic Lens",
                               "visibility": "timeline", "type": "IMAGE", "orientation": "landscape"]
        {
            #expect((filter[field] as? [String: String])?["eq"] == value)
        }
        #expect((filter["isFavorite"] as? [String: Bool])?["eq"] == true)
        #expect((filter["hasAlbums"] as? [String: Bool])?["eq"] == false)
        #expect((filter["personIds"] as? [String: [String]])?["any"] == ["11111111-1111-4111-8111-111111111111"])
        #expect((filter["iso"] as? [String: Double])?["gte"] == 400)
        #expect((filter["exposureTime"] as? [String: Double])?["lte"] == 0.008)
        #expect((filter["takenAt"] as? [String: String]) == ["gte": "1970-01-01T00:00:00.000Z", "lte": "1970-01-01T23:59:59.999Z"])
        #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
        switch rating {
        case .any: #expect(filter["rating"] == nil)
        case .unrated: #expect((filter["rating"] as? [String: Any])?["eq"] is NSNull)
        case let .stars(value): #expect((filter["rating"] as? [String: Double])?["eq"] == Double(value))
        }
        let cursor = json["cursor"] as? String
        if let cursor {
            #expect(cursor == "fork-next")
        }
        return (HTTPResponse(status: .ok), HTTPBody(forkResponse(id: cursor == nil ? "first" : "last", next: cursor == nil ? "fork-next" : nil)))
    }
}

/// id为纯合成身份，next为不透明续页令牌；返回完整官方搜索响应，无真实文件内容。
private func forkResponse(id: String, next: String?) -> String {
    let asset = #"{"id":"\#(id)","originalPath":"/synthetic/\#(id).jpg","checksum":"synthetic","createdAt":"2026-11-01T00:00:00Z","fileCreatedAt":"2026-11-01T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":true,"isOffline":false,"isTrashed":false,"localDateTime":"2026-11-01T00:00:00Z","originalFileName":"synthetic.jpg","ownerId":"synthetic","type":"IMAGE","updatedAt":"2026-11-01T00:00:00Z","visibility":"timeline"}"#
    let cursor = next.map { "\"\($0)\"" } ?? "null"
    return "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":1,\"count\":1,\"items\":[\(asset)],\"facets\":[],\"nextPage\":null,\"nextCursor\":\(cursor)}}"
}

/// 非法请求的失败哨兵；任何实际发送都意味着协议隔离失效。
private struct ForkNeverSendTransport: ClientTransport {
    /// 所有参数均不应进入网络；记录失败并抛取消，不访问服务器。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Invalid continuation must not reach transport")
        throw CancellationError()
    }
}

/// 记录调用次数验证缺路由/失败不会回退或重放；状态为合成HTTP输入。
private actor ForkStatusTransport: ClientTransport {
    let status: Int
    private(set) var calls = 0

    /// status为本次所有响应状态；调用计数仅用于只读重放断言。
    init(status: Int) {
        self.status = status
    }

    /// 只允许实际Fork操作，返回所选错误状态，不读取凭据或请求内容。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        calls += 1
        #expect(operationID == "forkSearchSmart")
        return (HTTPResponse(status: .init(code: status)), HTTPBody("{}"))
    }
}

/// shape选择混合令牌、空/重复游标或非JSON响应，验证失败不会伪装终页。
private struct ForkInvalidTransport: ClientTransport {
    let shape: String

    /// 请求参数不触发网络；始终返回合成200加坏响应内容。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        if shape == "malformed" {
            return (HTTPResponse(status: .ok), HTTPBody("invalid"))
        }
        let page = shape == "page" ? "\"2\"" : "null"
        let cursor = shape == "empty" ? "\"\"" : "\"same\""
        let response = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":\(page),\"nextCursor\":\(cursor)}}"
        return (HTTPResponse(status: .ok), HTTPBody(response))
    }
}

/// 故意忽略取消的读取替身，用显式握手控制响应时机，不执行网络。
private actor ForkDelayedTransport: ClientTransport {
    private var response: CheckedContinuation<(HTTPResponse, HTTPBody?), Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// 参数均为合成只读请求；保存响应continuation直到测试显式释放。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        await withCheckedContinuation { continuation in
            response = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// 等待实际请求进入，避免测试先取消而根本未覆盖在途响应。
    func waitForRequest() async {
        if response != nil {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 返回有效合成媒体页，故意不检查Task取消，以验证客户端发布边界。
    func complete() {
        response?.resume(returning: (HTTPResponse(status: .ok), HTTPBody(forkResponse(id: "late", next: nil))))
        response = nil
    }
}
