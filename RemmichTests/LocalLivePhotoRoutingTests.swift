import AVFoundation
import CryptoKit
import Foundation
import Nuke
import Photos
import Synchronization
import Testing
@testable import Remmich

/// 真实Media入口→fresh pair→本机proof→native请求；恢复资料是真实原子JSON，替身不伪造可播放PHLivePhoto。
@Suite("Local Live Photo routing")
@MainActor struct LocalLivePhotoRoutingTests {
    /// 一份公开PhotoKit真实重建lease顺序覆盖成功及最终版本/摘要改变；不创建伪PHLivePhoto或触碰系统图库。
    @Test(.timeLimit(.minutes(2)))
    func genuineNativeObjectRequiresStableFinalPair() async throws {
        let native = try await SyntheticLivePhotoFixture.make()
        defer { try? native.close() }
        let source = try liveRoutingSource(native: native)
        let stillBytes = try Data(contentsOf: native.stillURL)
        let motionBytes = try Data(contentsOf: native.motionURL)
        #expect(native.stillDigest.sha1Base64 != native.motionDigest.sha1Base64)
        #expect(native.motionDigest.byteCount == Int64(motionBytes.count) && native.stillDigest.byteCount == Int64(stillBytes.count))
        #expect(native.stillDigest.sha1Base64 == Data(Insecure.SHA1.hash(data: stillBytes)).base64EncodedString())
        #expect(native.motionDigest.sha1Base64 == Data(Insecure.SHA1.hash(data: motionBytes)).base64EncodedString())
        let changes: [String?] = [nil, "version", "checksum"]
        for change in changes {
            let fixture = try await liveRoutingFixture(nativeFixture: native, finalPairChange: change)
            defer { fixture.close() }
            let result = try await fixture.read()
            let requests = await fixture.remote.requests
            #expect(requests == [liveRoutingStillID, liveRoutingMotionID, liveRoutingStillID, liveRoutingMotionID])
            #expect(fixture.reader.calls == ["proof", "native"] && fixture.loader.requests.isEmpty)
            #expect(fixture.reader.expectedSource == source.snapshot.withCloudIdentity(.unavailable))
            let origin = fixture.media.mediaReadOrigin(assetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision)
            if change == nil {
                #expect(result === native.native && origin == .devicePhotos)
            } else {
                #expect(result == nil && origin == nil)
            }
        }
        try native.close()
    }

    /// 完整同源motion摘要才允许native请求；这里native明确nil，只证明路由/像素与零媒体请求，不冒称播放成功。
    @Test func verifiedMotionReachesNativeReaderWithoutRemoteMedia() async throws {
        let fixture = try await liveRoutingFixture(); defer { fixture.close() }
        let result = try await fixture.read()
        #expect(result == nil && fixture.reader.calls == ["proof", "native"])
        #expect(fixture.reader.pixels == MediaPixelSize(width: 4096, height: 3000))
        #expect(fixture.reader.expectedSource == liveRoutingSource().snapshot.withCloudIdentity(.unavailable))
        let requests = await fixture.remote.requests
        #expect(requests == [liveRoutingStillID, liveRoutingMotionID])
        #expect(fixture.loader.requests.isEmpty && fixture.media.mediaReadOrigin(assetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision) == nil)
    }

    /// fresh安全字段/配对任一不明都不能进入本机字节读取；证明实际helper门禁，不只调用纯model再断言。
    @Test(arguments: ["link", "missing-link", "still-revision", "still-checksum", "motion-owner", "motion-type", "trash", "offline", "edited",
                      "unknown-trash", "unknown-offline", "unknown-edited", "bad-checksum", "missing-revision"])
    func invalidFreshPairsNeverReadLocalMovie(_ mode: String) async throws {
        let fixture = try await liveRoutingFixture(pairMode: mode); defer { fixture.close() }
        let result = try await fixture.read()
        #expect(result == nil && fixture.reader.calls.isEmpty && fixture.loader.requests.isEmpty)
        let requests = await fixture.remote.requests
        #expect(requests == [liveRoutingStillID, liveRoutingMotionID])
    }

