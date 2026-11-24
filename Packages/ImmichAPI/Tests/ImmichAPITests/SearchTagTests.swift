import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 标签候选与查询只使用合成响应，验证三态、任一匹配和正确分页路径。
@Suite("Search tag contracts")
struct SearchTagTests {
    private static let firstID = "11111111-1111-4111-8111-111111111111"
    private static let secondID = "22222222-2222-4222-8222-222222222222"

    /// 官方GET候选保留完整层级名称和API前缀，不通过写入入口或公共服务查询。
    @Test func readsAccountTagsThroughOfficialGET() async throws {
        let transport = ImmichQueuedReadTransport { request, operation in
            #expect(operation == "getAllTags")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/immich/api/tags")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "application/json"]))
            let data = Data(#"[{"id":"11111111-1111-4111-8111-111111111111","name":"Child","value":"Parent/Child","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}]"#.utf8)
            return (data, response)
        }
        let url = try #require(URL(string: "https://example.invalid/immich/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let tags = try await client.searchTags()
        #expect(tags.map(\.id) == [Self.firstID])
        #expect(tags.map(\.value) == ["Parent/Child"])
    }

    /// mode与tags交叉验证省略/无标签/多个所选标签；smart选标签时必须使用独立Fork而非旧式all语义。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func preservesEveryTagState(_ mode: ImmichMetadataSearch.Mode) async throws {
        for tags in [ImmichSearchTagFilter.any, .untagged, .anyOf([Self.firstID, Self.secondID])] {
            var query = ImmichMetadataSearch()
            query.mode = mode
            query.text = "synthetic"
            query.city = "Synthetic City"
            query.tags = tags
            let transport = ImmichQueuedReadTransport(searchTransport: TagFilterTransport(mode: mode, tags: tags)) { _, _ in
                Issue.record("Tag search POST must not enter the GET queue")
                throw CancellationError()
            }
            let url = try #require(URL(string: "https://example.invalid/api"))
            let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
            let first = try await client.search(query)
            #expect(first.assets.isEmpty)
            let expected: ImmichSearchContinuation = mode == .smart ? (tags == .any ? .page(2) : .forkCursor("tag-next")) : .cursor("tag-next")
            #expect(first.continuation == expected)
            let last = try await client.search(query, continuation: first.continuation)
            #expect(last.continuation == nil)
        }
    }

    /// mode覆盖metadata/Fork-smart；100个不同UUID必须在首屏及续页完整发送，证明上限包含100。
    @Test(arguments: [ImmichMetadataSearch.Mode.fileName, .smart])
    func acceptsOneHundredDistinctTagIDs(_ mode: ImmichMetadataSearch.Mode) async throws {
        var query = ImmichMetadataSearch()
        query.mode = mode
        query.text = "synthetic"
        query.city = "Synthetic City"
        query.tags = .anyOf(syntheticTagIDs(count: 100))
        let transport = ImmichQueuedReadTransport(searchTransport: TagFilterTransport(mode: mode, tags: query.tags)) { _, _ in
            Issue.record("Tag search POST must not enter the GET queue")
            throw CancellationError()
        }
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let first = try await client.search(query)
        #expect(first.continuation == (mode == .smart ? .forkCursor("tag-next") : .cursor("tag-next")))
        let last = try await client.search(query, continuation: first.continuation)
        #expect(last.continuation == nil)
    }

    /// 非法、空、重复或超量ID不能作为任一匹配条件发送；匿名候选读取也必须先拒绝。
    @Test func rejectsInvalidTagSelectionsBeforeSending() async throws {
        let transport = TagNeverSendTransport()
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        let anonymous = ImmichClient(apiURL: url, transport: transport)
        await #expect(throws: ImmichAPIError.unauthorized) { try await anonymous.searchTags() }
        for ids in [[], ["invalid"], [Self.firstID, Self.firstID.uppercased()], syntheticTagIDs(count: 101),
                    ["aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa"], ["aaaaaaaa-aaaa-4aaa-7aaa-aaaaaaaaaaaa"],
                    ["00000000-0000-0000-0000-000000000000"]]
        {
            for mode in [ImmichMetadataSearch.Mode.fileName, .smart] {
                var query = ImmichMetadataSearch()
                query.mode = mode
                query.text = "synthetic"
                query.tags = .anyOf(ids)
                await #expect(throws: ImmichAPIError.invalidResponse) { try await client.search(query) }
            }
        }
    }

