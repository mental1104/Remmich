import Foundation
import Nuke
import Synchronization
import Testing
import UIKit
@testable import Remmich

/// 普通浏览明确请求编辑结果，编辑器和显式原片仍保持不同网络语义及缓存；合成loader截断真实网络。
@Suite("Edited display and original isolation")
@MainActor
struct MediaEditedDisplayRequestTests {
    /// 三种展示规格均选择edited=true；原片/视频路径及未编辑页面不能继承该查询或缓存身份。
    @Test func choosesEditedDerivativesWithoutChangingOriginalDownloads() throws {
        let fixture = makeFixture()
        defer { fixture.media.clearAll(); try? FileManager.default.removeItem(at: fixture.root) }
        let revision = Date(timeIntervalSince1970: 100)
        let scope = try #require(fixture.media.scope)
        for (derivative, size) in [(MediaDerivative.thumbnail, "thumbnail"), (.preview, "preview"), (.fullSize, "fullsize")] {
            let descriptor = MediaRequestDescriptor(assetID: assetID, updatedAt: revision, derivative: derivative, targetPixels: nil)
            let display = try #require(fixture.media.imageRequest(for: descriptor, useSavedPhotos: false))
            let parts = try #require(display.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            #expect(parts.path == "/prefix/api/assets/\(assetID)/thumbnail")
            #expect(parts.queryItems == [.init(name: "size", value: size), .init(name: "edited", value: "true")])
            #expect(display.imageID != descriptor.cacheKey(in: scope))
            let download = try #require(fixture.media.downloadURL(assetID: assetID, derivative: derivative))
            #expect(download == display.url)
        }
        for derivative in [MediaDerivative.original, .videoPlayback] {
            let descriptor = MediaRequestDescriptor(assetID: assetID, updatedAt: revision, derivative: derivative, targetPixels: nil)
            let request = try #require(fixture.media.imageRequest(for: descriptor, useSavedPhotos: false))
            #expect(request.url?.query == nil)
            #expect(request.imageID == descriptor.cacheKey(in: scope))
            #expect(fixture.media.downloadURL(assetID: assetID, derivative: derivative)?.query == nil)
        }
        #expect(fixture.loader.requests.isEmpty)
    }