    /// 空proof、不同SHA1或不同本机版本/身份不能因为still已关联就读取动态对象。
    @Test(arguments: ["nil", "hash", "version", "identity"])
    func unrelatedProofCannotStartNativePreparation(_ mode: String) async throws {
        let fixture = try await liveRoutingFixture(proofMode: mode); defer { fixture.close() }
        let result = try await fixture.read()
        #expect(result == nil && fixture.reader.calls == ["proof"] && fixture.loader.requests.isEmpty)
        #expect(fixture.media.mediaReadOrigin(assetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision) == nil)
    }

    /// 旧远端版本、无效motion ID或普通图片关联都直接miss，不能利用已恢复字典越过Live身份限制。
    @Test(arguments: ["revision", "motion-id", "ordinary-photo"])
    func unsupportedRequestsDoNotStartAnyRead(_ mode: String) async throws {
        let fixture = try await liveRoutingFixture(ordinaryPhoto: mode == "ordinary-photo"); defer { fixture.close() }
        let result = try await fixture.media.localLivePhoto(stillAssetID: liveRoutingStillID.uuidString,
                                                            revision: mode == "revision" ? liveRoutingRevision.addingTimeInterval(0.001) : liveRoutingRevision,
                                                            motionAssetID: mode == "motion-id" ? "invalid" : liveRoutingMotionID.uuidString, targetPixels: .init(width: 100, height: 100))
        let requests = await fixture.remote.requests
        #expect(result == nil && requests.isEmpty && fixture.reader.calls.isEmpty && fixture.loader.requests.isEmpty)
    }

    /// fresh详情网络/解析失败是本机miss，helper不得擅自发motion下载或给出设备来源标签。
    @Test(arguments: [1, 2])
    func freshReadFailuresAllowCallerFallbackWithoutDoingIt(_ step: Int) async throws {
        let fixture = try await liveRoutingFixture(failureAt: step); defer { fixture.close() }
        let result = try await fixture.read()
        let requests = await fixture.remote.requests
        #expect(result == nil && requests.count == step && fixture.reader.calls.isEmpty && fixture.loader.requests.isEmpty)
    }

    /// reader普通错误可返回nil；proof/native错误都不允许内部回源，来源仍保持未选中。
    @Test(arguments: ["proof", "native"])
    func localReadFailureDoesNotRequestRemoteMedia(_ stage: String) async throws {
        let fixture = try await liveRoutingFixture(readerFailure: stage); defer { fixture.close() }
        let result = try await fixture.read()
        #expect(result == nil && fixture.reader.calls == (stage == "proof" ? ["proof"] : ["proof", "native"]))
        #expect(fixture.loader.requests.isEmpty && fixture.media.mediaReadOrigin(assetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision) == nil)
    }

    /// 已取消Task即使尚未查关联也必须抛取消，不能用nil让旧准备路径继续下载motion。
    @Test func preCancelledRequestDoesNotTouchRemoteOrPhotos() async throws {
        let fixture = try await liveRoutingFixture(); defer { fixture.close() }
        let operation = Task { try await fixture.read() }; operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let requests = await fixture.remote.requests
        #expect(requests.isEmpty && fixture.reader.calls.isEmpty && fixture.loader.requests.isEmpty)
    }

