import AVFoundation
import Foundation
import Nuke
import Photos
import Synchronization
import Testing
import UIKit
@testable import Remmich

/// 无CloudID Live still的真实hash→匹配→JSON保存→Media→Nuke图片链；仅系统/远端来源注入，未直接设置关联字典。
@Suite("Live still checksum match and display")
@MainActor struct LocalLiveStillMatchDisplayTests {
    /// reverse让pairedVideo位于首项，证明主匹配入口仍实际选photo并显示同一完整PNG，不能凭资源位置猜still。
    @Test(arguments: [false, true])
    func liveStillUsesRealChecksumControllerPersistenceAndNuke(_ reverse: Bool) async throws {
        let fixture = try await liveStillDisplayFixture(reverse: reverse)
        defer { fixture.close() }
        let operation = try #require(fixture.matches.scan(using: fixture.media.management)); await operation.value
        let association = try #require(fixture.matches.association(assetID: stillDisplayAssetID.uuidString, revision: stillDisplayRevision))
        #expect(association.source == .checksum && association.localIdentity.mediaKind == .livePhoto)
        #expect(association.localIdentity == fixture.source.snapshot.identity && association.checksum == "dXJF9wiRoT2hATQFBjrZSNgGWM0=")
        #expect(fixture.matches.checksumMatches == 1 && fixture.matches.metadataMatches == 0 && fixture.matches.scanned == 1 && !fixture.matches.running)
        #expect(fixture.matches.association(assetID: stillDisplayAssetID.uuidString, revision: stillDisplayRevision.addingTimeInterval(0.001)) == nil)

        let reads = await fixture.remote.reads
        #expect(reads.metadataCalls == 0 && reads.assetIDs == [stillDisplayAssetID] && reads.digests.count == 1)
        #expect(reads.digests.first?.sha1Hex == "757245f70891a13da1013405063ad948d80658cd" && reads.digests.first?.byteCount == 74)
        #expect(reads.digests.first?.sha1Base64 == "dXJF9wiRoT2hATQFBjrZSNgGWM0=")
        #expect(fixture.hash.sourceReads == 2 && fixture.hash.resources.count == 1 && fixture.hash.resources.first?.descriptor.role == .originalPhoto)
        #expect(fixture.hash.network == [false] && fixture.hash.resources.first?.descriptor.type == PHAssetResourceType.photo.rawValue)

        // 新actor从实际磁盘恢复，不能用Controller当前内存当作持久化通过。
        let cold = LocalMediaAssociationStore(directory: fixture.matchDirectory)
        let restored = try await cold.load(scope: fixture.scope)
        let document = try #require(restored)
        #expect(document.namespace == fixture.scope.cacheNamespace && document.enabled && document.access == .full)
        #expect(document.associations == [association] && document.associations.first?.remoteRevision == stillDisplayRevision)
        let other = MediaAccountScope(session: stillDisplaySession(owner: UUID().uuidString))
        let absent = try await cold.load(scope: other)
        #expect(absent == nil)

        let descriptor = MediaRequestDescriptor(assetID: stillDisplayAssetID.uuidString, updatedAt: stillDisplayRevision, derivative: .preview,
                                                targetPixels: .init(width: 4000, height: 3000))
        let request = try #require(fixture.media.imageRequest(for: descriptor))
        let pipeline = try #require(fixture.media.pipeline)
        let response = try await pipeline.imageTask(with: request).response
        #expect(request.url == nil && response.image.size == CGSize(width: 3, height: 2))
        #expect(response.image.cgImage?.width == 3 && response.image.cgImage?.height == 2)
        #expect(fixture.images.imageRequests == 1 && fixture.images.kinds == [.livePhoto] && fixture.images.videoRequests == 0)
        #expect(fixture.images.version == .current && fixture.images.network == false && fixture.images.pixels == .init(width: 2048, height: 2048))
        #expect(fixture.loader.requests.isEmpty && fixture.media.mediaReadOrigin(assetID: stillDisplayAssetID.uuidString, revision: stillDisplayRevision) == .devicePhotos)
        let afterDisplay = await fixture.remote.reads
        #expect(afterDisplay.metadataCalls == 0 && afterDisplay.assetIDs == [stillDisplayAssetID] && afterDisplay.digests.count == 1)
    }

