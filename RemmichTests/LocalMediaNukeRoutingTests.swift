import AVFoundation
import Foundation
import Nuke
import Synchronization
import Testing
import UIKit
@testable import Remmich

/// 真实恢复/匹配Controller→MediaLibraryController→Nuke链；仅替换Photos/远端metadata/字节来源，不复制路由算法。
@Suite("Local media Nuke routing", .serialized)
@MainActor struct LocalMediaNukeRoutingTests {
    /// 三种展示规格都优先当前本机图；已存在的普通远端内存图不能让请求跳过本机关联。
    @Test(arguments: [MediaDerivative.thumbnail, .preview, .fullSize])
    func confirmedLocalImageAvoidsEveryRemoteDataLoad(_ derivative: MediaDerivative) async throws {
        let fixture = try await routingFixture()
        defer { fixture.close() }
        let descriptor = fixture.descriptor(derivative)
        let pipeline = try #require(fixture.media.pipeline)
        let remote = try #require(fixture.media.imageRequest(for: descriptor, useSavedPhotos: false, useLocalPhotos: false))
        pipeline.cache[remote] = ImageContainer(image: fixture.reader.remoteSizedImage)
        let request = try #require(fixture.media.imageRequest(for: descriptor))
        let result = try await pipeline.imageTask(with: request).response
        #expect(result.image.size == CGSize(width: 3, height: 2))
        #expect(request.url == nil && fixture.loader.requests.isEmpty && fixture.reader.imageReads == 1)
        #expect(fixture.media.mediaReadOrigin(assetID: fixture.assetID, revision: routingRevision) == .devicePhotos)
        let limit = derivative == .thumbnail ? 1024 : derivative == .preview ? 2048 : 4096
        #expect(fixture.reader.lastPixels == MediaPixelSize(width: limit, height: min(limit, 3000)))
    }