    /// 每一个真实await都可跨过停止/换号/换端点或权限撤销；迟到DTO/proof/native miss仍由真实helper重新检查。
    @Test(arguments: ["still", "motion", "proof", "native"], ["cancel", "account", "route", "disabled", "permission"])
    func retiredAwaitCannotAdvanceOrPublish(_ stage: String, _ mode: String) async throws {
        let fixture = try await liveRoutingFixture(holdStage: stage); defer { fixture.close() }
        let operation = Task { try await fixture.read() }
        do {
            try await waitUntil { fixture.gate.entered }
            if mode == "cancel" {
                operation.cancel()
            } else if mode == "account" {
                let next = liveRoutingSession(owner: UUID().uuidString)
                fixture.media.configure(session: next, activeEndpoint: nil)
            } else if mode == "route" {
                try fixture.media.updateRoute(#require(URL(string: "https://live-next.invalid/prefix/api")))
            } else if mode == "disabled" {
                let disable = try #require(fixture.matches.setEnabled(false, using: fixture.media.management)); await disable.value
            } else {
                fixture.inventory.authorization = .denied
            }
            fixture.gate.release()
            if mode == "disabled" || mode == "permission" {
                let value = try await operation.value; #expect(value == nil)
            } else {
                await #expect(throws: CancellationError.self) { try await operation.value }
            }
            let requests = await fixture.remote.requests
            #expect(requests.count == (stage == "still" ? 1 : 2) && fixture.loader.requests.isEmpty)
            #expect(fixture.reader.calls == (stage == "proof" ? ["proof"] : stage == "native" ? ["proof", "native"] : []))
        } catch {
            operation.cancel(); fixture.gate.release(); _ = await operation.result; throw error
        }
    }

    /// await以错误而非值迟到时也要先验证上下文；不能将旧账号/端点的失败吞成可回源的nil。
    @Test(arguments: ["account", "route"])
    func retiredFreshFailureIsCancellation(_ mode: String) async throws {
        let fixture = try await liveRoutingFixture(failureAt: 1, holdStage: "still"); defer { fixture.close() }
        let operation = Task { try await fixture.read() }
        do {
            try await waitUntil { fixture.gate.entered }
            if mode == "account" {
                fixture.media.configure(session: liveRoutingSession(owner: UUID().uuidString), activeEndpoint: nil)
            } else {
                try fixture.media.updateRoute(#require(URL(string: "https://live-next.invalid/prefix/api")))
            }
            fixture.gate.release()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(fixture.reader.calls.isEmpty && fixture.loader.requests.isEmpty)
        } catch {
            operation.cancel(); fixture.gate.release(); _ = await operation.result; throw error
        }
    }

    /// Saved Photos有自己既有motion入口，专用远端配对helper不得在其构造器路径访问Photos/网络。
    @Test func savedPhotosModeDoesNotUseRemoteAssociationHelper() async throws {
        let scope = MediaAccountScope(session: liveRoutingSession())
        let media = MediaLibraryController(savedPhotosLibrary: SavedPhotosLibrary(), scope: scope)
        defer { media.clearAll() }
        let value = try await media.localLivePhoto(stillAssetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision,
                                                   motionAssetID: liveRoutingMotionID.uuidString, targetPixels: .init(width: 50, height: 50))
        #expect(value == nil)
    }

    /// condition限定真实异步闸门；失败有界且调用方清理会放行尚未完成的任务。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }; try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Live Photo helper did not enter expected await")
    }
}

private nonisolated let liveRoutingStillID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private nonisolated let liveRoutingMotionID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
private nonisolated let liveRoutingRevision = Date(timeIntervalSince1970: 100.123)

/// 所有媒体和存储依赖均按例隔离；实例URLSession拦截头像，Nuke loader阻止任何意外媒体网络。
@MainActor private final class LiveRoutingFixture {
    let root: URL
    let media: MediaLibraryController
    let matches: LocalMediaMatchController
    let inventory: LiveRoutingInventory
    let remote: LiveRoutingRemote
    let reader: LiveRoutingReader
    let loader: LiveRoutingNoMedia
    let profile: URLSession
    let gate: LiveRoutingGate

    /// 参数只组合真实依赖，不替产品计算配对或回退结论。
    init(root: URL, media: MediaLibraryController, matches: LocalMediaMatchController, inventory: LiveRoutingInventory,
         remote: LiveRoutingRemote, reader: LiveRoutingReader, loader: LiveRoutingNoMedia, profile: URLSession, gate: LiveRoutingGate)
    {
        self.root = root; self.media = media; self.matches = matches; self.inventory = inventory; self.remote = remote
        self.reader = reader; self.loader = loader; self.profile = profile; self.gate = gate
    }

    /// 使用超限像素验证真实helper沿用4096展示上限，调用后仍由产品进行所有fresh/hash/context检查。
    func read() async throws -> PHLivePhoto? {
        try await media.localLivePhoto(stillAssetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision,
                                       motionAssetID: liveRoutingMotionID.uuidString, targetPixels: .init(width: 5000, height: 3000))
    }

