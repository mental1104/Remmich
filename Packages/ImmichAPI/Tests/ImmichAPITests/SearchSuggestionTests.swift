import Foundation
import Testing
@testable import ImmichAPI

/// 账号内搜索候选走官方GET，不向公共坐标服务发送照片位置。
@Suite("Search suggestions")
struct SearchSuggestionTests {
    /// kind为可选字段；只有型号候选带厂商，鉴权与API根路径必须保留。
    @Test(arguments: [ImmichSearchSuggestionKind.city, .cameraMake, .cameraModel])
    func readsAccountScopedChoices(_ kind: ImmichSearchSuggestionKind) async throws {
        let transport = ImmichQueuedReadTransport { request, operation in
            #expect(operation == "getSearchSuggestions")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/immich/api/search/suggestions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = try #require(components.queryItems)
            #expect(items.contains { $0.name == "type" && $0.value == kind.rawValue })
            #expect(items.contains { $0.name == "includeNull" && $0.value == "false" })
            #expect(items.contains { $0.name == "make" } == (kind == .cameraModel))
            if kind == .cameraModel {
                #expect(items.contains { $0.name == "make" && $0.value == "Synthetic Make" })
            }
            let body = Data(#"["Synthetic A","Synthetic B"]"#.utf8)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                                                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (body, response)
        }
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/immich/api")),
                                      credential: .bearer("synthetic"), transport: transport)
        #expect(try await client.searchSuggestions(kind: kind, make: "Synthetic Make") == ["Synthetic A", "Synthetic B"])
    }

    /// 未登录不得读取候选或触发队列；没有照片或账号来源的猜测回退。
    @Test func rejectsAnonymousCandidates() async throws {
        let transport = ImmichQueuedReadTransport { _, _ in
            Issue.record("Anonymous candidate read must not reach transport")
            throw CancellationError()
        }
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), transport: transport)
        await #expect(throws: ImmichAPIError.unauthorized) { try await client.searchSuggestions(kind: .city) }
    }
}