    /// 即使photo字节未变，paired描述在hash期间变化仍使真实reader拒绝；Controller不能发precheck/fresh或保存关联。
    @Test func pairedResourceChangeStopsBeforePrecheckAndAssociation() async throws {
        let fixture = try await liveStillDisplayFixture(reverse: true, changedPair: true)
        defer { fixture.close() }
        let operation = try #require(fixture.matches.scan(using: fixture.media.management)); await operation.value
        #expect(fixture.matches.association(assetID: stillDisplayAssetID.uuidString, revision: stillDisplayRevision) == nil)
        #expect(fixture.matches.checksumMatches == 0 && fixture.matches.metadataMatches == 0 && !fixture.matches.running)
        #expect(fixture.matches.status.contains("扫描未完成"))
        #expect(fixture.hash.sourceReads == 2 && fixture.hash.resources.count == 1 && fixture.hash.resources.first?.descriptor.role == .originalPhoto)
        #expect(fixture.hash.network == [false] && fixture.images.imageRequests == 0 && fixture.images.videoRequests == 0 && fixture.loader.requests.isEmpty)
        let reads = await fixture.remote.reads
        #expect(reads.metadataCalls == 0 && reads.assetIDs.isEmpty && reads.digests.isEmpty)
        let cold = LocalMediaAssociationStore(directory: fixture.matchDirectory)
        let restored = try await cold.load(scope: fixture.scope)
        let document = try #require(restored)
        #expect(document.namespace == fixture.scope.cacheNamespace && document.enabled && document.associations.isEmpty)
    }
}

private nonisolated let stillDisplayAssetID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private nonisolated let stillDisplayMotionID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
private nonisolated let stillDisplayRevision = Date(timeIntervalSince1970: 100.123)

/// Node zlib生成的完整3x2 RGBA PNG（74bytes），SHA1由独立Node crypto确认；不是冒充照片的文本/局部块。
private nonisolated func stillDisplayPNG() throws -> Data {
    try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGP4oGHzH4YZkDkAtKEN8+A/5/cAAAAASUVORK5CYII="))
}

/// 所有端点和账号均合成，profile/session注入拦截而不使用真实账号或媒体。
private nonisolated func stillDisplaySession(owner: String = UUID().uuidString) -> AccountSession {
    .init(apiURL: URL(string: "https://still-display.invalid/prefix/api")!, accessToken: "synthetic-live-still", userID: owner,
          userEmail: "still@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 两个公开资源共享本机Live身份，changed只替换paired描述；完整数组和snapshot同时变化以模拟真实源版本核验。
private nonisolated func stillDisplaySource(reverse: Bool, changed: Bool = false) -> LocalPhotoChecksumAsset {
    let photo = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.photo.rawValue, role: .originalPhoto, originalFilename: "synthetic.png",
                                                             uniformTypeIdentifier: "public.png", pixelWidth: 3, pixelHeight: 2), format: .image)
    let motion = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.pairedVideo.rawValue, role: .pairedVideo,
                                                              originalFilename: changed ? "changed-paired.mov" : "synthetic-paired.mov", uniformTypeIdentifier: "com.apple.quicktime-movie", pixelWidth: 3, pixelHeight: 2), format: .video)
    let resources = reverse ? [motion, photo] : [photo, motion]
    let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: "synthetic-live-still-display", modificationDate: Date(timeIntervalSince1970: 15), mediaKind: .livePhoto),
                                      creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
                                      pixelWidth: 3, pixelHeight: 2, duration: 0, mediaSubtypes: PHAssetMediaSubtype.photoLive.rawValue,
                                      resources: resources.map(\.descriptor), cloudIdentity: .unavailable)
    return .init(snapshot: snapshot, resources: resources)
}