    /// 真正本机miss进入既有edited展示GET，完整DataLoader请求/鉴权/结果尺寸可观测；不会导出或上传。
    @Test func localMissUsesAuthenticatedRemotePipeline() async throws {
        let fixture = try await routingFixture(localImage: false)
        defer { fixture.close() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.imageTask(with: request).response
        #expect(result.image.size == CGSize(width: 11, height: 7))
        #expect(fixture.reader.imageReads == 1 && fixture.loader.requests.count == 1)
        try routingAssertRemote(fixture.loader.requests, fixture: fixture)
        #expect(fixture.media.mediaReadOrigin(assetID: fixture.assetID, revision: routingRevision) == .immichResource)
    }

    /// wrapper每次仍验证本机，正常远端fallback可以复用已有缓存，不因修复旧local缓存绕过而重复加载远端。
    @Test func repeatedLocalMissKeepsNormalRemoteCache() async throws {
        let fixture = try await routingFixture(localImage: false)
        defer { fixture.close() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
        let pipeline = try #require(fixture.media.pipeline)
        _ = try await pipeline.imageTask(with: request).response
        _ = try await pipeline.imageTask(with: request).response
        #expect(fixture.reader.imageReads == 2 && fixture.loader.requests.count == 1)
    }

    /// 请求已在Photos挂起才取消/换号/换端点；迟到nil不能触发任何旧账号远端回源。
    @Test(arguments: ["cancel", "account", "route"])
    func retiredInFlightLocalReadCannotStartOldFallback(_ mode: String) async throws {
        let fixture = try await routingFixture(localImage: false)
        defer { fixture.close() }
        fixture.reader.holdImage = true
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
        let pipeline = try #require(fixture.media.pipeline)
        let pending = Task { try await pipeline.imageTask(with: request).response }
        let watcher = Task { _ = await pending.result; fixture.reader.gate.finished() }
        guard await fixture.reader.gate.waitForEntry() else { await watcher.value; Issue.record("Actual image reader must reach the gate"); return }
        if mode == "cancel" {
            pending.cancel()
        } else if mode == "account" {
            let next = routingSession(owner: UUID().uuidString, endpoint: fixture.session.apiURL)
            fixture.media.configure(session: next, activeEndpoint: next.apiURL)
        } else {
            let route = try #require(URL(string: "https://route-\(UUID().uuidString.lowercased()).invalid/prefix/api"))
            fixture.media.updateRoute(route)
            let updated = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
            #expect(updated.url == nil && updated.imageID != request.imageID)
        }
        fixture.reader.gate.release(); await fixture.reader.gate.waitForReturn(); await watcher.value
        do { _ = try await pending.value; Issue.record("Retired media request must not publish") }
        catch { /* Nuke将fetch取消映射为其错误类型；关键是实际在途读取后失败且没有fallback请求。 */ }
        #expect(fixture.loader.requests.isEmpty && fixture.reader.imageReads == 1)
    }

    /// 同一个已缓存旧request在关联关闭/授权撤销后重用，真实内存中虽有旧图也不能绕过执行期校验。
    @Test(arguments: ["disabled", "permission"])
    func cachedOldRequestCannotReviveInvalidLocalAssociation(_ mode: String) async throws {
        let fixture = try await routingFixture()
        defer { fixture.close() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
        let pipeline = try #require(fixture.media.pipeline)
        let first = try await pipeline.imageTask(with: request).response
        #expect(first.image.size == CGSize(width: 3, height: 2))
        var memoryProbe = request
        memoryProbe.options.remove(.disableMemoryCacheReads)
        #expect(pipeline.cache[memoryProbe]?.image.size == CGSize(width: 3, height: 2))
        if mode == "disabled" {
            let operation = try #require(fixture.matches.setEnabled(false, using: fixture.media.management)); await operation.value
        } else {
            fixture.inventory.authorization = .denied
        }
        #expect(fixture.matches.association(assetID: fixture.assetID, revision: routingRevision) == nil)
        let second = try await pipeline.imageTask(with: request).response
        #expect(second.image.size == CGSize(width: 11, height: 7))
        #expect(fixture.reader.imageReads == 1 && fixture.loader.requests.count == 1)
        try routingAssertRemote(fixture.loader.requests, fixture: fixture)
    }

    /// 原先构造但尚未执行的request，关联已关闭时不访问旧Photos对象，直接进入当前合法远端通道。
    @Test func deferredRequestChecksAssociationBeforeTouchingPhotos() async throws {
        let fixture = try await routingFixture()
        defer { fixture.close() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor()))
        let operation = try #require(fixture.matches.setEnabled(false, using: fixture.media.management)); await operation.value
        let pipeline = try #require(fixture.media.pipeline)
        let value = try await pipeline.imageTask(with: request).response
        #expect(value.image.size == CGSize(width: 11, height: 7))
        #expect(fixture.reader.imageReads == 0 && fixture.loader.requests.count == 1)
    }

    /// 不匹配远端精确revision的展示请求不能用旧本机关联替代，原片下载同样不进入Photos current路由。
    @Test(arguments: ["revision", "original"])
    func otherVersionsAndOriginalsDoNotUseLocalDisplay(_ mode: String) async throws {
        let fixture = try await routingFixture()
        defer { fixture.close() }
        let descriptor = MediaRequestDescriptor(assetID: fixture.assetID, updatedAt: mode == "revision" ? routingRevision.addingTimeInterval(0.001) : routingRevision,
                                                derivative: mode == "original" ? .original : .preview, targetPixels: nil)
        let request = try #require(fixture.media.imageRequest(for: descriptor, useSavedPhotos: false))
        let pipeline = try #require(fixture.media.pipeline)
        _ = try await pipeline.imageTask(with: request).response
        #expect(fixture.reader.imageReads == 0 && fixture.loader.requests.count == 1)
        #expect(request.url != nil)
    }

    /// 普通视频helper返回实际Photos item并记录设备来源，不创建远端视频/图片字节请求。
    @Test func confirmedLocalVideoReturnsCurrentPlayerItem() async throws {
        let fixture = try await routingFixture(video: true)
        defer { fixture.close() }
        let result = try await fixture.media.localPhotoPlayerItem(assetID: fixture.assetID, revision: routingRevision)
        #expect(result === fixture.reader.video && fixture.reader.videoReads == 1 && fixture.loader.requests.isEmpty)
        #expect(fixture.media.mediaReadOrigin(assetID: fixture.assetID, revision: routingRevision) == .devicePhotos)
    }

    /// 真正prepare选择同一本机item；空组合只证明路由身份，不宣称可播放，音频全部由记录替身承接。
    @Test func realVideoPrepareSelectsMatchedCurrentItemWithoutRemoteBytes() async throws {
        let fixture = try await routingFixture(video: true)
        defer { fixture.close() }
        let audio = RoutingAudioSession()
        let playback = VideoPlaybackSession(assetID: fixture.assetID, revision: routingRevision, audioSession: audio)
        defer { playback.close() }
        await playback.prepare(using: fixture.media, autoplay: false)
        #expect(playback.player.currentItem === fixture.reader.video)
        #expect(fixture.reader.videoReads == 1 && fixture.loader.requests.isEmpty)
        #expect(fixture.media.mediaReadOrigin(assetID: fixture.assetID, revision: routingRevision) == .devicePhotos)
        // 现有startPlayback先activate再检查autoplay；只核对替身调用，不改变或绕过生产音频语义。
        #expect(audio.activations.withLock { $0 } == 1)
    }

    /// 视频helper等待期间取消/换号不能交出旧item，关闭关联则明确miss；都不能由helper发远端请求。
    @Test(arguments: ["cancel", "account", "disabled"])
    func lateVideoHelperCannotPublishRetiredItem(_ mode: String) async throws {
        let fixture = try await routingFixture(video: true)
        defer { fixture.close() }
        fixture.reader.holdVideo = true
        let pending = Task { try await fixture.media.localPhotoPlayerItem(assetID: fixture.assetID, revision: routingRevision) }
        let watcher = Task { _ = await pending.result; fixture.reader.gate.finished() }
        guard await fixture.reader.gate.waitForEntry() else { await watcher.value; Issue.record("Actual player helper must reach the gate"); return }
        if mode == "cancel" {
            pending.cancel()
        } else if mode == "account" {
            let next = routingSession(owner: UUID().uuidString, endpoint: fixture.session.apiURL)
            fixture.media.configure(session: next, activeEndpoint: next.apiURL)
        } else {
            let operation = try #require(fixture.matches.setEnabled(false, using: fixture.media.management)); await operation.value
        }
        fixture.reader.gate.release(); await watcher.value
        if mode == "disabled" {
            #expect(try await pending.value == nil)
        } else {
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
        }
        #expect(fixture.loader.requests.isEmpty && fixture.reader.videoReads == 1)
    }

    /// 无关联时的已取消视频prepare也必须先停止，不能因为local helper返回nil继续构造远端播放器。
    @Test func cancelledVideoPrepareWithoutAssociationDoesNotFallBack() async throws {
        let fixture = try await routingFixture(video: true)
        defer { fixture.close() }
        let disable = try #require(fixture.matches.setEnabled(false, using: fixture.media.management)); await disable.value
        let audio = RoutingAudioSession()
        let playback = VideoPlaybackSession(assetID: fixture.assetID, revision: routingRevision, audioSession: audio)
        defer { playback.close() }
        let pending = Task { await playback.prepare(using: fixture.media, autoplay: false) }
        pending.cancel(); await pending.value
        #expect(playback.player.currentItem == nil && fixture.reader.videoReads == 0 && fixture.loader.requests.isEmpty)
        #expect(audio.activations.withLock { $0 } == 0)
    }
}

private nonisolated let routingRevision = Date(timeIntervalSince1970: 100.123)
private nonisolated let routingAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

/// 每例真实Media/Controller/原子JSON/SQLite依赖均隔离，所有HTTP/Photos来源都只能进入合成适配。
@MainActor private struct RoutingFixture {
    let root: URL
    let media: MediaLibraryController
    let matches: LocalMediaMatchController
    let inventory: RoutingInventory
    let reader: RoutingPhotoReader
    let loader: RoutingDataLoader
    let session: AccountSession
    let profileSession: URLSession
    var assetID: String {
        routingAssetID
    }

    /// derivative限定实际展示请求，像素刻意超限以观察真实Media入口裁限。
    func descriptor(_ derivative: MediaDerivative = .preview) -> MediaRequestDescriptor {
        .init(assetID: assetID, updatedAt: routingRevision, derivative: derivative, targetPixels: .init(width: 5000, height: 3000))
    }

    /// 关闭实际账号/会话，移除本例恢复目录；绝不使用普通用户的export store或全局URLProtocol注册。
    func close() {
        reader.gate.release(); media.clearAll(); profileSession.invalidateAndCancel(); try? FileManager.default.removeItem(at: root)
    }
}

/// localImage/video选择本例系统结果；先真实原子保存并冷恢复，再经过真实Controller fresh验证，而非直接设置私有map。
@MainActor private func routingFixture(localImage: Bool = true, video: Bool = false) async throws -> RoutingFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRouting-\(UUID())", isDirectory: true)
    let endpoint = URL(string: "https://routing-\(UUID().uuidString.lowercased()).invalid/prefix/api")!
    let session = routingSession(owner: UUID().uuidString, endpoint: endpoint)
    let scope = MediaAccountScope(session: session)
    let identity = LocalPhotoIdentity(localIdentifier: "synthetic-local-current", modificationDate: Date(timeIntervalSince1970: 15), mediaKind: video ? .video : .image)
    let snapshot = LocalPhotoSnapshot(identity: identity, creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false,
                                      latitude: nil, longitude: nil, pixelWidth: 64, pixelHeight: 48, duration: video ? 2 : 0, mediaSubtypes: 0,
                                      resources: [.init(type: video ? 2 : 1, role: video ? .originalVideo : .originalPhoto,
                                                        originalFilename: video ? "synthetic.mov" : "synthetic.jpg", uniformTypeIdentifier: video ? "com.apple.quicktime-movie" : "public.jpeg", pixelWidth: 64, pixelHeight: 48)],
                                      cloudIdentity: .resolved("routing:complete-opaque"))
    let assetID = try #require(UUID(uuidString: routingAssetID))
    let ownerID = try #require(UUID(uuidString: session.userID))
    let asset = LocalMediaRemoteAsset(id: assetID, ownerId: ownerID, type: video ? "VIDEO" : "IMAGE",
                                      isTrashed: false, isOffline: false, isEdited: false, checksum: Data(repeating: 0xAA, count: 20).base64EncodedString(), updatedAt: routingRevision)
    let association = try #require(LocalMediaAssociation.verified(remote: asset, requestedID: asset.id, ownerID: session.userID, local: identity, source: .mobileMetadata))
    let store = LocalMediaAssociationStore(directory: root.appendingPathComponent("matches"))
    let saved = try await store.save(.init(scope: scope, enabled: true, access: .full, associations: [association]), scope: scope, permit: LocalMediaSavePermit())
    #expect(saved)
    let inventory = RoutingInventory(id: identity.localIdentifier)
    let remote = RoutingRemote(asset: asset)
    let matches = LocalMediaMatchController(inventory: inventory, metadata: RoutingMetadata(snapshot: snapshot), checksum: RoutingChecksum(),
                                            remote: remote, persistence: store, observeChanges: false)
    let reader = RoutingPhotoReader(localImage: localImage)
    let remotePNG = try #require(reader.remoteSizedImage.pngData())
    let loader = RoutingDataLoader(image: remotePNG)
    let transfers = LibraryTransferQueue(rootURL: root.appendingPathComponent("transfers"), nativeTasksProvider: { [] }, sessionIdentifier: "io.github.espeonblue.routing-unused-\(UUID())")
    let exports = MediaExportController(store: .init(databaseURL: root.appendingPathComponent("unused.sqlite")), photos: RoutingNoExports(), transfers: transfers)
    let profileConfiguration = URLSessionConfiguration.ephemeral
    profileConfiguration.protocolClasses = [RoutingProfileProtocol.self]
    let profileSession = URLSession(configuration: profileConfiguration)
    let media = MediaLibraryController(imageDataLoader: loader, exports: exports, localMediaMatches: matches, localPhotoReader: reader, profileImageSession: profileSession)
    media.configure(session: session, activeEndpoint: endpoint)
    let restore = try #require(matches.restoreAndRefresh(using: media.management, scope: scope)); await restore.value
    #expect(matches.association(assetID: routingAssetID, revision: routingRevision) == association)
    #expect(await remote.calls == ["metadata", "asset"])
    return .init(root: root, media: media, matches: matches, inventory: inventory, reader: reader, loader: loader, session: session, profileSession: profileSession)
}

/// owner/endpoint全部合成，namespace独占；版本与正常根路由保持真实账号形状。
private nonisolated func routingSession(owner: String, endpoint: URL) -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic-routing", userID: owner, userEmail: "routing@example.invalid", name: "Synthetic",
          isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 真正远端fallback请求必须仍是编辑展示路径；检查实际DataLoader收到的请求而非再次调用产品URL构造器。
@MainActor private func routingAssertRemote(_ requests: [URLRequest], fixture: RoutingFixture) throws {
    let request = try #require(requests.first)
    let url = try #require(request.url)
    #expect(requests.count == 1 && request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-routing")
    #expect(url.host == fixture.session.apiURL.host && url.path == "/prefix/api/assets/\(routingAssetID)/thumbnail")
    #expect(url.query == "size=preview&edited=true")
}

/// 当前授权清单完全合成；只允许既有full访问，不在测试触碰系统权限。
@MainActor private final class RoutingInventory: LocalPhotoInventoryReading {
    var authorization = LocalPhotoLibraryAccess.full
    let id: String
    /// id是本例唯一Photos身份。
    init(id: String) {
        self.id = id
    }