    /// 先释放旧await/撤销账号工作，再清理临时恢复目录；没有全局URLProtocol或真实媒体文件。
    func close() {
        gate.release(); media.clearAll(); profile.invalidateAndCancel(); try? FileManager.default.removeItem(at: root)
    }
}

/// 从真实JSON cold恢复确认still映射；管理endpoint初始离线使自动刷新不抢占本例手动fresh序列。
/// nativeFixture非nil时采用其真实资源/摘要/native，finalPairChange只改变第4个fresh motion响应，其余默认场景保持原值。
@MainActor private func liveRoutingFixture(pairMode: String = "valid", proofMode: String = "valid", ordinaryPhoto: Bool = false,
                                           failureAt: Int? = nil, readerFailure: String? = nil, holdStage: String? = nil,
                                           nativeFixture: SyntheticLivePhotoFixture? = nil, finalPairChange: String? = nil) async throws -> LiveRoutingFixture
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRouting-\(UUID())", isDirectory: true)
    let session = liveRoutingSession(); let scope = MediaAccountScope(session: session)
    let source = try nativeFixture.map { try liveRoutingSource(native: $0) } ?? liveRoutingSource()
    let identity = ordinaryPhoto ? LocalPhotoIdentity(localIdentifier: source.snapshot.identity.localIdentifier, modificationDate: source.snapshot.identity.modificationDate, mediaKind: .image) : source.snapshot.identity
    let stillChecksum = nativeFixture?.stillDigest.sha1Base64 ?? Data(repeating: 0xAA, count: 20).base64EncodedString()
    let association = LocalMediaAssociation(remoteID: liveRoutingStillID, remoteRevision: liveRoutingRevision, localIdentity: identity, checksum: stillChecksum, source: .mobileMetadata)
    let store = LocalMediaAssociationStore(directory: root.appendingPathComponent("matches"))
    _ = try await store.save(.init(scope: scope, enabled: true, access: .full, associations: [association]), scope: scope, permit: LocalMediaSavePermit())
    let inventory = LiveRoutingInventory()
    let matches = LocalMediaMatchController(inventory: inventory, metadata: LiveRoutingNoMetadata(), checksum: LiveRoutingNoChecksum(), persistence: store, observeChanges: false)
    let gate = LiveRoutingGate()
    let digest = try nativeFixture?.motionDigest ?? LocalPhotoByteDigest(sha1Hex: "58be777b9bf5f3971870cc8725c828fcfc089cf2", byteCount: 34)
    let remote = LiveRoutingRemote(owner: UUID(uuidString: session.userID)!, stillChecksum: stillChecksum, motionChecksum: digest.sha1Base64,
                                   mode: pairMode, failureAt: failureAt, holdStage: holdStage, gate: gate, finalPairChange: finalPairChange)
    let proofSource = nativeFixture == nil ? liveRoutingSource(proofMode) : source
    let resource = try #require(proofSource.motionResource())
    let proof = try LocalLivePhotoMotionProof(source: proofSource, resource: resource,
                                              digest: proofMode == "hash" ? .init(sha1Hex: String(repeating: "bb", count: 20), byteCount: 34) : digest)
    let reader = LiveRoutingReader(proof: proofMode == "nil" ? nil : proof, failure: readerFailure, holdStage: holdStage, gate: gate, native: nativeFixture?.native)
    let loader = LiveRoutingNoMedia()
    let transfers = LibraryTransferQueue(rootURL: root.appendingPathComponent("transfers"), nativeTasksProvider: { [] }, sessionIdentifier: "io.github.espeonblue.live-unused-\(UUID())")
    let exports = MediaExportController(store: .init(databaseURL: root.appendingPathComponent("unused.sqlite")), photos: LiveRoutingNoExports(), transfers: transfers)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LiveRoutingProfileProtocol.self]
    let profile = URLSession(configuration: configuration)
    let media = MediaLibraryController(imageDataLoader: loader, exports: exports, localMediaMatches: matches, profileImageSession: profile, localLivePhotoReader: reader, remote: remote)
    media.configure(session: session, activeEndpoint: nil)
    let restore = try #require(matches.restoreAndRefresh(using: media.management, scope: scope)); await restore.value
    #expect(matches.association(assetID: liveRoutingStillID.uuidString, revision: liveRoutingRevision) == association)
    return .init(root: root, media: media, matches: matches, inventory: inventory, remote: remote, reader: reader, loader: loader, profile: profile, gate: gate)
}

