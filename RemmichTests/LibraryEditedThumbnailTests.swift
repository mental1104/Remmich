import Foundation
import Testing
@testable import Remmich

/// 持久缩略图模式升级与旧队列恢复；使用合成记录/本地目录，禁止启动真实传输。
@Suite("Edited thumbnail cache migration")
struct LibraryEditedThumbnailTests {
    /// 相同资产/源revision的旧文件仍在磁盘，模式未知不能投影或计为edited缓存完成；新记录可正常投影。
    @Test func legacyRecordsDoNotMasqueradeAsEditedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = MediaAccountScope(session: .fixture)
        let asset = makeAsset()
        let old = record(asset: asset, file: "thumbnail/legacy.bin")
        let filename = LibraryThumbnailCache.displayThumbnailFilename(assetID: asset.id, updatedAt: asset.updatedAt)
        let current = record(asset: asset, file: "thumbnail/\(filename)")
        let directory = root.appending(path: scope.cacheNamespace).appending(path: "thumbnail")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFile = directory.appending(path: "legacy.bin")
        let currentFile = directory.appending(path: filename)
        try Data([1]).write(to: oldFile)
        try Data([2]).write(to: currentFile)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        try await store.upsert(derivatives: [old], scope: scope)
        let cache = LibraryThumbnailCache(store: store, rootURL: root)
        #expect(try await cache.cachedProgress(assets: [asset], scope: scope).cachedCount == 0)
        #expect(LibraryThumbnailCache.projectIndexedThumbnails(records: [old], scope: scope, rootURL: root).isEmpty)
        try await store.upsert(derivatives: [current], scope: scope)
        #expect(try await cache.cachedProgress(assets: [asset], scope: scope).cachedCount == 1)
        #expect(LibraryThumbnailCache.projectIndexedThumbnails(records: [current], scope: scope, rootURL: root).first?.fileURL == currentFile)
        #expect(try Data(contentsOf: oldFile) == Data([1]))
    }

    /// 冷恢复的旧GET完成体不能让导入器误报就绪；预取替换成明确edited=true的有界配对且不联网。
    @Test func replacesLegacyQueuedThumbnailSemanticsWithoutReplayingTheBody() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-queue-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AccountSession.fixture
        let scope = MediaAccountScope(session: session)
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let asset = makeAsset()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        let oldURL = session.apiURL.appending(path: "assets/\(asset.id)/thumbnail").appending(queryItems: [.init(name: "size", value: "thumbnail")])
        var old = try journal.job(url: oldURL, kind: .thumbnail, owner: owner, sourceRevision: asset.updatedAt.ISO8601Format())
        old.state = .completed; old.statusCode = 200
        journal.update(old)
        try journal.save(to: root.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] }, sessionIdentifier: "io.github.espeonblue.Remmich.mode-unused-\(UUID().uuidString)")
        #expect(try await queue.readyCacheAssets([asset], owner: owner, thumbnailIDs: [], metadataIDs: [asset.id]).ids.isEmpty)
        // 关闭真实cache传输，只检查实际预取写出的持久请求；nativeTasksProvider也阻止恢复系统任务。
        try await queue.configure(session: session, endpoint: session.apiURL, cacheAllowed: false)
        await queue.prefetchCache([asset], scope: scope, endpoint: session.apiURL, thumbnailIDs: [], metadataIDs: [])
        let refreshed = try LibraryTransferJournal.load(from: root.appending(path: "journal.json"))
        let thumbnail = try #require(refreshed.jobs.first { $0.kind == .thumbnail })
        #expect(thumbnail.id != old.id && thumbnail.state == .queued)
        #expect(thumbnail.url.path == session.apiURL.appending(path: "assets/\(asset.id)/thumbnail").path)
        #expect(thumbnail.url.query == "size=thumbnail&edited=true")
        #expect(thumbnail.sourceRevision == asset.updatedAt.ISO8601Format())
        #expect(refreshed.jobs.count == 2)
    }

    /// 同秒内服务端派生完成时不能只按省略小数的sourceRevision计为已缓存，文件版本须反映实际毫秒。
    @Test func subsecondDerivedVersionsDoNotCountAnIntermediateThumbnailAsCurrent() {
        let oldAsset = makeAsset(revision: Date(timeIntervalSince1970: 100.1))
        let completedAsset = makeAsset(revision: Date(timeIntervalSince1970: 100.2))
        let filename = LibraryThumbnailCache.displayThumbnailFilename(assetID: oldAsset.id, updatedAt: oldAsset.updatedAt)
        let intermediate = record(asset: oldAsset, file: "thumbnail/\(filename)")
        #expect(oldAsset.updatedAt.ISO8601Format() == completedAsset.updatedAt.ISO8601Format())
        #expect(LibraryThumbnailCache.cachedProgress(assets: [oldAsset], derivatives: [intermediate]).cachedCount == 1)
        #expect(LibraryThumbnailCache.cachedProgress(assets: [completedAsset], derivatives: [intermediate]).cachedCount == 0)
    }

    /// 固定合成资产身份/版本/尺寸；与实际索引模型同构，未读取服务端或照片。
    private func makeAsset(revision: Date = Date(timeIntervalSince1970: 100)) -> LibraryIndexAssetRecord {
        .init(id: "synthetic", ownerID: "synthetic", kind: .image, livePhotoVideoID: nil,
              capturedAt: .distantPast, uploadedAt: .distantPast, updatedAt: revision,
              checksum: "synthetic", width: 60, height: 40, aspectRatio: 1.5, durationMilliseconds: nil,
              isFavorite: false, visibility: "timeline", isTrashed: false, isOffline: false,
              bucketKey: "synthetic", dayKey: "synthetic", weekKey: "synthetic", monthKey: "synthetic", yearKey: "synthetic")
    }

    /// asset固定源revision，file区分旧/新展示模式路径；返回已验证合成派生记录，不假装新模式来自旧文件。
    private func record(asset: LibraryIndexAssetRecord, file: String) -> LibraryIndexDerivativeRecord {
        .init(assetID: asset.id, derivative: .thumbnail, pixelSize: nil, sourceRevision: asset.updatedAt.ISO8601Format(),
              relativeFileKey: file, byteCount: 1, digest: "synthetic", isVerified: true, lastAccessedAt: .now, completedAt: .now)
    }
}
