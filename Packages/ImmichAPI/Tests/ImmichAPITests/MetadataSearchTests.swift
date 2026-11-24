import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 使用内存传输验证搜索POST契约，不连接真实图库。
@Suite("Metadata search contract")
struct MetadataSearchTests {
    /// 验证认证、游标、类型与字段组合，防止搜索误经过GET专用队列。
    @Test func sendsAuthenticatedStructuredSearch() async throws {
        var query = ImmichMetadataSearch()
        query.text = " synthetic "
        query.media = .image
        query.city = "Test City"
        query.cameraMake = "Test Make"
        query.cameraModel = "Test Model"
        let transport = ImmichQueuedReadTransport(searchTransport: SearchTransport()) { _, _ in
            Issue.record("Search POST must not enter the URL-only durable queue")
            throw CancellationError()
        }
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")),
                                      credential: .bearer("synthetic-token"), transport: transport)
        let page = try await client.metadataSearch(query, cursor: "opaque-cursor", size: 60)
        #expect(page.assets.isEmpty)
        #expect(page.nextCursor == "next-opaque")
    }

    /// 无凭据与非法页大小须在发送前拒绝。
    @Test func rejectsInvalidSearchBoundary() async throws {
        let url = try #require(URL(string: "https://example.com/api"))
        let anonymous = ImmichClient(apiURL: url, transport: SearchTransport())
        await #expect(throws: ImmichAPIError.unauthorized) { try await anonymous.metadataSearch(.init()) }
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: SearchTransport())
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.metadataSearch(.init(), size: 0) }
    }
}

/// 验证请求并返回完整空页；所有响应只含合成数据。
private struct SearchTransport: ClientTransport {
    /// request/body为SDK输出，baseURL和operationID确定公开路由；返回合成HTTP200 JSON。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "searchAssets")
        #expect(request.method == .post)
        #expect(request.path == "/search/metadata")
        #expect(request.headerFields[.authorization] == "Bearer synthetic-token")
        let data = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["cursor"] as? String == "opaque-cursor")
        #expect(json["page"] == nil)
        let filter = try #require(json["filter"] as? [String: Any])
        #expect((filter["originalFileName"] as? [String: String])?["like"] == "synthetic")
        #expect((filter["type"] as? [String: String])?["eq"] == "IMAGE")
        #expect((filter["city"] as? [String: String])?["eq"] == "Test City")
        #expect((filter["make"] as? [String: String])?["eq"] == "Test Make")
        #expect((filter["model"] as? [String: String])?["eq"] == "Test Model")
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":"next-opaque"}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
