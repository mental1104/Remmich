import AVFoundation
import Foundation
import Nuke
import Synchronization
import Testing
@testable import Remmich

@Suite("Saved Photos sources", .serialized)
@MainActor
struct MediaSavedPhotosTests {
    @Test func cancellingBeforePhotoKitReturnsItsIDFinishesOnce() async {
        let request = PhotoResourceRead<Data>()
        let cancelled = Mutex(false)
        request.cancel()
        let result: Data? = await withCheckedContinuation { continuation in
            request.begin(continuation)
            request.install { cancelled.withLock { $0 = true } }
            request.finish(Data([1]))
        }
        #expect(result == nil)
        #expect(cancelled.withLock { $0 })
    }

    @Test func completedPhotosReadDoesNotCancelOrResumeAgain() async {
        let request = PhotoResourceRead<Data>()
        let cancelled = Mutex(false)
        let result: Data? = await withCheckedContinuation { continuation in
            request.begin(continuation)
            request.finish(Data([1]))
            request.install { cancelled.withLock { $0 = true } }
            request.cancel()
            request.finish(nil)
        }
        #expect(result == Data([1]))
        #expect(!cancelled.withLock { $0 })
    }

    @Test func matchingResidentPhotoLoadsOfflineWithoutNetwork() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: false)
        defer { fixture.cleanup() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor))
        #expect(request.options.contains(.skipDataLoadingQueue))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([1, 2, 3]))
        #expect(fixture.loader.isEmpty)
        #expect(await fixture.photos.imageReads == 1)
    }

    @Test func missingPhotosFileFallsBackToNormalRemoteLoader() async throws {
        let fixture = try await fixture(local: nil, connected: true)
        defer { fixture.cleanup() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([9, 8, 7]))
        #expect(fixture.loader.count == 1)
        #expect(await fixture.photos.imageReads == 1)
    }

    @Test func savedPreviewDoesNotSubstituteForOriginalOrDifferentRevision() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: true)
        defer { fixture.cleanup() }
        let exports = fixture.media.exports
        #expect(exports.savedReceipt(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .original) == nil)
        #expect(exports.savedReceipt(assetID: "asset", revision: .distantFuture, tier: .preview) == nil)
        let original = MediaRequestDescriptor(assetID: "asset", updatedAt: fixture.descriptor.updatedAt,
                                              derivative: .original, targetPixels: nil)
        let request = try #require(fixture.media.imageRequest(for: original))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([9, 8, 7]))
        #expect(await fixture.photos.imageReads == 0)
        #expect(fixture.loader.count == 1)
    }

    @Test func playbackReceiptProvidesVideoWithoutSubstitutingOriginal() async throws {
        let fixture = try await fixture(local: nil, connected: false, tier: .playback)
        defer { fixture.cleanup() }
        let exports = fixture.media.exports
        let video = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .playback)
        #expect(video?.url.lastPathComponent == "saved.mov")
        let other = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .original)
        #expect(other == nil)
        #expect(await fixture.photos.videoReads == 1)
        exports.reset()
        let afterReset = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .playback)
        #expect(afterReset == nil)
    }

    /// 旧回执继续可在显式Saved Photos读取；普通编辑结果不复用unknown，也不在离线时偷偷读取原片。
    @Test func legacyUnknownRemainsReadableButCannotImpersonateEditedDisplay() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: false, legacy: true)
        defer { fixture.cleanup() }
        let exports = fixture.media.exports
        let receipt = try #require(exports.savedReceipt(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .preview))
        #expect(receipt.sourceMode == nil)
        #expect(exports.savedReceipt(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .preview, requiredSourceMode: .editedDisplay) == nil)
        #expect(fixture.media.imageRequest(for: fixture.descriptor) == nil)
        #expect(try await exports.localImageData(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .preview) == Data([1, 2, 3]))
        #expect(await fixture.photos.imageReads == 1)
        #expect(fixture.loader.isEmpty)
    }

    /// 即使同一资产原片已在手机，普通预览仍走edited=true通道；显式原片离线能力由下一用例保护。
    @Test func residentOriginalCannotSubstituteForEditedPreview() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: true, tier: .original)
        defer { fixture.cleanup() }
        let preview = MediaRequestDescriptor(assetID: "asset", updatedAt: fixture.descriptor.updatedAt, derivative: .preview, targetPixels: nil)
        let request = try #require(fixture.media.imageRequest(for: preview))
        #expect(request.url?.query == "size=preview&edited=true")
        let pipeline = try #require(fixture.media.pipeline)
        #expect(try await pipeline.data(for: request).0 == Data([9, 8, 7]))
        #expect(await fixture.photos.imageReads == 0)
        #expect(fixture.loader.count == 1)
    }

    /// 原片路由没有变更，旧unknown原片回执仍服务显式原片读取，不会被模式迁移删除或强迫联网。
    @Test func explicitLegacyOriginalStillLoadsOffline() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: false, tier: .original, legacy: true)
        defer { fixture.cleanup() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor))
        let pipeline = try #require(fixture.media.pipeline)
        #expect(try await pipeline.data(for: request).0 == Data([1, 2, 3]))
        #expect(await fixture.photos.imageReads == 1)
        #expect(fixture.loader.isEmpty)
    }

    /// local为合成Photos内容，connected决定可用路由，tier指定精确规格，legacy表示冷恢复无来源字段的旧回执。
    /// 返回真实SQLite→exports→media通路及局部网络拦截器，不调用PhotoKit或真实HTTP。
    private func fixture(local: Data?, connected: Bool, tier: MediaExportTier = .preview, legacy: Bool = false) async throws -> SavedPhotosFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedPhotosTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = AccountSession(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "fixture",
                                     userID: UUID().uuidString, userEmail: "test@example.invalid", name: "Test",
                                     isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite3"))
        try await store.prepare(scope: scope)
        let revision = Date(timeIntervalSince1970: 1_700_000_000)
        let receipt = MediaPhotosReceipt(key: "saved", assetID: "asset", revision: revision, tier: tier,
                                         photosID: "photos-asset", albumID: "album", savedAt: .now,
                                         sourceMode: legacy ? nil : tier.requestSourceMode)
        try await store.saveMediaExports(.init(receipts: [receipt]), scope: scope)
        let photos = SavedPhotosFixtureWriter(data: local)
        let exports = MediaExportController(store: store, photos: photos)
        let loader = SavedPhotosFixtureLoader()
        let media = MediaLibraryController(imageDataLoader: loader, exports: exports)
        media.configure(session: session, activeEndpoint: connected ? session.apiURL : nil)
        for _ in 0 ..< 200 {
            if exports.savedReceipt(assetID: "asset", revision: revision, tier: tier) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exports.savedReceipt(assetID: "asset", revision: revision, tier: tier) != nil)
        return .init(root: root, media: media, photos: photos, loader: loader,
                     descriptor: .init(assetID: "asset", updatedAt: revision, derivative: tier.derivative, targetPixels: nil))
    }
}

