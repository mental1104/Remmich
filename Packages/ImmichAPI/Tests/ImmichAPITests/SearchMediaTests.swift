import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 媒体来源、分辨率和全景必须在首屏及续页保留，不能借旧式smart丢失高级条件。
@Suite("Search media contracts")
struct SearchMediaTests {
    /// category和resolution遍历固定协议全集；metadata与Fork智能路径均实际编码两页请求。
    @Test(arguments: ImmichSearchMediaCategory.allCases, ImmichSearchResolution.allCases)
    func preservesMediaConditionsAcrossPages(_ category: ImmichSearchMediaCategory, _ resolution: ImmichSearchResolution) async throws {
        for mode in [ImmichMetadataSearch.Mode.fileName, .smart] {
            var query = ImmichMetadataSearch()
            query.text = "synthetic"
            query.mode = mode
            query.mediaCategory = category
            query.resolution = resolution
            query.panoramasOnly = true
            #expect(query.requiresForkSmartSearch == (mode == .smart))
            try await verifyPages(query)
        }
    }

    /// 单独的category也必须触发完整Fork智能分页；不让其他扩展条件掩盖路由判断回归。
    @Test(arguments: ImmichSearchMediaCategory.allCases)
    func routesStandaloneCategory(_ category: ImmichSearchMediaCategory) async throws {
        var query = ImmichMetadataSearch()
        query.mediaCategory = category
        try await verifyPages(query)
        query.mode = .smart
        query.text = "synthetic"
        #expect(query.requiresForkSmartSearch)
        try await verifyPages(query)
    }

    /// 全景或分辨率单独启用仍可执行；空文本保留metadata协议，非空smart选择独立Fork协议。
    @Test func routesStandaloneMediaConditions() async throws {
        var panorama = ImmichMetadataSearch()
        panorama.panoramasOnly = true
        var resolution = ImmichMetadataSearch()
        resolution.resolution = .fourK
        for var query in [panorama, resolution] {
            try await verifyPages(query)
            query.mode = .smart
            query.text = "synthetic"
            #expect(query.requiresForkSmartSearch)
            try await verifyPages(query)
        }
    }

    /// 未选择扩展媒体条件时，普通metadata不得写false条件或默认档位。
    @Test func omitsUnselectedMediaFilters() async throws {
        var query = ImmichMetadataSearch()
        query.text = "synthetic"
        try await verifyPages(query)
    }

    /// 交叉整合后的媒体/设备/标签/EXIF必须同页保留；参考图也不能退回文字或旧式smart。
    @Test func preservesCombinedFiltersForEveryQuerySource() async throws {
        var query = ImmichMetadataSearch()
        query.text = "synthetic"
        query.mediaCategory = .steamScreenshot
        query.resolution = .fourK
        query.panoramasOnly = true
        query.deviceModels = ["Synthetic Model", "Synthetic Alias"]
        query.cameraModel = "Synthetic Model"
        query.tags = .anyOf(["11111111-1111-4111-8111-111111111111"])
        query.orientation = .landscape
        query.hasAlbums = false
        query.rating = .stars(0)
        query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400)]
        try await verifyPages(query)
        query.mode = .smart
        try await verifyPages(query)
        query.queryAssetID = "22222222-2222-4222-8222-222222222222"
        query.text = ""
        try await verifyPages(query)
    }

    /// query为完整不可变条件；两页都经SDK和真实JSON编码，返回令牌须按原协议继续使用。
    private func verifyPages(_ query: ImmichMetadataSearch) async throws {
        let endpoint = try #require(URL(string: "https://example.invalid/api"))
        let client = ImmichClient(apiURL: endpoint, credential: .bearer("synthetic"), transport: MediaSearchTransport(query: query))
        let first = try await client.search(query)
        let token = try #require(first.continuation)
        #expect(token == (query.requiresForkSmartSearch ? .forkCursor("next") : .cursor("next")))
        let last = try await client.search(query, continuation: token)
        #expect(last.continuation == nil)
    }
}

/// 只接收SDK发出的合成请求，不建立网络连接；逐字段检验媒体条件与分页令牌。
private struct MediaSearchTransport: ClientTransport {
    let query: ImmichMetadataSearch

    /// request/body为实际编码请求；query为独立期望，返回首屏或终屏合成搜索响应。
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(request.method == .post)
        #expect(request.headerFields[.authorization] == "Bearer synthetic")
        #expect(operationID == (query.requiresForkSmartSearch ? "forkSearchSmart" : "searchAssets"))
        #expect(request.path == (query.requiresForkSmartSearch ? "/fork/search/smart" : "/search/metadata"))
        let encoded = try #require(body)
        let bytes = try await Data(collecting: encoded, upTo: 1_000_000)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let filter = try #require(object["filter"] as? [String: Any])
        if let resolution = query.resolution {
            #expect((filter["resolution"] as? [String: String])?["eq"] == resolution.rawValue)
        } else {
            #expect(filter["resolution"] == nil)
        }
        if query.panoramasOnly {
            #expect((filter["isPanorama"] as? [String: Bool])?["eq"] == true)
        } else {
            #expect(filter["isPanorama"] == nil)
        }
        let categoryKeys: [(ImmichSearchMediaCategory, String)] = [
            (.phoneVideo, "isPhoneVideo"), (.screenshot, "isScreenshot"), (.deltaScreenshot, "isDeltaScreenshot"),
            (.steamScreenshot, "isSteamScreenshot"), (.switchScreenshot, "isSwitchScreenshot"), (.nintendo3dsScreenshot, "isNintendo3dsScreenshot"),
        ]
        for (category, key) in categoryKeys {
            if query.mediaCategory == category {
                #expect((filter[key] as? [String: Bool])?["eq"] == true)
            } else {
                #expect(filter[key] == nil)
            }
        }
        #expect(object["page"] == nil)
        if !query.deviceModels.isEmpty {
            let model = try #require(filter["model"] as? [String: Any])
            #expect(model["in"] as? [String] == query.deviceModels)
            #expect(model["eq"] as? String == query.cameraModel)
        }
        if case let .anyOf(ids) = query.tags {
            #expect((filter["tagIds"] as? [String: [String]])?["any"] == ids)
            #expect((filter["iso"] as? [String: Double])?["gte"] == 400)
            #expect((filter["rating"] as? [String: Int])?["eq"] == 0)
            #expect((filter["orientation"] as? [String: String])?["eq"] == "landscape")
            #expect((filter["hasAlbums"] as? [String: Bool])?["eq"] == false)
        }
        if query.requiresForkSmartSearch {
            if let reference = query.queryAssetID {
                #expect(object["query"] == nil)
                #expect(object["queryAssetId"] as? String == reference)
            } else {
                #expect(object["query"] as? String == "synthetic")
                #expect(object["queryAssetId"] == nil)
            }
        }
        if let cursor = object["cursor"] as? String {
            #expect(cursor == "next")
        }
        let next = object["cursor"] == nil ? "\"next\"" : "null"
        let response = "{\"albums\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[]},\"assets\":{\"total\":0,\"count\":0,\"items\":[],\"facets\":[],\"nextPage\":null,\"nextCursor\":\(next)}}"
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
    }
}