    /// id覆盖UUID版本和variant错误；候选响应不得把不能执行的ID发布为可选择标签。
    @Test(arguments: ["aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa", "aaaaaaaa-aaaa-4aaa-7aaa-aaaaaaaaaaaa"])
    func rejectsCandidateIDsOutsideTheServerContract(_ id: String) async throws {
        let transport = ImmichQueuedReadTransport { request, _ in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "application/json"]))
            let json = #"[{"id":"\#(id)","name":"Synthetic","value":"Synthetic","createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}]"#
            return (Data(json.utf8), response)
        }
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        await #expect(throws: ImmichAPIError.invalidResponse) { try await client.searchTags() }
    }

    /// status是官方标签读取失败；401/403/404不被改为空候选或不受限查询。
    @Test(arguments: [401, 403, 404, 500])
    func preservesCandidateErrors(_ status: Int) async throws {
        let transport = ImmichQueuedReadTransport { request, operation in
            #expect(operation == "getAllTags")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                        headerFields: ["Content-Type": "application/json"]))
            return (Data("{}".utf8), response)
        }
        let url = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: url, credential: .bearer("synthetic"), transport: transport)
        await #expect(throws: ImmichClient.map(status: status)) { try await client.searchTags() }
    }
}

/// count为1–101的测试边界；返回有序、互异且固定版本/variant的UUID，不依赖随机数。
private func syntheticTagIDs(count: Int) -> [String] {
    (1 ... count).map { String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012llx", UInt64($0)) }
}

/// 检查最终HTTP JSON的标签与其他条件，返回完整合成终页。
private struct TagFilterTransport: ClientTransport {
    let mode: ImmichMetadataSearch.Mode
    let tags: ImmichSearchTagFilter

    /// request/body是SDK或Fork包装输出；mode/tags决定预期路径，始终保留城市与回收站范围。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        let encoded = try #require(body)
        let bytes = try await Data(collecting: encoded, upTo: 1_000_000)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nextPage: String
        let nextCursor: String
        if mode == .smart, tags == .any {
            #expect(operationID == "searchSmart" && request.path == "/search/smart")
            #expect(json["city"] as? String == "Synthetic City")
            #expect(json["tagIds"] == nil && json["filter"] == nil)
            let page = try #require(json["page"] as? Int)
            #expect(page == 1 || page == 2)
            nextPage = page == 1 ? "\"2\"" : "null"
            nextCursor = "null"
        } else {
            #expect(operationID == (mode == .smart ? "forkSearchSmart" : "searchAssets"))
            #expect(request.path == (mode == .smart ? "/fork/search/smart" : "/search/metadata"))
            let filter = try #require(json["filter"] as? [String: Any])
            #expect(json["page"] == nil)
            if let cursor = json["cursor"] as? String {
                #expect(cursor == "tag-next")
            }
            nextPage = "null"
            nextCursor = json["cursor"] == nil ? "\"tag-next\"" : "null"
            #expect((filter["city"] as? [String: String])?["eq"] == "Synthetic City")
            #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
            switch tags {
            case .any:
                #expect(filter["tagIds"] == nil && filter["hasTags"] == nil)
            case .untagged:
                #expect(filter["tagIds"] == nil)
                #expect((filter["hasTags"] as? [String: Bool])?["eq"] == false)
            case let .anyOf(ids):
                #expect(filter["hasTags"] == nil)
                #expect((filter["tagIds"] as? [String: [String]]) == ["any": ids])
            }
        }
        let response = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":\(nextPage),\"nextCursor\":\(nextCursor)}}"
        return (HTTPResponse(status: .ok), HTTPBody(response))
    }
}

/// 所有请求均不应进入传输器；用于网络前验证，不触碰实际服务。
private struct TagNeverSendTransport: ClientTransport {
    /// 参数不产生副作用；记录越界发送并抛取消使预期错误断言失败。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Invalid tag selection must not reach transport")
        throw CancellationError()
    }
}