/// 只有合成账号，真实Remote API被实例注入替代，.invalid域名不会发出真实网络。
private nonisolated func liveRoutingSession(owner: String = UUID().uuidString) -> AccountSession {
    .init(apiURL: URL(string: "https://live-routing.invalid/prefix/api")!, accessToken: "synthetic-live-routing", userID: owner,
          userEmail: "live@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 真实proof构造器可接受的唯一未编辑pair，version/identity模式用于检测helper未按预期关联核验。
private nonisolated func liveRoutingSource(_ mode: String = "valid") -> LocalLivePhotoSource {
    let photo = LocalPhotoChecksumResource(descriptor: .init(type: 1, role: .originalPhoto, originalFilename: "synthetic.heic", uniformTypeIdentifier: "public.heic", pixelWidth: 64, pixelHeight: 48), format: .image)
    let motion = LocalPhotoChecksumResource(descriptor: .init(type: 9, role: .pairedVideo, originalFilename: "synthetic.mov", uniformTypeIdentifier: "com.apple.quicktime-movie", pixelWidth: 64, pixelHeight: 48), format: .video)
    let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: mode == "identity" ? "other-local-live" : "synthetic-local-live",
                                                      modificationDate: Date(timeIntervalSince1970: mode == "version" ? 56 : 55), mediaKind: .livePhoto),
                                      creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
                                      pixelWidth: 64, pixelHeight: 48, duration: 0, mediaSubtypes: PHAssetMediaSubtype.photoLive.rawValue,
                                      resources: [photo.descriptor, motion.descriptor], cloudIdentity: .unavailable)
    return .init(snapshot: snapshot, resources: [photo, motion], access: .full, isLivePlayback: true)
}

/// native是公开文件重建的真实对象lease；描述取实际文件名、文件时间和已独立回读的像素/类型，身份仅是此合成文件UUID。
/// 这里没有PHAsset或系统授权，full只是系统端口的测试观察；产品仍决定真实关联、fresh pair和摘要是否可用。
@MainActor private func liveRoutingSource(native: SyntheticLivePhotoFixture) throws -> LocalLivePhotoSource {
    let photo = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.photo.rawValue, role: .originalPhoto,
                                                             originalFilename: native.stillURL.lastPathComponent, uniformTypeIdentifier: "public.jpeg",
                                                             pixelWidth: native.pixels.width, pixelHeight: native.pixels.height), format: .image)
    let motion = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.pairedVideo.rawValue, role: .pairedVideo,
                                                              originalFilename: native.motionURL.lastPathComponent, uniformTypeIdentifier: "com.apple.quicktime-movie",
                                                              pixelWidth: native.pixels.width, pixelHeight: native.pixels.height), format: .video)
    let photoValues = try native.stillURL.resourceValues(forKeys: [.creationDateKey])
    let motionValues = try native.motionURL.resourceValues(forKeys: [.contentModificationDateKey])
    let created = try #require(photoValues.creationDate)
    let modified = try #require(motionValues.contentModificationDate)
    let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: "file-native-\(native.identifier)", modificationDate: modified, mediaKind: .livePhoto),
                                      creationDate: created, adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
                                      pixelWidth: native.pixels.width, pixelHeight: native.pixels.height, duration: 0,
                                      mediaSubtypes: PHAssetMediaSubtype.photoLive.rawValue, resources: [photo.descriptor, motion.descriptor], cloudIdentity: .unavailable)
    return .init(snapshot: snapshot, resources: [photo, motion], access: .full, isLivePlayback: true)
}

/// 同一个actor宿主下的确定闸门；早释放也记录，cleanup不依赖await一定已安装。
@MainActor private final class LiveRoutingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var released = false
    /// 真正API/reader调用在此挂起，允许测试在旧await期间修改合法上下文。
    func hold() async {
        entered = true; if !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    /// 正常放行和错误cleanup共用，重复调用不再次恢复。
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

/// 唯一授权替身；本例只恢复已有full权限，不能意外弹框或调用系统库。
@MainActor private final class LiveRoutingInventory: LocalPhotoInventoryReading {
    var authorization = LocalPhotoLibraryAccess.full
    /// 自动恢复不得主动请求权限。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        Issue.record("Unexpected Photos authorization"); return authorization
    }

    /// 路由变化可能触发空清单自动刷新；无真实Photos ID进入任何读取器。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return []
    }
}