    /// 同一资产/revision实际通过同一个pipeline读取两种图片；旧未编辑cache不能冒充展示，也不能污染编辑器。
    @Test func pipelineKeepsEditedUneditedAndLegacyBytesSeparate() async throws {
        let fixture = makeFixture()
        defer { fixture.media.clearAll(); try? FileManager.default.removeItem(at: fixture.root) }
        let revision = Date(timeIntervalSince1970: 100)
        let descriptor = MediaRequestDescriptor(assetID: assetID, updatedAt: revision, derivative: .preview, targetPixels: nil)
        let display = try #require(fixture.media.imageRequest(for: descriptor, useSavedPhotos: false))
        let editor = try #require(fixture.media.uneditedEditorPreviewRequest(assetID: assetID, revision: revision,
                                                                             sourceVersion: "synthetic|revision-one", targetPixels: .init(width: 2048, height: 2048)))
        let pipeline = try #require(fixture.media.pipeline)
        var legacy = display
        legacy.imageID = try descriptor.cacheKey(in: #require(fixture.media.scope))
        pipeline.cache.storeCachedData(fixture.loader.original, for: legacy)

        let edited = try await pipeline.imageTask(with: display).response
        let unedited = try await pipeline.imageTask(with: editor).response
        #expect(edited.image.size == CGSize(width: 20, height: 10))
        #expect(unedited.image.size == CGSize(width: 30, height: 20))
        #expect(display.imageID != editor.imageID && display.imageID != legacy.imageID)
        let requests = fixture.loader.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic" })
        #expect(requests.compactMap { $0.url?.query } == ["size=preview&edited=true", "size=preview&edited=false"])

        // 导出同规格时按展示请求的真实缓存身份读取；不能因registerExportRequest仍记旧ID返回未编辑数据。
        #expect(await fixture.media.exportCachedData(assetID: assetID, revision: revision, tier: .preview) == fixture.loader.edited)
    }

    /// 服务端可能先返回旧派生图、再于同秒的新updatedAt完成渲染；新revision必须实际重读，不能命中中间缓存。
    @Test func derivedCompletionWithinOneSecondGetsASeparateDisplayRequest() async throws {
        let fixture = makeFixture()
        defer { fixture.media.clearAll(); try? FileManager.default.removeItem(at: fixture.root) }
        let pipeline = try #require(fixture.media.pipeline)
        let intermediate = try #require(fixture.media.imageRequest(for: .init(assetID: assetID, updatedAt: Date(timeIntervalSince1970: 100.1),
                                                                              derivative: .preview, targetPixels: nil), useSavedPhotos: false))
        #expect(try await pipeline.imageTask(with: intermediate).response.image.size == CGSize(width: 20, height: 10))
        fixture.loader.replaceEditedBytes(imageData(width: 10, height: 20))
        let completed = try #require(fixture.media.imageRequest(for: .init(assetID: assetID, updatedAt: Date(timeIntervalSince1970: 100.2),
                                                                           derivative: .preview, targetPixels: nil), useSavedPhotos: false))
        #expect(completed.url == intermediate.url && completed.imageID != intermediate.imageID)
        #expect(try await pipeline.imageTask(with: completed).response.image.size == CGSize(width: 10, height: 20))
        #expect(fixture.loader.requests.count == 2)
    }

    /// 不读取私人资源的固定UUID；每个fixture通过随机账号隔离磁盘命名空间。
    private var assetID: String {
        "11111111-1111-4111-8111-111111111111"
    }

    /// 返回真实媒体控制器、隔离导出目录与合成图loader；没有未受控的HTTP或Photos请求。
    private func makeFixture() -> (media: MediaLibraryController, root: URL, loader: EditedDisplayFixtureLoader) {
        let root = FileManager.default.temporaryDirectory.appending(path: "edited-display-\(UUID().uuidString)")
        let loader = EditedDisplayFixtureLoader(edited: imageData(width: 20, height: 10), original: imageData(width: 30, height: 20))
        let queue = LibraryTransferQueue(rootURL: root.appending(path: "transfers"), nativeTasksProvider: { [] },
                                         sessionIdentifier: "io.github.espeonblue.Remmich.display-unused-\(UUID().uuidString)")
        let exports = MediaExportController(store: .init(databaseURL: root.appending(path: "unused.sqlite")), transfers: queue)
        let media = MediaLibraryController(imageDataLoader: loader, exports: exports)
        let session = AccountSession(apiURL: URL(string: "https://example.invalid/prefix/api")!, accessToken: "synthetic",
                                     userID: "display-\(UUID().uuidString)", userEmail: "display@example.invalid", name: "Synthetic",
                                     isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        media.configure(session: session, activeEndpoint: session.apiURL)
        return (media, root, loader)
    }

    /// width/height为合成有限图像素尺寸；尺寸本身是独立观测值，不依赖产品缓存或描述符计算。
    private func imageData(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }
}

/// 同步记录真实pipeline请求并返回本地合成字节；Mutex保护可能从后台队列进入的调用，不连接网络。
private final nonisolated class EditedDisplayFixtureLoader: DataLoading, @unchecked Sendable {
    let edited: Data
    let original: Data
    private let recorded = Mutex<[URLRequest]>([])
    private let replacement = Mutex<Data?>(nil)

    /// edited/original为两份独立图片字节；init不执行任何请求。
    init(edited: Data, original: Data) {
        self.edited = edited
        self.original = original
    }

    /// 返回已拦截请求的值快照，避免测试与loader并发读取可变数组。
    var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    /// data替换模拟的异步派生完成内容；只改本地fixture，不更新任何服务端或产品缓存。
    func replaceEditedBytes(_ data: Data) {
        replacement.withLock { $0 = data }
    }

    /// request由实际ImagePipeline提供；按edited查询返回合成图或本地错误，回调均在当前调用栈完成。
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        recorded.withLock { $0.append(request) }
        guard let url = request.url,
              let editedValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "edited" })?.value,
              ["true", "false"].contains(editedValue)
        else {
            completion(URLError(.badURL))
            return EditedDisplayFixtureCancellation()
        }
        let data = editedValue == "true" ? replacement.withLock { $0 } ?? edited : original
        didReceiveData(data, URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
        completion(nil)
        return EditedDisplayFixtureCancellation()
    }
}

/// fixture没有延后任务；取消令牌不触发网络或文件副作用。
private nonisolated struct EditedDisplayFixtureCancellation: Cancellable {
    /// 返回立即完成读取的空取消动作。
    func cancel() {}
}