/// 每例恢复/导出/SQLite/传输资料临时隔离，媒体缓存使用随机scope namespace；不读取真实Photos库。
@MainActor private struct StillDisplayFixture {
    let root: URL
    let matchDirectory: URL
    let scope: MediaAccountScope
    let source: LocalPhotoChecksumAsset
    let media: MediaLibraryController
    let matches: LocalMediaMatchController
    let remote: StillDisplayRemote
    let hash: StillDisplayHashSource
    let images: StillDisplayImageDriver
    let loader: StillDisplayNoMedia
    let profile: URLSession

    /// 取消实际账号任务后销毁实例会话和临时文件，未登记全局URLProtocol。
    func close() {
        media.clearAll(); profile.invalidateAndCancel(); try? FileManager.default.removeItem(at: root)
    }
}

/// 只替换系统来源；真实元数据reader、checksum reader、SHA1、Controller、JSON、Media/Nuke全在路径中执行。
@MainActor private func liveStillDisplayFixture(reverse: Bool, changedPair: Bool = false) async throws -> StillDisplayFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveStillDisplay-\(UUID())", isDirectory: true)
    let matchDirectory = root.appendingPathComponent("matches")
    let session = stillDisplaySession(); let scope = MediaAccountScope(session: session)
    let source = stillDisplaySource(reverse: reverse)
    let bytes = try stillDisplayPNG()
    let image = try #require(UIImage(data: bytes, scale: 1))
    let hash = StillDisplayHashSource(before: source, after: changedPair ? stillDisplaySource(reverse: reverse, changed: true) : source, bytes: bytes)
    let checksum = PhotoKitCurrentResourceChecksumReader(source: hash.source, bytes: hash.read, authorization: { .authorized })
    let metadata = PhotoKitLocalPhotoMetadataReader(assets: { ids in ids.contains(source.snapshot.identity.localIdentifier) ? [source.snapshot] : [] }, cloudIDs: { ids in
        Dictionary(uniqueKeysWithValues: ids.map { ($0, LocalPhotoCloudIdentity.unavailable) })
    })
    let remote = StillDisplayRemote(owner: UUID(uuidString: session.userID)!)
    let matches = LocalMediaMatchController(inventory: StillDisplayInventory(id: source.snapshot.identity.localIdentifier), metadata: metadata, checksum: checksum,
                                            remote: remote, persistence: LocalMediaAssociationStore(directory: matchDirectory), observeChanges: false)
    let images = StillDisplayImageDriver(snapshot: source.snapshot, image: image)
    let local = PhotoKitLocalPhotoMediaReader(driver: images)
    let loader = StillDisplayNoMedia()
    let transfers = LibraryTransferQueue(rootURL: root.appendingPathComponent("transfers"), nativeTasksProvider: { [] }, sessionIdentifier: "io.github.espeonblue.still-display-unused-\(UUID())")
    let exports = MediaExportController(store: .init(databaseURL: root.appendingPathComponent("unused.sqlite")), photos: StillDisplayNoExports(), transfers: transfers)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StillDisplayProfileProtocol.self]
    let profile = URLSession(configuration: configuration)
    let media = MediaLibraryController(imageDataLoader: loader, exports: exports, localMediaMatches: matches, localPhotoReader: local, profileImageSession: profile)
    media.configure(session: session, activeEndpoint: session.apiURL)
    let restore = try #require(matches.restoreAndRefresh(using: media.management, scope: scope)); await restore.value
    #expect(!matches.enabled)
    return .init(root: root, matchDirectory: matchDirectory, scope: scope, source: source, media: media, matches: matches, remote: remote,
                 hash: hash, images: images, loader: loader, profile: profile)
}

/// 仅提供已授权本机清单，不调用真实系统照片库。
@MainActor private struct StillDisplayInventory: LocalPhotoInventoryReading {
    let id: String
    var authorization: LocalPhotoLibraryAccess {
        .full
    }

    /// 明确scan由真实Controller请求一次已有授权，本例不弹系统框。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        .full
    }

    /// validateContext仍真实执行，只返回本例合成ID。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return [id]
    }
}

