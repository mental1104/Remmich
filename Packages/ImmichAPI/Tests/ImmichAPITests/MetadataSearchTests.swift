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
        query.personIDs = ["11111111-1111-4111-8111-111111111111"]
        query.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        query.takenAfter = Date(timeIntervalSince1970: 0)
        query.takenBefore = Date(timeIntervalSince1970: 0)
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
        var invalid = ImmichMetadataSearch()
        invalid.personIDs = ["not-a-uuid"]
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.metadataSearch(invalid) }
        invalid = .init()
        invalid.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        invalid.takenAfter = Date(timeIntervalSince1970: 86400)
        invalid.takenBefore = Date(timeIntervalSince1970: 0)
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.metadataSearch(invalid) }
    }

    /// 夏令时当日仍编码为本地墙上日期，不把23小时的绝对日长带到服务器比较中。
    @Test func dateBoundariesPreserveLocalCalendarDayAcrossDST() throws {
        var query = ImmichMetadataSearch()
        query.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let selected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T15:00:00Z"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T00:00:00Z"))
        #expect(try query.captureBoundary(selected, endOfDay: false) == expected)
        #expect(try query.captureBoundary(selected, endOfDay: true) == expected.addingTimeInterval(86400 - 0.001))
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
        #expect((filter["personIds"] as? [String: [String]])?["any"] == ["11111111-1111-4111-8111-111111111111"])
        let taken = try #require(filter["takenAt"] as? [String: String])
        #expect(taken["gte"] == "1970-01-01T00:00:00.000Z")
        #expect(taken["lte"] == "1970-01-01T23:59:59.999Z")
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":"next-opaque"}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