/// 本例依赖冷恢复关联，任何全库metadata读取都是额外工作；没有系统Photos调用。
@MainActor private struct LiveRoutingNoMetadata: LocalPhotoMetadataReading {
    /// 空清单不应到此，不构造额外关联。
    func snapshots(for _: [String], validateContext _: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        Issue.record("Unexpected metadata scan"); return []
    }
}

/// 普通静态/视频hash读取不属于专用Live motion helper。
@MainActor private struct LiveRoutingNoChecksum: LocalPhotoChecksumReading {
    /// 专用Live reader由本例独立提供，普通hash调用明确失败。
    func checksum(for _: LocalPhotoSnapshot, validateContext _: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        Issue.record("Unexpected ordinary checksum"); return .insufficient(.unsupportedMedia)
    }
}

/// actor提供fresh详情值和受控旧响应，不替产品判断pair是否安全，没有媒体或写入接口。
private actor LiveRoutingRemote: LocalMediaMatchingReading {
    private let owner: UUID
    private let stillChecksum: String
    private let motionChecksum: String
    private let mode: String
    private let failureAt: Int?
    private let holdStage: String?
    private let gate: LiveRoutingGate
    private let finalPairChange: String?
    private(set) var requests: [UUID] = []
    /// owner/两个checksum为本例账号与摘要；mode选择fresh字段，failureAt为失败序号，holdStage/gate控制挂起。
    /// finalPairChange仅在第4次fresh回读改变motion版本或用真实still摘要替换motion摘要，不修改前阶段响应。
    init(owner: UUID, stillChecksum: String, motionChecksum: String, mode: String, failureAt: Int?, holdStage: String?, gate: LiveRoutingGate,
         finalPairChange: String? = nil)
    {
        self.owner = owner; self.stillChecksum = stillChecksum; self.motionChecksum = motionChecksum; self.mode = mode
        self.failureAt = failureAt; self.holdStage = holdStage; self.gate = gate
        self.finalPairChange = finalPairChange
    }

    /// 只返回所请求UUID详情；即使取消/换号也故意交出迟到结果，由真实Media helper拒绝。
    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        guard let id = UUID(uuidString: id) else { throw LibraryWriteError.invalidID }
        requests.append(id)
        let index = requests.count
        if holdStage == "still" && index == 1 || holdStage == "motion" && index == 2 {
            await gate.hold()
        }
        if failureAt == index {
            throw URLError(.notConnectedToInternet)
        }
        if id == liveRoutingStillID {
            return .init(id: id, ownerId: owner, type: "IMAGE", isTrashed: false, isOffline: false, isEdited: false,
                         checksum: mode == "still-checksum" ? Data(repeating: 0xCC, count: 20).base64EncodedString() : stillChecksum,
                         updatedAt: mode == "still-revision" ? liveRoutingRevision.addingTimeInterval(0.001) : liveRoutingRevision,
                         livePhotoVideoId: mode == "missing-link" ? nil : mode == "link" ? UUID() : liveRoutingMotionID)
        }
        return .init(id: id, ownerId: mode == "motion-owner" ? UUID() : owner, type: mode == "motion-type" ? "IMAGE" : "VIDEO",
                     isTrashed: mode == "unknown-trash" ? nil : mode == "trash", isOffline: mode == "unknown-offline" ? nil : mode == "offline",
                     isEdited: mode == "unknown-edited" ? nil : mode == "edited",
                     checksum: mode == "bad-checksum" ? "invalid" : index == 4 && finalPairChange == "checksum" ? stillChecksum : motionChecksum,
                     updatedAt: mode == "missing-revision" ? nil : Date(timeIntervalSince1970: index == 4 && finalPairChange == "version" ? 201 : 200))
    }

    /// 本例metadata由真实恢复资料供给，不允许意外发全库同步。
    func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        Issue.record("Unexpected metadata stream"); return []
    }

    /// helper验证的movie摘要不走查重/上传；只对指定fresh motion比较。
    func lookupLocalMediaChecksums(_: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        Issue.record("Unexpected checksum lookup"); return []
    }
}

