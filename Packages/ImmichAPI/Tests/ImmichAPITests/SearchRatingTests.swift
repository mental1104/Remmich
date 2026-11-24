import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 对生成SDK实际请求断言评分三态，不能用“未评分查询成功”掩盖null被丢弃。
@Suite("Search rating contracts")
struct SearchRatingTests {
    /// rating覆盖缺省、null、0和边界具体值；metadata请求必须准确表达每个选择。
    @Test(arguments: [ImmichSearchRating.any, .unrated, .stars(0), .stars(1), .stars(5)])
    func metadataKeepsRatingMeaning(_ rating: ImmichSearchRating) async throws {
        var query = ImmichMetadataSearch()
        query.text = "synthetic"
        query.rating = rating
        let api = try client(rating: rating)
        _ = try await api.search(query)
    }

    /// 旧式smart的缺省/null/1–5直接使用现有平铺字段；不更换分页协议。
    @Test(arguments: [ImmichSearchRating.any, .unrated, .stars(1), .stars(5)])
    func smartKeepsSupportedRating(_ rating: ImmichSearchRating) async throws {
        var query = ImmichMetadataSearch()
        query.text = "synthetic"
        query.mode = .smart
        query.rating = rating
        _ = try await client(rating: rating, smart: true).search(query)
    }

    /// 0不在旧式smart评分范围内，越界值也须在网络之前拒绝。
    @Test func rejectsUnsupportedOrInvalidRatingsBeforeSending() async throws {
        let url = try #require(URL(string: "https://example.invalid/api"))
        let transport = UnexpectedRatingTransport()
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        for (mode, rating) in [(ImmichMetadataSearch.Mode.smart, ImmichSearchRating.stars(0)), (.fileName, .stars(-1)), (.fileName, .stars(6))] {
            var query = ImmichMetadataSearch()
            query.text = "synthetic"
            query.mode = mode
            query.rating = rating
            await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        }
    }

    /// 自定义替换类型必须保留官方全部运算符；不仅检验本次用到的eq。
    @Test func nullableFilterPreservesEveryOperator() throws {
        let filter = ImmichNullableNumberFilter(eq: .null, gt: 0, gte: 1, inValues: [0, 3], lt: 6, lte: 5, ne: .number(0), notIn: [2, 4])
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(ImmichNullableNumberFilter.self, from: data) == filter)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["eq"] is NSNull)
        #expect(object["in"] as? [Double] == [0, 3])
        #expect(object["ne"] as? Double == 0)
        let absent = try JSONDecoder().decode(ImmichNullableNumberFilter.self, from: Data("{}".utf8))
        #expect(absent.eq == .missing && absent.ne == .missing)
        let emptyData = try JSONEncoder().encode(absent)
        let emptyObject = try #require(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        #expect(emptyObject.isEmpty)
    }

    /// rating指定预期值、smart选择官方分页模式；返回纯内存传输客户端。
    private func client(rating: ImmichSearchRating, smart: Bool = false) throws -> ImmichClient {
        try ImmichClient(apiURL: #require(URL(string: "https://example.invalid/api")), credential: .bearer("synthetic"),
                         transport: RatingTransport(rating: rating, smart: smart))
    }
}

/// 非法评分用例的失败哨兵；任何发送均失败，测试不会误连真实网络。
private struct UnexpectedRatingTransport: ClientTransport {
    /// 所有参数均代表不应发出的请求；记录失败并抛取消，由用例断言预期错误不匹配。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Invalid rating must not reach transport")
        throw CancellationError()
    }
}

/// 比较请求的实际JSON，不绕开SDK编码器；返回合成终页。
private struct RatingTransport: ClientTransport {
    let rating: ImmichSearchRating
    let smart: Bool

    /// request/body来自SDK，smart决定平铺/结构化评分；返回不含私人资源的空页。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        let encoded = try #require(body)
        let data = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if smart {
            #expect(operationID == "searchSmart")
            switch rating {
            case .any: #expect(json["rating"] == nil)
            case .unrated: #expect(json["rating"] is NSNull)
            case let .stars(value): #expect(json["rating"] as? Int == value)
            }
            #expect(json["page"] as? Int == 1)
        } else {
            #expect(operationID == "searchAssets")
            let filter = try #require(json["filter"] as? [String: Any])
            switch rating {
            case .any: #expect(filter["rating"] == nil)
            case .unrated:
                let condition = try #require(filter["rating"] as? [String: Any])
                #expect(condition["eq"] is NSNull)
            case let .stars(value):
                let condition = try #require(filter["rating"] as? [String: Double])
                #expect(condition["eq"] == Double(value))
            }
        }
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