    /// 自动恢复不应请求权限，若误入此路径明确记录失败。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        Issue.record("Routing restoration must not request permission"); return authorization
    }

    /// 真实Controller决定分批/取消，本fixture只提供一个公开身份。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return [id]
    }
}

/// 唯一稳定快照提供给真实领域匹配器，不预设Controller中的关联map。
@MainActor private struct RoutingMetadata: LocalPhotoMetadataReading {
    let snapshot: LocalPhotoSnapshot
    /// 仅返回实际请求的当前身份，调用方代际检查照常执行。
    func snapshots(for ids: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext(); return ids.contains(snapshot.identity.localIdentifier) ? [snapshot] : []
    }
}

/// 元数据路径已足够确认，任何哈希读取表示fixture/路由误入额外资源请求。
@MainActor private struct RoutingChecksum: LocalPhotoChecksumReading {
    /// 来源为合成snapshot；不能在测试隐式请求系统原片或凭空制造哈希证明。
    func checksum(for _: LocalPhotoSnapshot, validateContext _: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        Issue.record("Confirmed metadata must not read checksum bytes"); return .insufficient(.notLocallyAvailable)
    }
}

/// metadata/fresh详情只替换只读来源，所有owner/type/revision和恢复发布逻辑仍由真实Controller执行。
private actor RoutingRemote: LocalMediaMatchingReading {
    let asset: LocalMediaRemoteAsset
    private(set) var calls: [String] = []
    /// asset为合成同账号资源，fresh读取逐次记录。
    init(asset: LocalMediaRemoteAsset) {
        self.asset = asset
    }

    /// 完整opaque ID和创建时间与公开本机快照一致。
    func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        calls.append("metadata")
        return [.init(assetID: asset.id, value: Data(#"{"iCloudId":"routing:complete-opaque","createdAt":"1970-01-01T00:00:10Z"}"#.utf8))]
    }

    /// 返回新鲜资源数据，不读取真实client或媒体。
    func localMediaAsset(_: String) async throws -> LocalMediaRemoteAsset {
        calls.append("asset"); return asset
    }

    /// 任何checksum请求都为意外，不把它变成上传或mock成功。
    func lookupLocalMediaChecksums(_: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        Issue.record("Unexpected checksum lookup"); throw CancellationError()
    }
}

/// 模拟原生媒体回调可跨账号迟到；取消遵守真实PhotoReader契约，账号变化则交由真实Media入口复核。
@MainActor private final class RoutingPhotoReader: LocalPhotoMediaReading {
    let local: UIImage
    let remoteSizedImage: UIImage
    let video = AVPlayerItem(asset: AVMutableComposition())
    let returnsImage: Bool
    let gate = RoutingGate()
    var holdImage = false
    var holdVideo = false
    private(set) var imageReads = 0
    private(set) var videoReads = 0
    private(set) var lastPixels: MediaPixelSize?
    /// localImage决定当前本机是否miss，像素颜色/尺寸完全合成，不使用PhotoKit。
    init(localImage: Bool) {
        returnsImage = localImage; local = Self.image(width: 3, height: 2); remoteSizedImage = Self.image(width: 11, height: 7)
    }

    /// 先检查实际调用方context，再有意允许迟到结果，避免fixture替Media提前吞掉旧值。
    func image(for _: LocalPhotoIdentity, targetPixels: MediaPixelSize, validateContext: @MainActor () throws -> Void) async throws -> UIImage? {
        try validateContext(); imageReads += 1; lastPixels = targetPixels
        defer { gate.didReturn() }
        if holdImage {
            await gate.hold()
        }
        try Task.checkCancellation()
        return returnsImage ? local : nil
    }

    /// 返回Photos current形状的空组合item；不会播放文件，迟到值由真实Media helper再次检查。
    func playerItem(for _: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> AVPlayerItem? {
        try validateContext(); videoReads += 1
        if holdVideo {
            await gate.hold()
        }
        return video
    }

    /// 以scale1生成独立可观测尺寸，避免屏幕scale造成期待值与产品实现耦合。
    private static func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format).image { UIColor.red.setFill(); $0.fill(.init(x: 0, y: 0, width: width, height: height)) }
    }
}

/// 真实媒体读取已进入才报告成功；操作若先结束返回false，释放信号可在continuation安装前安全保存。
@MainActor private final class RoutingGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var entered = false
    private var released = false
    private var completed = false
    private var returned = false
    private var returnObserver: CheckedContinuation<Void, Never>?
    /// 对应实际媒体方法调用点，不使用sleep推断已到达。
    func hold() async {
        entered = true; observer?.resume(returning: true); observer = nil; if !released {
            await withCheckedContinuation { pending = $0 }
        }
    }

    /// 提前结束的请求不能假装进入门禁。
    func waitForEntry() async -> Bool {
        if entered {
            return true
        }; if completed {
            return false
        }; return await withCheckedContinuation { observer = $0 }
    }

    /// 操作真正结束时唤醒失败等待者。
    func finished() {
        completed = true; observer?.resume(returning: false); observer = nil
    }

    /// 真实fake reader函数退出才报告，不能只依赖Nuke外层Task提前取消就断言迟到读取已经收尾。
    func didReturn() {
        returned = true; returnObserver?.resume(); returnObserver = nil
    }

    /// 本机gate已进入且显式release后，等待读取函数实际执行到退出路径。
    func waitForReturn() async {
        if !returned {
            await withCheckedContinuation { returnObserver = $0 }
        }
    }

    /// 放行一次真实旧值，同时保护早释放情况。
    func release() {
        released = true; pending?.resume(); pending = nil
    }
}