@MainActor
private struct SavedPhotosFixture {
    let root: URL
    let media: MediaLibraryController
    let photos: SavedPhotosFixtureWriter
    let loader: SavedPhotosFixtureLoader
    let descriptor: MediaRequestDescriptor
    func cleanup() {
        media.clearAll()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SavedPhotosFixtureWriter: MediaPhotosWriting {
    let data: Data?
    var imageReads = 0
    var videoReads = 0
    init(data: Data?) {
        self.data = data
    }

    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        imageReads += 1
        return data
    }

    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        videoReads += 1
        return AVURLAsset(url: URL(fileURLWithPath: "/fixture/saved.mov"))
    }

    func authorize() async throws {
        throw CancellationError()
    }

    func album(savedID _: String?) async throws -> String {
        "album"
    }

    func validateLivePhoto(still _: URL, motion _: URL) async throws {}
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    func verifiedKeys(_ receipts: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: Set(receipts.map(\.key)))
    }
}

private final class SavedPhotosFixtureLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int {
        lock.withLock { requests }
    }

    var isEmpty: Bool {
        lock.withLock { requests == 0 }
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        lock.withLock { requests += 1 }
        let bytes = Data([9, 8, 7])
        didReceiveData(bytes, URLResponse(url: request.url!, mimeType: "image/jpeg", expectedContentLength: bytes.count, textEncodingName: nil))
        completion(nil)
        return SavedPhotosFixtureCancellation()
    }
}

private struct SavedPhotosFixtureCancellation: Cancellable {
    func cancel() {}
}
