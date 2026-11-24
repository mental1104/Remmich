import Foundation
import ImmichAPI
import Testing
@testable import Remmich

/// 管理写后的主相簿页必须消费前台状态，不能把旧索引响应当作封面/删除/改名已经刷新。
@Suite("Album management foreground refresh")
struct AlbumsManagementRefreshTests {
    /// 初次浏览允许普通来源；写后重载改走前台列表，显示新封面/名称并移除已删除相簿。
    @Test @MainActor func foregroundReloadReplacesStaleAlbumsAndCover() async {
        let reader = RefreshableAlbumReader()
        let store = AlbumsStore(reader: reader)
        await store.load()
        #expect(store.albums.map(\.name) == ["Before", "Deleted"])
        await store.load(fresh: true)
        #expect(store.albums.map(\.name) == ["After"])
        #expect(store.albums.first?.thumbnailAssetID == "new-cover")
        #expect(await reader.normalReads == 1)
        #expect(await reader.foregroundReads == 1)
        #expect(store.errorMessage == nil && !store.isLoading)
    }

    /// 写后GET失败保留旧展示与可见错误，不降级调用普通已完成缓存并伪造成功。
    @Test @MainActor func failedForegroundReadDoesNotFallBackToStaleSuccess() async {
        let reader = RefreshableAlbumReader()
        let store = AlbumsStore(reader: reader)
        await store.load()
        await reader.failForeground()
        await store.load(fresh: true)
        #expect(store.albums.map(\.name) == ["Before", "Deleted"])
        #expect(store.errorMessage != nil && !store.isLoading)
        #expect(await reader.normalReads == 1)
        #expect(await reader.foregroundReads == 1)
    }

    /// 两次真实SDK GET读取相同URL必须能得到不同的当前列表；鉴权、操作名及路径不被绕过。
    @Test func repositoryForegroundReadsUseTheAuthenticatedSDK() async throws {
        let session = refreshAlbumSession()
        let http = AlbumForegroundHTTP()
        let source = ImmichTimelineRepository(readLoader: { request, operation in try await http.load(request, operation: operation) })
        await source.configure(session: session, activeEndpoint: session.apiURL)
        #expect(try await source.foregroundAlbums().map(\.name) == ["First"])
        #expect(try await source.foregroundAlbums().map(\.name) == ["Second"])
        #expect(await http.requests == 2)
    }
}

/// 普通读取固定保留旧状态，前台读取返回新状态；使Store测试能区分两个入口，而不是镜像同一实现。
private actor RefreshableAlbumReader: ManagementAlbumReading {
    private(set) var normalReads = 0
    private(set) var foregroundReads = 0
    private var fails = false

    /// 模拟索引已完成GET；写后调用此方法会使测试观察到旧名称/封面和已删除行。
    func albums() async throws -> [AlbumSummary] {
        normalReads += 1
        return [refreshAlbum("retained", name: "Before", cover: "old-cover"), refreshAlbum("removed", name: "Deleted", cover: nil)]
    }

    /// 返回真实前台状态或明确网络失败；不在本fixture内部调用普通缓存入口。
    func foregroundAlbums() async throws -> [AlbumSummary] {
        foregroundReads += 1
        if fails {
            throw URLError(.networkConnectionLost)
        }
        return [refreshAlbum("retained", name: "After", cover: "new-cover")]
    }

    /// 本测试不加载单相簿；id仍决定返回的身份。
    func album(id: String) async throws -> AlbumSummary {
        refreshAlbum(id, name: "Synthetic", cover: nil)
    }

    /// 下一次前台读取明确失败，验证Store不转用旧索引结果。
    func failForeground() {
        fails = true
    }
}

/// 合成相簿摘要只用于Store行为；id/name/cover分别区分成员身份、改名和封面变化。
private nonisolated func refreshAlbum(_ id: String, name: String, cover: String?) -> AlbumSummary {
    .init(id: id, name: name, description: "", thumbnailAssetID: cover, assetCount: 1,
          updatedAt: Date(timeIntervalSince1970: 100), createdAt: .distantPast, startDate: nil, endDate: nil,
          isShared: false, ownerName: "Synthetic", ownerID: "owner")
}

/// 使用保留域名及假token构造真实仓库会话；不会建立网络。
private nonisolated func refreshAlbumSession() -> AccountSession {
    .init(apiURL: URL(string: "https://album-refresh.example.invalid/api")!, accessToken: "synthetic", userID: "owner",
          userEmail: "owner@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 每次向真实SDK提供新的官方形状字节；测试替身只在HTTP边界，不替换解码、映射或代际检查。
private actor AlbumForegroundHTTP {
    private(set) var requests = 0

    /// request/operation是实际认证后的SDK请求；同URL依次返回不同名称，证明调用不是复用旧解码值。
    func load(_ request: URLRequest, operation: String) throws -> (Data, HTTPURLResponse) {
        requests += 1
        #expect(operation == "getAllAlbums" && request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://album-refresh.example.invalid/api/albums")
        let name = requests == 1 ? "First" : "Second"
        let json = #"[{"id":"95d36426-d0ac-4f48-8a4f-d76367d62385","albumName":"\#(name)","description":"","albumThumbnailAssetId":null,"assetCount":0,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-02T00:00:00Z","shared":false,"hasSharedLink":false,"isActivityEnabled":false,"albumUsers":[]}]"#
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
        return (Data(json.utf8), response)
    }
}
