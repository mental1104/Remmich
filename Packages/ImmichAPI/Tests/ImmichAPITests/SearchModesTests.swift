import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 检查真实搜索模式路由与分页类型，使用纯内存响应，不访问照片。
@Suite("Search mode contracts")
struct SearchModesTests {
    /// mode为非智能文本语义，必须只生成相应metadata字段并原样使用游标。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .description, .fullPath, .ocr])
    func metadataModeKeepsItsField(_ mode: ImmichMetadataSearch.Mode) async throws {
        var query = ImmichMetadataSearch()
        query.mode = mode
        query.text = "synthetic"
        let client = try makeClient(mode: mode)
        let result = try await client.search(query, continuation: .cursor("opaque"))
        #expect(result.assets.isEmpty)
        #expect(result.continuation == nil)
    }

    /// 智能搜索只使用旧式数字分页；不能把size上限当作全部结果。
    @Test func smartSearchUsesReturnedPageNumber() async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        let result = try await makeClient(mode: .smart).search(query, continuation: .page(2))
        #expect(result.continuation == .page(3))
    }

    /// 地点字段在旧式smart使用官方平铺请求，不因更换模式丢掉国家、省州筛选。
    @Test func smartSearchPreservesRegions() async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        query.country = "Synthetic Country"
        query.state = "Synthetic State"
        let result = try await makeClient(mode: .smart, expectRegions: true).search(query, continuation: .page(2))
        #expect(result.continuation == .page(3))
    }

    /// raw为异常服务器页码，重复/倒退/非数字必须拒绝，避免无限重取。
    @Test(arguments: ["2", "1", "invalid"])
    func rejectsInvalidSmartPage(_ raw: String) async throws {
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        let client = try makeClient(mode: .smart, nextPage: raw)
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query, continuation: .page(2)) }
    }

    /// 同一请求模式不能接受另一种分页token，不向网络猜测转换。
    @Test func rejectsMixedPaginationKinds() async throws {
        let client = try makeClient(mode: .smart)
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(.init(), continuation: .page(2)) }
        var query = ImmichMetadataSearch()
        query.mode = .smart
        query.text = "synthetic"
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query, continuation: .cursor("opaque")) }
    }

    /// mode选择合成断言，nextPage为合成响应，expectRegions要求保留地点；返回客户端，GET队列不应被调用。
    private func makeClient(mode: ImmichMetadataSearch.Mode, nextPage: String = "3", expectRegions: Bool = false) throws -> ImmichClient {
        let transport = ImmichQueuedReadTransport(searchTransport: ModeTransport(mode: mode, nextPage: nextPage, expectRegions: expectRegions)) { _, _ in
            Issue.record("Search POST must not enter the GET queue")
            throw CancellationError()
        }
        return try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("synthetic"), transport: transport)
    }
}

/// 检查生成请求的字段与方法，返回完整空结果外壳。
private struct ModeTransport: ClientTransport {
    let mode: ImmichMetadataSearch.Mode
    let nextPage: String
    let expectRegions: Bool

    /// request/body是SDK输出，baseURL是验证过的API根；按模式验证operationID并返回合成响应。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        let data = try await Data(collecting: #require(body), upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if mode == .smart {
            #expect(operationID == "searchSmart")
            #expect(request.path == "/search/smart")
            #expect(json["query"] as? String == "synthetic")
            #expect(json["page"] as? Int == 2)
            #expect(json["filter"] == nil && json["cursor"] == nil)
            if expectRegions {
                #expect(json["country"] as? String == "Synthetic Country")
                #expect(json["state"] as? String == "Synthetic State")
            }
        } else {
            #expect(operationID == "searchAssets")
            #expect(request.path == "/search/metadata")
            #expect(json["cursor"] as? String == "opaque")
            let filter = try #require(json["filter"] as? [String: Any])
            let key = switch mode {
            case .fileName: "originalFileName"
            case .description: "description"
            case .fullPath: "originalPath"
            case .ocr: "ocr"
            case .smart: "unexpected"
            }
            let condition = try #require(filter[key] as? [String: String])
            #expect(condition[mode == .ocr ? "matches" : "like"] == "synthetic")
        }
        let next = mode == .smart ? "\"\(nextPage)\"" : "null"
        let jsonResponse = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":\(next),\"nextCursor\":null}}"
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(jsonResponse))
    }
}
