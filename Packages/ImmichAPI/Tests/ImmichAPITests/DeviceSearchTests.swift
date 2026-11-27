import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 验证设备别名OR组的实际请求字节，保持metadata/Fork分页和单相机条件互不覆盖。
@Suite("Capture device search contracts")
struct DeviceSearchTests {
    /// mode区分官方metadata与独立Fork智能路由；两页都必须保留原始别名及其他筛选。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func preservesDeviceGroupsAcrossPages(_ mode: ImmichMetadataSearch.Mode) async throws {
        var query = ImmichMetadataSearch()
        query.mode = mode
        query.text = "synthetic"
        query.deviceModels = ["DJI OsmoPocket3", "PP-101"]
        query.cameraModel = "PP-101"
        query.cameraMake = "Synthetic Make"
        query.lensModel = "Synthetic Lens"
        query.media = .video
        query.favoritesOnly = true
        let transport = ImmichQueuedReadTransport(searchTransport: DeviceSearchTransport(smart: mode == .smart)) { _, _ in
            Issue.record("Device search must not enter the durable GET queue")
            throw CancellationError()
        }
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.invalid/immich/api")),
                                      credential: .bearer("synthetic"), transport: transport)
        let first = try await client.search(query)
        #expect(first.continuation == (mode == .smart ? .cursor("device-next") : .cursor("device-next")))
        let last = try await client.search(query, continuation: first.continuation)
        #expect(last.continuation == nil)
    }

    /// 非法型号组不能发往网络；metadata与smart均须拒绝，不能删除错误条件后搜索。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func rejectsInvalidDeviceGroupsBeforeSend(_ mode: ImmichMetadataSearch.Mode) async throws {
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.invalid/api")),
                                      credential: .bearer("synthetic"), transport: DeviceNeverSendTransport())
        for models in [[""], [" \n"], [String(repeating: "x", count: 257)], Array(repeating: "Synthetic", count: 51)] {
            var query = ImmichMetadataSearch()
            query.mode = mode
            query.text = "synthetic"
            query.deviceModels = models
            await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        }
    }

    /// 清除设备组后不再发送in；独立单型号仍保留，没有任何型号时整个model键省略。
    @Test(arguments: ["", "Synthetic Model"])
    func clearsOnlyDeviceGroup(_ singleModel: String) async throws {
        var query = ImmichMetadataSearch()
        query.cameraModel = singleModel
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.invalid/api")),
                                      credential: .bearer("synthetic"), transport: ClearedDeviceTransport(singleModel: singleModel))
        _ = try await client.search(query)
    }

    /// 从账号建议读取完整设备列表时不得带当前相机make/model约束；空组不要求Fork智能扩展。
    @Test func loadsUnconstrainedAccountModels() async throws {
        let transport = ImmichQueuedReadTransport { request, operation in
            #expect(operation == "getSearchSuggestions")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
            let url = try #require(request.url)
            #expect(url.path == "/immich/api/search/suggestions")
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = try #require(components.queryItems)
            #expect(items.contains { $0.name == "type" && $0.value == "camera-model" })
            #expect(!items.contains { $0.name == "make" || $0.name == "model" })
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "application/json"]))
            return (Data(#"["PP-101","DJI OsmoPocket3"]"#.utf8), response)
        }
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.invalid/immich/api")),
                                      credential: .bearer("synthetic"), transport: transport)
        #expect(try await client.searchSuggestions(kind: .cameraModel) == ["PP-101", "DJI OsmoPocket3"])
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        #expect(!query.requiresForkSmartSearch)
        query.deviceModels = ["PP-101"]
        #expect(query.requiresForkSmartSearch)
        query.text = ""
        #expect(!query.requiresForkSmartSearch)
    }
}

/// 清除组的合成metadata响应器；singleModel是唯一允许保留的型号条件。
private struct ClearedDeviceTransport: ClientTransport {
    let singleModel: String

    /// request/body为SDK输出；断言model.in省略，并返回不带资源的明确终页。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.path == "/search/metadata" && operationID == "searchAssets")
        let data = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filter = try #require(json["filter"] as? [String: Any])
        if singleModel.isEmpty {
            #expect(filter["model"] == nil)
        } else {
            #expect(filter["model"] as? [String: String] == ["eq": singleModel])
        }
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}

/// 接收两页合成设备查询；smart指定唯一允许路由，响应仅包含空资源和不透明游标。
private struct DeviceSearchTransport: ClientTransport {
    let smart: Bool

    /// request/body为SDK实际输出；baseURL保留部署前缀，返回首屏游标或明确终页。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        #expect(request.path == (smart ? "/search/smart" : "/search/metadata"))
        #expect(operationID == (smart ? "searchSmart" : "searchAssets"))
        #expect(baseURL.absoluteString == "https://example.invalid/immich/api")
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        let data = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["deviceModels"] == nil && json["page"] == nil)
        let filter = try #require(json["filter"] as? [String: Any])
        let model = try #require(filter["model"] as? [String: Any])
        #expect(model["in"] as? [String] == ["DJI OsmoPocket3", "PP-101"])
        #expect(model["eq"] as? String == "PP-101")
        #expect((filter["make"] as? [String: String])?["eq"] == "Synthetic Make")
        #expect((filter["lensModel"] as? [String: String])?["eq"] == "Synthetic Lens")
        #expect((filter["type"] as? [String: String])?["eq"] == "VIDEO")
        #expect((filter["isFavorite"] as? [String: Bool])?["eq"] == true)
        #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
        if smart {
            #expect(json["query"] as? String == "synthetic")
        } else {
            #expect((filter["originalFileName"] as? [String: String])?["like"] == "synthetic")
        }
        let cursor = json["cursor"] as? String
        if let cursor {
            #expect(cursor == "device-next")
        }
        let next = cursor == nil ? "\"device-next\"" : "null"
        let response = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":null,\"nextCursor\":\(next)}}"
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}

/// 非法型号组的网络哨兵，任何发送都记录失败，绝不访问服务器。
private struct DeviceNeverSendTransport: ClientTransport {
    /// 所有输入都不应抵达传输层；记录失败后抛取消，避免产生网络副作用。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Invalid device filter must not reach transport")
        throw CancellationError()
    }
}