/// 系统资源来源只提供两份完整观察和PNG块；源选择、前后校验、摘要与取消都由真实产品代码执行。
@MainActor private final class StillDisplayHashSource {
    private let before: LocalPhotoChecksumAsset
    private let after: LocalPhotoChecksumAsset
    private let bytes: Data
    private(set) var sourceReads = 0
    private(set) var resources: [LocalPhotoChecksumResource] = []
    private(set) var network: [Bool] = []
    /// before/after控制配对描述时序，bytes为完整可解码PNG；不预设reader选哪个资源。
    init(before: LocalPhotoChecksumAsset, after: LocalPhotoChecksumAsset, bytes: Data) {
        self.before = before; self.after = after; self.bytes = bytes
    }

    /// id必须为同一本机Live对象；返回实际次序观察，不替产品吞掉changed pair。
    func source(_ id: String) throws -> LocalPhotoChecksumAsset? {
        guard id == before.snapshot.identity.localIdentifier else { throw LocalPhotoChecksumError.invalidInput }
        sourceReads += 1; return sourceReads == 1 ? before : after
    }

    /// 只允许photo原始资源进入字节来源；使用真实SHA1Stream按三块读完，network参数由产品硬编码false。
    func read(_ identity: LocalPhotoIdentity, _ resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest {
        guard identity == before.snapshot.identity, resource.descriptor.role == .originalPhoto, resource.format == .image else {
            Issue.record("Live still checksum must never read pairedVideo"); throw LocalPhotoChecksumError.invalidInput
        }
        resources.append(resource)
        return try await LocalPhotoResourceSHA1Stream().read(start: { allowNetwork, receive, complete in
            self.network.append(allowNetwork)
            receive(Data(self.bytes.prefix(19))); receive(Data(self.bytes.dropFirst(19).prefix(31))); receive(Data(self.bytes.dropFirst(50))); complete(nil)
            return 71
        }, cancel: { _ in })
    }
}

/// 远端只开放实际校验和查询和fresh still详情；metadata/视频/上传不存在于允许路径。
private actor StillDisplayRemote: LocalMediaMatchingReading {
    /// 读取事实以Sendable快照返回，避免expect宏跨actor推导。
    struct Reads: Sendable { var metadataCalls = 0; var assetIDs: [UUID] = []; var digests: [LocalPhotoByteDigest] = [] }
    private let owner: UUID
    private(set) var reads = Reads()
    /// owner是当前合成账号，资产校验必须由真实Controller完成。
    init(owner: UUID) {
        self.owner = owner
    }

    /// cloudID全不可用时不得请求元数据；误调用明确记录失败而非返回成功候选。
    func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        reads.metadataCalls += 1; Issue.record("No-cloud Live still must not request metadata stream"); throw CancellationError()
    }

    /// 返回当前账号fresh IMAGE与正确PNG摘要；motion只有link，绝不读取或宣称其配对成功。
    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        guard UUID(uuidString: id) == stillDisplayAssetID else { Issue.record("Still matching must not fetch motion"); throw LibraryWriteError.invalidID }
        reads.assetIDs.append(stillDisplayAssetID)
        return .init(id: stillDisplayAssetID, ownerId: owner, type: "IMAGE", isTrashed: false, isOffline: false, isEdited: false,
                     checksum: "dXJF9wiRoT2hATQFBjrZSNgGWM0=", updatedAt: stillDisplayRevision, livePhotoVideoId: stillDisplayMotionID)
    }

    /// 保留真实nonce并记录真实计算摘要；错误摘要仍会由fresh比较拒绝，不替Controller造成功proof。
    func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        reads.digests += queries.map(\.digest)
        guard queries.count == 1 else { throw LocalPhotoChecksumError.invalidInput }
        return queries.map { .init(id: $0.id, outcome: .existing(stillDisplayAssetID)) }
    }
}

