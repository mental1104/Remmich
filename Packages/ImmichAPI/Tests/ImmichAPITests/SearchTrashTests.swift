import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 检查默认搜索/视频排除回收站，并验证日期类型替换没有破坏官方日期编码。
@Suite("Search trash contracts")
struct SearchTrashTests {
    /// 视频列表沿用原游标，生成请求必须明确包含trashedAt.eq:null。
    @Test func videosExcludeTrashedAssets() async throws {
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: TrashTransport(expectation: .video))
        let page = try await client.videoAssets(cursor: "opaque")
        #expect(page.assets.isEmpty)
        #expect(page.nextCursor == nil)
    }

    /// 通过真实生成SDK检查所有日期操作仍使用ISO8601，而不是Date默认的数值编码。
    @Test func generatedSDKPreservesNullableDateOperators() async throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = Client(serverURL: url, transport: TrashTransport(expectation: .dates))
        _ = try await client.searchAssets(.init(body: .json(.init(filter: .init(trashedAt: .init(
            eq: .date(epoch), gt: epoch.addingTimeInterval(-60), gte: epoch,
            lt: epoch.addingTimeInterval(120), lte: epoch.addingTimeInterval(60), ne: .null
        )), size: 1))))
    }

    /// 缺省/null/日期和六个官方运算符完整往返，不因为本次只用eq:null删掉其他能力。
    @Test func dateFilterRetainsNullAbsentAndAllOperators() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let filter = ImmichNullableDateFilter(eq: .null, gt: epoch, gte: epoch, lt: epoch, lte: epoch, ne: .date(epoch))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(filter)
        #expect(try decoder.decode(ImmichNullableDateFilter.self, from: data) == filter)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["eq"] is NSNull)
        #expect(Set(object.keys) == Set(["eq", "ne", "gt", "gte", "lt", "lte"]))
        let absent = try decoder.decode(ImmichNullableDateFilter.self, from: Data("{}".utf8))
        #expect(absent.eq == .missing && absent.ne == .missing)
        let emptyData = try encoder.encode(absent)
        let empty = try #require(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        #expect(empty.isEmpty)
    }
}

/// 从最终HTTP字节断言过滤条件，返回合成终页，不连接实际服务或照片。
private struct TrashTransport: ClientTransport {
    /// 选择默认视频范围或日期操作契约，测试传输器只执行一个明确分支。
    enum Expectation: Sendable { case video, dates }
    let expectation: Expectation

    /// request/body为SDK编码结果，expectation选择默认视频或全部日期操作；返回完整空页。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "searchAssets" && request.method == .post)
        let encoded = try #require(body)
        let data = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filter = try #require(json["filter"] as? [String: Any])
        let trash = try #require(filter["trashedAt"] as? [String: Any])
        switch expectation {
        case .video:
            #expect(trash["eq"] is NSNull)
            #expect((filter["type"] as? [String: String])?["eq"] == "VIDEO")
            #expect(json["cursor"] as? String == "opaque")
        case .dates:
            #expect(trash["eq"] as? String == "1970-01-01T00:00:00.000Z")
            #expect(trash["ne"] is NSNull)
            #expect(trash["gt"] as? String == "1969-12-31T23:59:00.000Z")
            #expect(trash["gte"] as? String == "1970-01-01T00:00:00.000Z")
            #expect(trash["lt"] as? String == "1970-01-01T00:02:00.000Z")
            #expect(trash["lte"] as? String == "1970-01-01T00:01:00.000Z")
        }
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
