import Foundation
import Nuke
import Synchronization
import Testing
@testable import Remmich

/// 编辑预览必须明确读未编辑资源，并与普通预览、源版本及账号缓存隔离；测试不执行任何真实HTTP。
@Suite("Unedited editor preview requests")
@MainActor
struct AssetEditorPreviewRequestTests {
    /// 使用真实controller构造请求，检查路径/查询/Bearer、独立缓存和源版本；loader阻断所有意外网络。
    @Test func usesExplicitUneditedPreviewAndSeparateVersionedIdentity() throws {
        let session = makeSession()
        let fixture = makeMedia()
        let media = fixture.media
        defer { media.clearAll(); try? FileManager.default.removeItem(at: fixture.root) }
        media.configure(session: session, activeEndpoint: session.apiURL)
        let revision = Date(timeIntervalSince1970: 100)
        let first = try #require(media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                                    sourceVersion: "checksum-one|updated-one", targetPixels: .init(width: 2048, height: 2048)))
        let request = try #require(first.urlRequest)
        let parts = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(request.httpMethod == "GET")
        #expect(parts.path == "/immich/api/assets/\(assetID)/thumbnail")
        #expect(Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) }) == ["size": "preview", "edited": "false"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        let ordinary = try #require(media.imageRequest(for: .init(assetID: assetID, updatedAt: revision, derivative: .preview,
                                                                  targetPixels: .init(width: 2048, height: 2048)), useSavedPhotos: false))
        let changed = try #require(media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                                      sourceVersion: "checksum-two|updated-two", targetPixels: .init(width: 2048, height: 2048)))
        #expect(first.imageID != ordinary.imageID && changed.imageID != first.imageID)
        let other = makeSession()
        media.configure(session: other, activeEndpoint: other.apiURL)
        let switched = try #require(media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                                       sourceVersion: "checksum-one|updated-one", targetPixels: .init(width: 2048, height: 2048)))
        #expect(switched.imageID != first.imageID)
        #expect(fixture.loader.requestCount == 0)
    }

    /// 缺路由时不能借旧session URL偷偷联网，非法身份/空源版本也不能构造带凭据请求。
    @Test func rejectsMissingRouteAndInvalidSourceIdentity() {
        let fixture = makeMedia()
        defer { fixture.media.clearAll(); try? FileManager.default.removeItem(at: fixture.root) }
        let session = makeSession()
        let revision = Date(timeIntervalSince1970: 100)
        fixture.media.configure(session: session, activeEndpoint: nil)
        #expect(fixture.media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                           sourceVersion: "synthetic", targetPixels: .init(width: 2048, height: 2048)) == nil)
        fixture.media.configure(session: session, activeEndpoint: session.apiURL)
        #expect(fixture.media.uneditedEditorPreviewRequest(assetID: "../other", revision: revision,
                                                           sourceVersion: "synthetic", targetPixels: .init(width: 2048, height: 2048)) == nil)
        #expect(fixture.media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                           sourceVersion: "", targetPixels: .init(width: 2048, height: 2048)) == nil)
        #expect(fixture.loader.requestCount == 0)
    }

    /// 返回固定合法资源ID，不引用任何真实照片。
    private var assetID: String {
        "11111111-1111-4111-8111-111111111111"
    }

    /// 随机userID隔离真实缓存命名空间；endpoint保留路径前缀以检测URL拼接是否丢路径。
    private func makeSession() -> AccountSession {
        let user = "editor-\(UUID().uuidString)"
        return .init(apiURL: URL(string: "https://example.invalid/immich/api")!, accessToken: "synthetic", userID: user,
                     userEmail: "editor@example.invalid", name: "Synthetic", isAdmin: false,
                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
    }

    /// 构建仅测试使用的媒体与空导出队列；配置不读取普通下载历史，所有图片字节来源均被阻断。
    private func makeMedia() -> (media: MediaLibraryController, root: URL, loader: EditorPreviewNoNetworkLoader) {
        let root = FileManager.default.temporaryDirectory.appending(path: "editor-request-\(UUID().uuidString)")
        let queue = LibraryTransferQueue(rootURL: root.appending(path: "transfers"), nativeTasksProvider: { [] },
                                         sessionIdentifier: "io.github.espeonblue.Remmich.editor-unused-\(UUID().uuidString)")
        let exports = MediaExportController(store: .init(databaseURL: root.appending(path: "unused.sqlite")), transfers: queue)
        let loader = EditorPreviewNoNetworkLoader()
        return (MediaLibraryController(imageDataLoader: loader, exports: exports), root, loader)
    }
}

/// 明确阻断本测试controller的全部图片读取；锁保护异步调用计数，不注册URLProtocol或访问真实网络。
private final nonisolated class EditorPreviewNoNetworkLoader: DataLoading, @unchecked Sendable {
    private let count = Mutex(0)
    var requestCount: Int {
        count.withLock { $0 }
    }

    /// request只用于确认没有意外读取；任何调用都返回本地错误，不发出HTTP数据。
    func loadData(with _: URLRequest, didReceiveData _: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        count.withLock { $0 += 1 }
        completion(URLError(.cannotConnectToHost))
        return EditorPreviewCancellation()
    }
}

/// 本地立即失败读取没有在途任务；cancel保持无副作用。
private nonisolated struct EditorPreviewCancellation: Cancellable {
    func cancel() {}
}