/// 实际PhotoKit image reader的系统端口；UIImage由完整同源PNG解码，只观察current/network/像素和Live身份。
@MainActor private final class StillDisplayImageDriver: LocalPhotoMediaRequesting {
    private let snapshot: LocalPhotoSnapshot
    private let image: UIImage
    private(set) var imageRequests = 0
    private(set) var videoRequests = 0
    private(set) var kinds: [LocalPhotoIdentity.MediaKind] = []
    private(set) var version: PHImageRequestOptionsVersion?
    private(set) var network: Bool?
    private(set) var pixels: MediaPixelSize?
    /// snapshot仅公开合成元数据；image是真实UIKit解码结果，不使用PHLivePhoto或视频伪对象。
    init(snapshot: LocalPhotoSnapshot, image: UIImage) {
        self.snapshot = snapshot; self.image = image
    }

    /// 当前授权和版本保持稳定，读取过程仍由真实image reader前后对比。
    func observation(for id: String) -> LocalPhotoMediaObservation? {
        guard id == snapshot.identity.localIdentifier else { return nil }
        return .init(identity: snapshot.identity, access: .full, adjustmentTime: nil, hasAdjustments: false, pixelWidth: 3, pixelHeight: 2, duration: 0, mediaSubtypes: snapshot.mediaSubtypes)
    }

    /// 接收真实options与选择的Live still identity；同步完整image回调仍通过产品真实continuation gate。
    func requestImage(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, options: PHImageRequestOptions,
                      result: @escaping @Sendable (LocalPhotoImageDelivery) -> Void) -> LocalPhotoMediaRequest?
    {
        imageRequests += 1; kinds.append(expected.mediaKind); version = options.version; network = options.isNetworkAccessAllowed; pixels = targetPixels
        result(.init(image: image, degraded: false, failed: false)); return .init(identifier: 91, cancel: {})
    }

    /// Live still显示绝不能误入普通video对象读取。
    func requestPlayerItem(for _: LocalPhotoIdentity, options _: PHVideoRequestOptions, result _: @escaping @Sendable (AVPlayerItem?) -> Void) -> LocalPhotoMediaRequest? {
        videoRequests += 1; Issue.record("Live still display must not request player item"); return nil
    }
}

/// Nuke所有潜在远端媒体加载仅记录并同步失败，绝不转发网络。
private final nonisolated class StillDisplayNoMedia: DataLoading, Sendable {
    private let values = Mutex<[URLRequest]>([])
    /// 当前真实请求事实，不从预期路由反推计数。
    var requests: [URLRequest] {
        values.withLock { $0 }
    }

    /// 记录任何意外fallback；成功case必须保持此入口零调用。
    func loadData(with request: URLRequest, didReceiveData _: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        values.withLock { $0.append(request) }; completion(URLError(.unsupportedURL)); return StillDisplayCancellation()
    }
}

/// 同步失败的数据源没有底层任务。
private nonisolated struct StillDisplayCancellation: Cancellable {
    /// 无网络/Photos副作用。
    func cancel() {}
}

/// 仅在本例头像URLSession安装；拦截一切请求并失败，不能漏到.invalid域名网络。
private final nonisolated class StillDisplayProfileProtocol: URLProtocol, @unchecked Sendable {
    /// 所有URL都截住，不按host匹配后转发。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 不修改产品请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 不提供真实头像/账号数据。
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    /// 同步失败无后续callback。
    override func stopLoading() {}
}

/// 空导出依赖保证此读取链无法写Photos、上传、导出或复用备份回执。
private actor StillDisplayNoExports: MediaPhotosWriting {
    /// 无导出权限请求。
    func authorize() async throws {
        throw CancellationError()
    }

    /// 不创建相簿。
    func album(savedID _: String?) async throws -> String {
        throw CancellationError()
    }

    /// 不伪造motion配对验证。
    func validateLivePhoto(still _: URL, motion _: URL) async throws {
        throw CancellationError()
    }

    /// 不保存或上传原片。
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    /// 没有导出回执。
    func verifiedKeys(_: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: [])
    }

    /// 没有Saved Photos原片字节可复用。
    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        nil
    }

    /// 没有导出视频可复用。
    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        nil
    }
}
