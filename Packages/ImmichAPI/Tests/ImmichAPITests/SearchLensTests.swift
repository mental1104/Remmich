import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 镜头条件在metadata游标与smart页码两条官方路径均须保留，续页不能漏传。
@Suite("Search lens contracts")
struct SearchLensTests {
    /// mode选择分页协议；每次SDK实际请求均检查镜头字段，不以首屏成功代替续页验证。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func preservesLensAcrossPages(_ mode: ImmichMetadataSearch.Mode) async throws {
        var query = ImmichMetadataSearch()
        query.text = "synthetic"
        query.mode = mode
        query.lensModel = "Synthetic Lens"
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: LensTransport(mode: mode))
        let first = try await client.search(query)
        let token = try #require(first.continuation)
        #expect(token == (mode == .smart ? .page(2) : .cursor("next")))
        let last = try await client.search(query, continuation: token)
        #expect(last.continuation == nil)
    }
}

/// 根据请求的原始页码/游标返回两页合成数据，不持久化请求或接触网络。
private struct LensTransport: ClientTransport {
    let mode: ImmichMetadataSearch.Mode

    /// request/body是SDK输出；mode决定镜头字段的位置与实际分页协议，返回相应终态令牌。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        let encoded = try #require(body)
        let data = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nextPage: String
        let nextCursor: String
        if mode == .smart {
            #expect(operationID == "searchSmart")
            #expect(json["lensModel"] as? String == "Synthetic Lens")
            #expect(json["filter"] == nil)
            let page = try #require(json["page"] as? Int)
            #expect(page == 1 || page == 2)
            nextPage = page == 1 ? "\"2\"" : "null"
            nextCursor = "null"
        } else {
            #expect(operationID == "searchAssets")
            let filter = try #require(json["filter"] as? [String: Any])
            #expect((filter["lensModel"] as? [String: String])?["eq"] == "Synthetic Lens")
            #expect(json["page"] == nil)
            if let cursor = json["cursor"] as? String {
                #expect(cursor == "next")
            }
            nextPage = "null"
            nextCursor = json["cursor"] == nil ? "\"next\"" : "null"
        }
        let response = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":\(nextPage),\"nextCursor\":\(nextCursor)}}"
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
