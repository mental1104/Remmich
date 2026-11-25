import Foundation
import Nuke
import Testing
@testable import Remmich

/// 真正媒体入口必须校验manifest的精确版本，不只给旧文件套一个新的Nuke缓存键。
@Suite("Managed thumbnail version boundary")
@MainActor
struct MediaThumbnailVersionTests {
    /// old/new同秒但相差100ms；旧文件只能服务旧descriptor，新descriptor必须回到真实远端请求。
    @Test func rejectsAnEarlierSameSecondManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "manifest-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSince1970: 100.1), current = Date(timeIntervalSince1970: 100.2)
        #expect(old.ISO8601Format() == current.ISO8601Format())
        let media = MediaLibraryController()
        media.configure(session: .fixture, activeEndpoint: AccountSession.fixture.apiURL)
        defer { media.clearAll() }
        let oldFile = directory.appending(path: LibraryThumbnailCache.displayThumbnailFilename(assetID: "synthetic", updatedAt: old))
        try Data([1]).write(to: oldFile)
        media.registerWarmedThumbnails([.init(assetID: "synthetic", sourceRevision: old.ISO8601Format(), fileURL: oldFile)])
        let oldDescriptor = MediaRequestDescriptor(assetID: "synthetic", updatedAt: old, derivative: .thumbnail, targetPixels: nil)
        let descriptor = MediaRequestDescriptor(assetID: "synthetic", updatedAt: current, derivative: .thumbnail, targetPixels: nil)
        #expect(media.imageRequest(for: oldDescriptor)?.url == nil)
        let fallback = try #require(media.imageRequest(for: descriptor))
        #expect(fallback.url?.path == "/api/assets/synthetic/thumbnail")
        #expect(fallback.url?.query == "size=thumbnail&edited=true")
        let currentFile = directory.appending(path: LibraryThumbnailCache.displayThumbnailFilename(assetID: "synthetic", updatedAt: current))
        try Data([2]).write(to: currentFile)
        media.registerWarmedThumbnails([.init(assetID: "synthetic", sourceRevision: current.ISO8601Format(), fileURL: currentFile)])
        #expect(media.imageRequest(for: descriptor)?.url == nil)
        #expect(media.imageRequest(for: oldDescriptor)?.url != nil)
        #expect(try Data(contentsOf: oldFile) == Data([1]))
    }
}
