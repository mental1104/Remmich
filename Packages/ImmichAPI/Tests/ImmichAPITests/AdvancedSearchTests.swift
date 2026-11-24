import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 合成请求验证EXIF组合，不读取真实照片或依赖生产元数据。
@Suite("Advanced search filters")
struct AdvancedSearchTests {
    /// 上下界共存并保留其他筛选；快门以秒发送，方向和未入簿明确编码。
    @Test func preservesNumericRangesAndOtherFilters() async throws {
        var query = ImmichMetadataSearch()
        query.city = "Synthetic City"
        query.media = .image
        query.orientation = .landscape
        query.hasAlbums = false
        query.exifConditions = [
            .init(field: .iso, comparison: .atLeast, value: 400),
            .init(field: .iso, comparison: .lessThan, value: 1600),
            .init(field: .fNumber, comparison: .atMost, value: 2.8),
            .init(field: .focalLength, comparison: .equal, value: 50),
            .init(field: .exposureTime, comparison: .atMost, value: 0.008),
        ]
        let client = try makeClient()
        #expect(try await client.search(query).assets.isEmpty)
    }

    /// value为非法数值，必须在编码/发送前拒绝，不用忽略条件换取成功。
    @Test(arguments: [Double.nan, .infinity, -1])
    func rejectsNonFiniteAndNegativeValues(_ value: Double) async throws {
        var query = ImmichMetadataSearch()
        query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: value)]
        let client = try makeClient()
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
    }

    /// 重复槽位在metadata和高级smart均须发送前拒绝，不能覆盖条件。
    @Test func rejectsDuplicateSlotsInEverySearchMode() async throws {
        var query = ImmichMetadataSearch()
        query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400),
                                .init(field: .iso, comparison: .atLeast, value: 800)]
        let client = try makeClient()
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
        query.mode = .smart
        query.text = "synthetic"
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
    }

    /// 返回只能读取合成响应的SDK实例，任何错误的请求字段都会产生测试断言。
    private func makeClient() throws -> ImmichClient {
        try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("synthetic"),
                         transport: AdvancedSearchTransport())
    }
}

/// 接收结构化metadata请求并返回空页，核对字段映射与数值单位。
private struct AdvancedSearchTransport: ClientTransport {
    /// request/body是SDK输出，baseURL用于契约签名；返回纯合成HTTP200。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "searchAssets")
        #expect(request.method == .post)
        let data = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filter = try #require(json["filter"] as? [String: Any])
        #expect((filter["iso"] as? [String: Double]) == ["gte": 400, "lt": 1600])
        #expect((filter["fNumber"] as? [String: Double]) == ["lte": 2.8])
        #expect((filter["focalLength"] as? [String: Double]) == ["eq": 50])
        #expect((filter["exposureTime"] as? [String: Double]) == ["lte": 0.008])
        #expect((filter["orientation"] as? [String: String]) == ["eq": "landscape"])
        #expect((filter["hasAlbums"] as? [String: Bool]) == ["eq": false])
        #expect((filter["city"] as? [String: String]) == ["eq": "Synthetic City"])
        #expect((filter["type"] as? [String: String]) == ["eq": "IMAGE"])
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