/// 专用reader仅替换系统PH读取；proof使用真实policy构造，native默认nil，可接收公开文件重建的真实对象。
@MainActor private final class LiveRoutingReader: LocalLivePhotoMediaReading {
    private let proof: LocalLivePhotoMotionProof?
    private let failure: String?
    private let holdStage: String?
    private let gate: LiveRoutingGate
    private let native: PHLivePhoto?
    private(set) var calls: [String] = []
    private(set) var pixels: MediaPixelSize?
    private(set) var expectedSource: LocalPhotoSnapshot?
    /// proof可能故意不匹配，reader不替helper提前过滤；native仅来自真实fixture，不构造PHLivePhoto()假对象。
    init(proof: LocalLivePhotoMotionProof?, failure: String?, holdStage: String?, gate: LiveRoutingGate, native: PHLivePhoto? = nil) {
        self.proof = proof; self.failure = failure; self.holdStage = holdStage; self.gate = gate
        self.native = native
    }

    /// 先检查调用方发布权，再允许旧proof迟到；产品必须在await后重验关联。
    func motionProof(for _: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> LocalLivePhotoMotionProof? {
        try validateContext(); calls.append("proof")
        if holdStage == "proof" {
            await gate.hold()
        }
        if failure == "proof" {
            throw URLError(.cannotDecodeContentData)
        }
        return proof
    }

    /// 记录实际native入口目标像素及proof来源；返回给定真实对象或nil，不自行验证pair或宣称系统已播放。
    func livePhoto(for _: LocalPhotoIdentity, targetPixels: MediaPixelSize, matching expectedSource: LocalPhotoSnapshot?,
                   validateContext: @MainActor () throws -> Void) async throws -> PHLivePhoto?
    {
        try validateContext(); calls.append("native"); pixels = targetPixels; self.expectedSource = expectedSource
        if holdStage == "native" {
            await gate.hold()
        }
        if failure == "native" {
            throw URLError(.cannotDecodeContentData)
        }
        return native
    }
}

/// Nuke如果被意外调用，只记录并失败；全实例隔离，不允许向外转发媒体请求。
private final nonisolated class LiveRoutingNoMedia: DataLoading, Sendable {
    private let values = Mutex<[URLRequest]>([])
    /// 返回线程安全请求事实，用于确认helper没有执行fallback。
    var requests: [URLRequest] {
        values.withLock { $0 }
    }

    /// request必须是产品真正发来的值，不修补或生成响应媒体。
    func loadData(with request: URLRequest, didReceiveData _: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        values.withLock { $0.append(request) }; completion(URLError(.unsupportedURL)); return LiveRoutingCancellation()
    }
}

/// 失败同步完成的数据源没有底层外部任务。
private nonisolated struct LiveRoutingCancellation: Cancellable {
    /// 调用不会操作任何Photos/HTTP状态。
    func cancel() {}
}

/// 按实例封闭头像URLSession；任何URL都在本地失败，不安装全局拦截器或访问真实凭据。
private final nonisolated class LiveRoutingProfileProtocol: URLProtocol, @unchecked Sendable {
    /// 所有请求都拦截，不能因URL拼错泄漏到网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留产品请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 本例不依赖头像内容，立即终止且不回传真实账号资料。
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    /// 同步失败无延迟任务需要收尾。
    override func stopLoading() {}
}

/// 导出/Photos写入完全隔离；没有回执或本地原片能被helper误复用。
private actor LiveRoutingNoExports: MediaPhotosWriting {
    /// 浏览不申请导出权限。
    func authorize() async throws {
        throw CancellationError()
    }

    /// 不创建相簿。
    func album(savedID _: String?) async throws -> String {
        throw CancellationError()
    }

    /// 不伪造导出配对验证。
    func validateLivePhoto(still _: URL, motion _: URL) async throws {
        throw CancellationError()
    }

    /// 不保存、上传或导出任何媒体。
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    /// 没有导出回执，返回空事实。
    func verifiedKeys(_: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: [])
    }

    /// 没有Saved Photos原片数据可用。
    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        nil
    }

    /// 没有原片视频可复用。
    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        nil
    }
}