/// 只响应实际Nuke DataLoading接口；所有字节均本地PNG，任何请求都被计数且不会转发到网络。
private final nonisolated class RoutingDataLoader: DataLoading, @unchecked Sendable {
    private let image: Data
    private let recorded = Mutex<[URLRequest]>([])
    /// image是合成PNG，init没有请求副作用。
    init(image: Data) {
        self.image = image
    }

    /// 并发安全快照，不在测试中预先计算产品是否应回源。
    var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    /// request为真正fallback交给Nuke的请求；返回实际可解码字节和本例取消令牌。
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void, completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        recorded.withLock { $0.append(request) }
        guard let url = request.url else { completion(URLError(.badURL)); return RoutingCancellation() }
        didReceiveData(image, URLResponse(url: url, mimeType: "image/png", expectedContentLength: image.count, textEncodingName: nil)); completion(nil)
        return RoutingCancellation()
    }
}

/// 无延迟网络/后台任务的同步字节来源取消令牌。
private nonisolated struct RoutingCancellation: Cancellable {
    /// 同步数据源已经完成，没有可取消的外部任务。
    func cancel() {}
}

/// 按实例注入给头像URLSession，只有合成profile路径返回404；其余一律失败，不安装全局协议或转发请求。
private final nonisolated class RoutingProfileProtocol: URLProtocol, @unchecked Sendable {
    /// 所有会话请求都截住，错误URL不能泄漏到真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留请求，禁止fixture修正路由。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 原头像机制可正常完成404；没有媒体字节、凭据输出或磁盘profile保存。
    override func startLoading() {
        guard let url = request.url, url.host?.hasSuffix(".invalid") == true, request.httpMethod == "GET", url.path.hasSuffix("/profile-image"),
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self)
    }

    /// 本协议没有延迟工作，取消后也没有其他callback来源。
    override func stopLoading() {}
}

/// 普通媒体入口的导出依赖完全隔离且没有任何回执；误触Photos写入必须失败。
private actor RoutingNoExports: MediaPhotosWriting {
    /// 导出授权不属于浏览验收。
    func authorize() async throws {
        throw CancellationError()
    }

    /// 不创建系统相簿。
    func album(savedID _: String?) async throws -> String {
        throw CancellationError()
    }

    /// 不做真LivePhoto读取或配对。
    func validateLivePhoto(still _: URL, motion _: URL) async throws {
        throw CancellationError()
    }

    /// 永不上传、导出或写Photos。
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    /// 空真实journal没有可校验回执，不访问系统库。
    func verifiedKeys(_: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: [])
    }

    /// 浏览回退没有Saved Photos副本。
    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        nil
    }

    /// 浏览回退没有Saved Photos视频。
    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        nil
    }
}

/// 已取消prepare不应激活真实音频会话，次数仍由真实VideoPlaybackSession调用决定。
private final nonisolated class RoutingAudioSession: ViewerAudioSessionControlling {
    let activations = Mutex(0)
    /// 只记次数，不配置系统音频。
    func activate() async throws {
        activations.withLock { $0 += 1 }
    }

    /// 不触碰全局AVAudioSession。
    func deactivate() {}
}
