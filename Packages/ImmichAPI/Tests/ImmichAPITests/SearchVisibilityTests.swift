import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 收藏和归档条件在两种分页模式中语义一致，默认仍限定时间线且不限制收藏。
@Suite("Search visibility contracts")
struct SearchVisibilityTests {
    /// mode选择metadata或旧式smart；逐项验证两个开关独立生效，不能把false写成未收藏限制。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func sendsIndependentFavoriteAndArchiveConditions(_ mode: ImmichMetadataSearch.Mode) async throws {
        for (favorites, archived) in [(false, false), (true, false), (false, true), (true, true)] {
            var query = ImmichMetadataSearch()
            query.mode = mode
            query.text = "synthetic"
            query.favoritesOnly = favorites
            query.archivedOnly = archived
            let transport = VisibilityTransport(mode: mode, favorites: favorites, archived: archived)
            let url = try #require(URL(string: "https://example.invalid/api"))
            let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
            let page = try await client.search(query)
            #expect(page.assets.isEmpty)
            #expect(page.continuation == nil)
        }
    }
}

/// 通过SDK真实编码后的HTTP请求检查条件；只返回合成空页，不连接网络。
private struct VisibilityTransport: ClientTransport {
    let mode: ImmichMetadataSearch.Mode
    let favorites: Bool
    let archived: Bool

    /// request/body为生成SDK输出，mode决定结构；返回完整空响应，所有标志均独立断言。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        let encoded = try #require(body)
        let data = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let visibility = archived ? "archive" : "timeline"
        if mode == .smart {
            #expect(operationID == "searchSmart")
            #expect(request.path == "/search/smart")
            #expect(json["visibility"] as? String == visibility)
            #expect(json["isFavorite"] as? Bool == (favorites ? true : nil))
            #expect(json["filter"] == nil)
        } else {
            #expect(operationID == "searchAssets")
            #expect(request.path == "/search/metadata")
            let filter = try #require(json["filter"] as? [String: Any])
            #expect((filter["visibility"] as? [String: String])?["eq"] == visibility)
            if favorites {
                #expect((filter["isFavorite"] as? [String: Bool])?["eq"] == true)
            } else {
                #expect(filter["isFavorite"] == nil)
            }
        }
        let response = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
