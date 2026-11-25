import Foundation
import Photos
import Synchronization
import Testing
@testable import Remmich

/// 专用Live policy及真实reader/gate/SHA1流；系统边界合成，不伪造不存在的PHLivePhoto正例。
@Suite("Local Live Photo current media")
@MainActor struct LocalLivePhotoMediaReaderTests {
    /// 未编辑唯一photo+pairedVideo可产生本机motion证明，摘要由真实流对合成块计算而非fixture直接指定。
    @Test func motionProofHashesCompleteLocalMovieWithoutExport() async throws {
        let before = liveSource()
        let driver = LiveReadDriver(sources: [before, before])
        let result = try await PhotoKitLocalLivePhotoMediaReader(driver: driver).motionProof(for: before.snapshot.identity, validateContext: {})
        let proof = try #require(result)
        #expect(proof.source == before.snapshot.withCloudIdentity(.unavailable) && proof.resource.role == .pairedVideo)
        #expect(proof.digest.sha1Hex == "58be777b9bf5f3971870cc8725c828fcfc089cf2" && proof.digest.byteCount == 34)
        #expect(driver.digestRequests == 1 && driver.nativeRequests == 0 && driver.digestNetwork == false && driver.cancellations.ids.isEmpty)
    }

    /// first cut不猜已编辑/复合/RAW/current关闭或未知版本；两个公开入口均不得触发任何字节或native请求。
    @Test(arguments: ["image", "video", "unknown-version", "bad-version", "empty-id", "edited", "timestamp", "photo-only", "duplicate-motion", "extra",
                      "adjusted-resource", "raw", "bad-uti", "playback", "pixels", "duration", "descriptor-mismatch"])
    func unsupportedSourcesCannotRequestMedia(_ mode: String) async throws {
        let source = liveSource(mode)
        #expect(source.motionResource() == nil)
        let driver = LiveReadDriver(sources: [source, source])
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let proof = try await reader.motionProof(for: source.snapshot.identity, validateContext: {})
        let native = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
        #expect(proof == nil && native == nil && driver.digestRequests == 0 && driver.nativeRequests == 0)
    }

    /// policy只允许选中的pairedVideo进入proof；仅拿到同源photo摘要也不能冒充motion。
    @Test func proofConstructorRejectsUnselectedResource() throws {
        let source = liveSource()
        let digest = try LocalPhotoByteDigest(sha1Hex: "58be777b9bf5f3971870cc8725c828fcfc089cf2", byteCount: 34)
        let photo = try #require(source.resources.first)
        #expect(throws: LocalPhotoChecksumError.invalidInput) { try LocalLivePhotoMotionProof(source: source, resource: photo, digest: digest) }
    }

    /// 完整motion证明完成后，即使identity/modDate相同，资源或创建时间/位置变化也不能进入native请求。
    @Test(arguments: ["other-resource", "new-created", "new-location"])
    func sourceChangeBetweenProofAndNativeNeverStartsRequest(_ mode: String) async throws {
        let before = liveSource(); let changed = liveSource(mode)
        #expect(before.snapshot.identity == changed.snapshot.identity && changed.motionResource() != nil)
        let driver = LiveReadDriver(sources: [before, before, changed])
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let result = try await reader.motionProof(for: before.snapshot.identity, validateContext: {})
        let proof = try #require(result)
        let native = try await reader.livePhoto(for: before.snapshot.identity, targetPixels: .init(width: 64, height: 48), matching: proof.source, validateContext: {})
        #expect(native == nil && driver.digestRequests == 1 && driver.nativeRequests == 0 && driver.sourceReads == 3)
    }

    /// 相同完整proof来源允许进入真实native适配边界；系统替身仍返回nil，仅证明门禁/参数而不冒充PHLivePhoto成功。
    @Test func exactProofSourceAllowsNativeRequest() async throws {
        let source = liveSource()
        let driver = LiveReadDriver(sources: [source, source, source, source])
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let result = try await reader.motionProof(for: source.snapshot.identity, validateContext: {})
        let proof = try #require(result)
        let native = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), matching: proof.source, validateContext: {})
        #expect(native == nil && driver.digestRequests == 1 && driver.nativeRequests == 1 && driver.sourceReads == 4)
    }

    /// 字节读取期间版本、权限、资源或当前编辑变化都丢弃真实已算摘要，不能只看同一个本机ID。
    @Test(arguments: ["missing", "version", "limited", "edited", "resource"])
    func changedSourcesDoNotPublishMotionProof(_ mode: String) async throws {
        let source = liveSource()
        let after = mode == "missing" ? nil : liveSource(mode == "version" ? "next-version" : mode == "resource" ? "other-resource" : mode)
        let driver = LiveReadDriver(sources: [source, after])
        let result = try await PhotoKitLocalLivePhotoMediaReader(driver: driver).motionProof(for: source.snapshot.identity, validateContext: {})
        #expect(result == nil && driver.digestRequests == 1 && driver.sourceReads == 2)
    }

    /// 完整资源不存在/云上-only/失败/空数据都没有可用proof；网络选项保持false，不将不足转换为匹配成功。
    @Test(arguments: ["nil", "cloud-only", "failed", "empty"])
    func unavailableMovieNeverCreatesPartialProof(_ mode: String) async throws {
        let source = liveSource()
        let driver = LiveReadDriver(sources: [source, source])
        driver.digestMode = mode
        let result = try await PhotoKitLocalLivePhotoMediaReader(driver: driver).motionProof(for: source.snapshot.identity, validateContext: {})
        #expect(result == nil && driver.digestRequests == 1 && driver.nativeRequests == 0)
        if mode != "nil" {
            #expect(driver.digestNetwork == false)
        }
    }

    /// native路径使用真实PHLivePhotoRequestOptions的current/highQuality/network=false及目标像素；nil仅证明miss/选项，不声称可播。
    @Test(arguments: ["nil", "failed", "missing-handle"])
    func nativeRequestUsesPublicLocalOnlyOptions(_ mode: String) async throws {
        let source = liveSource()
        let driver = LiveReadDriver(sources: [source, source])
        driver.nativeMode = mode
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let pixels = MediaPixelSize(width: 900, height: 700)
        let result = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: pixels, validateContext: {})
        #expect(result == nil && driver.nativeRequests == 1 && driver.digestRequests == 0 && driver.sourceReads == 2)
        #expect(driver.nativeVersion == .current && driver.nativeQuality == .highQualityFormat && driver.nativeNetwork == false && driver.pixels == pixels)
    }

    /// 只有degraded的回调不算最终结果；20ms测试deadline取消真实nativeID，迟到回调不能再次取消/完成。
    @Test func degradedNativeTimesOutAndCancelsActualRequest() async throws {
        let source = liveSource()
        let driver = LiveReadDriver(sources: [source, source]); driver.nativeMode = "degraded"
        let result = try await PhotoKitLocalLivePhotoMediaReader(driver: driver, timeout: .milliseconds(20))
            .livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
        #expect(result == nil && driver.cancellations.ids == [51] && !Task.isCancelled)
        driver.finishNative(failed: false); driver.finishNative(failed: true)
        #expect(driver.cancellations.ids == [51])
    }

    /// Task已取消时完全不触Photos观察；不能把取消当成nil交给旧账户继续回源。
    @Test(arguments: [false, true])
    func preCancelledCallsNeverTouchDriver(_ native: Bool) async {
        let source = liveSource(); let driver = LiveReadDriver(sources: [])
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let operation = Task {
            if native {
                _ = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
            } else {
                _ = try await reader.motionProof(for: source.snapshot.identity, validateContext: {})
            }
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(driver.sourceReads == 0 && driver.digestRequests == 0 && driver.nativeRequests == 0)
    }

    /// 资源ID/nativeID尚未返回就取消，真实现有gate安装后仍补发准确取消，迟到失败不二次完成。
    @Test(arguments: [false, true])
    func cancellationBeforeIDInstallationStillCancelsActualID(_ native: Bool) async {
        let source = liveSource(); let driver = LiveReadDriver(sources: [source])
        let control = LiveReadControl(); driver.onStart = { control.cancel?() }
        driver.digestMode = "held"; driver.nativeMode = "held"
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let operation = Task {
            if native {
                _ = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
            } else {
                _ = try await reader.motionProof(for: source.snapshot.identity, validateContext: {})
            }
        }
        control.cancel = { operation.cancel() }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(driver.cancellations.ids == [native ? 51 : 31])
        driver.finishDigest(); driver.finishNative(failed: true)
        #expect(driver.cancellations.ids == [native ? 51 : 31])
    }

    /// 正在进行的真实gate被Task取消后，不交摘要/PH对象，也不等系统迟到回调才返回。
    @Test(arguments: [false, true])
    func runningCancellationStopsBothKinds(_ native: Bool) async throws {
        let source = liveSource(); let driver = LiveReadDriver(sources: [source])
        driver.digestMode = "held"; driver.nativeMode = "held"
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        let operation = Task {
            if native {
                _ = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
            } else {
                _ = try await reader.motionProof(for: source.snapshot.identity, validateContext: {})
            }
        }
        do {
            try await waitUntil { driver.digestRequests + driver.nativeRequests == 1 }
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(driver.cancellations.ids == [native ? 51 : 31])
            driver.finishDigest(); driver.finishNative(failed: false)
        } catch {
            operation.cancel(); driver.finishDigest(); driver.finishNative(failed: true); _ = await operation.result; throw error
        }
    }

    /// 账号在await/回调期间被撤销，完整SHA1或native miss都必须抛出发布权错误，而不能进入远端fallback。
    @Test(arguments: [false, true])
    func revokedContextCannotReturnProofOrNativeMiss(_ native: Bool) async {
        let source = liveSource(); let driver = LiveReadDriver(sources: [source])
        let control = LiveReadControl(); driver.onStart = { control.active = false }
        let reader = PhotoKitLocalLivePhotoMediaReader(driver: driver)
        await #expect(throws: LocalMediaMetadataError.sourceChanged) {
            if native {
                _ = try await reader.livePhoto(for: source.snapshot.identity, targetPixels: .init(width: 64, height: 48), validateContext: control.validate)
            } else {
                _ = try await reader.motionProof(for: source.snapshot.identity, validateContext: control.validate)
            }
        }
        #expect(driver.sourceReads == 1)
    }

    /// condition只等待真实reader开始请求，失败有界且调用者会取消/释放实际gate。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Live Photo request did not start")
    }
}

/// mode只控制公开资源形态；所有名字/ID/时间与位置均为合成，不读系统照片库。
private nonisolated func liveSource(_ mode: String = "valid") -> LocalLivePhotoSource {
    let photo = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.photo.rawValue, role: .originalPhoto, originalFilename: "synthetic.heic",
                                                             uniformTypeIdentifier: "public.heic", pixelWidth: 64, pixelHeight: 48), format: mode == "raw" ? .raw : .image)
    let motion = LocalPhotoChecksumResource(descriptor: .init(type: mode == "adjusted-resource" ? PHAssetResourceType.fullSizePairedVideo.rawValue : PHAssetResourceType.pairedVideo.rawValue,
                                                              role: mode == "adjusted-resource" ? .adjusted : .pairedVideo,
                                                              originalFilename: mode == "other-resource" ? "changed.mov" : "synthetic.mov", uniformTypeIdentifier: "com.apple.quicktime-movie", pixelWidth: 64, pixelHeight: 48),
                                            format: mode == "bad-uti" ? .unsupported : .video)
    var resources = [photo, motion]
    if mode == "photo-only" {
        resources = [photo]
    } else if mode == "duplicate-motion" {
        resources.append(motion)
    } else if mode == "extra" {
        resources.append(.init(descriptor: .init(type: 99, role: .other, originalFilename: "extra", uniformTypeIdentifier: "public.data", pixelWidth: 0, pixelHeight: 0), format: .unsupported))
    }
    let version: Date? = mode == "unknown-version" ? nil : Date(timeIntervalSince1970: mode == "bad-version" ? .nan : mode == "next-version" ? 16 : 15)
    let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: mode == "empty-id" ? "" : "synthetic-live", modificationDate: version,
                                                      mediaKind: mode == "image" ? .image : mode == "video" ? .video : .livePhoto),
                                      creationDate: Date(timeIntervalSince1970: mode == "new-created" ? 11 : 10), adjustmentTime: mode == "timestamp" ? Date(timeIntervalSince1970: 20) : nil,
                                      hasAdjustments: mode == "edited", latitude: mode == "new-location" ? 1 : nil, longitude: mode == "new-location" ? 2 : nil, pixelWidth: mode == "pixels" ? 0 : 64, pixelHeight: 48,
                                      duration: mode == "duration" ? .nan : 0, mediaSubtypes: PHAssetMediaSubtype.photoLive.rawValue,
                                      resources: mode == "descriptor-mismatch" ? [] : resources.map(\.descriptor), cloudIdentity: .unavailable)
    return .init(snapshot: snapshot, resources: resources, access: mode == "limited" ? .limited : .full, isLivePlayback: mode != "playback")
}

/// 任意callback线程的实际取消ID日志；不在fixture里过滤重复，便于检测产品重复取消。
private final nonisolated class LiveReadCancellations: Sendable {
    private let values = Mutex<[Int32]>([])
    /// 有限取消序列的线程安全快照。
    var ids: [Int32] {
        values.withLock { $0 }
    }

    /// id为实际reader安装的资源31/native51，重复原样保留。
    func append(_ id: Int32) {
        values.withLock { $0.append(id) }
    }
}

/// 只替换公开PhotoKit传输点，真实policy/完整SHA1流/gate/超时与所有前后校验保持产品实现。
@MainActor private final class LiveReadDriver: LocalLivePhotoRequesting {
    private var sources: [LocalLivePhotoSource?]
    var digestMode = "complete"
    var nativeMode = "nil"
    var onStart: (@MainActor () -> Void)?
    let cancellations = LiveReadCancellations()
    private(set) var sourceReads = 0
    private(set) var digestRequests = 0
    private(set) var nativeRequests = 0
    private(set) var digestNetwork: Bool?
    private(set) var nativeVersion: PHImageRequestOptionsVersion?
    private(set) var nativeQuality: PHImageRequestOptionsDeliveryMode?
    private(set) var nativeNetwork: Bool?
    private(set) var pixels: MediaPixelSize?
    private var digestComplete: (@Sendable ((any Error)?) -> Void)?
    private var nativeResult: (@Sendable (LocalLivePhotoDelivery) -> Void)?

    /// sources按实际前后读取提供；空项明确表示权限/对象已不可见。
    init(sources: [LocalLivePhotoSource?]) {
        self.sources = sources
    }

    /// 只返回下一份观察，判断仍由真实reader执行，不在fixture中推导成功。
    func source(for _: String) -> LocalLivePhotoSource? {
        sourceReads += 1; return sources.isEmpty ? nil : sources.removeFirst()
    }

    /// 本机movie块全部合成；真实SHA1Stream处理同步完成、ID安装/取消与错误，不直接返回假摘要。
    func motionDigest(for _: LocalLivePhotoSource, resource _: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest? {
        digestRequests += 1
        if digestMode == "nil" {
            return nil
        }
        let log = cancellations
        return try await LocalPhotoResourceSHA1Stream().read(start: { network, receive, complete in
            self.digestNetwork = network; self.digestComplete = complete; self.onStart?()
            if self.digestMode == "cloud-only" {
                complete(LocalPhotoChecksumError.networkRequired)
            } else if self.digestMode == "failed" {
                complete(LocalPhotoChecksumError.readFailed)
            } else if self.digestMode == "empty" {
                complete(nil)
            } else {
                let bytes = Data("synthetic local Live Photo motion\n".utf8)
                receive(Data(bytes.prefix(7)))
                if self.digestMode != "held" {
                    receive(Data(bytes.dropFirst(7))); complete(nil)
                }
            }
            return 31
        }, cancel: { log.append($0) })
    }

    /// 接收真实options；只发nil/失败/降质状态，没有PHLivePhoto()或unsafe替身伪造原生成功。
    func requestLivePhoto(for _: LocalLivePhotoSource, targetPixels: MediaPixelSize, options: PHLivePhotoRequestOptions,
                          result: @escaping @Sendable (LocalLivePhotoDelivery) -> Void) -> LocalPhotoMediaRequest?
    {
        nativeRequests += 1; nativeVersion = options.version; nativeQuality = options.deliveryMode; nativeNetwork = options.isNetworkAccessAllowed; pixels = targetPixels
        guard nativeMode != "missing-handle" else { return nil }
        nativeResult = result; onStart?()
        if nativeMode == "degraded" {
            result(.init(livePhoto: nil, degraded: true, failed: false))
        } else if nativeMode != "held" {
            result(.init(livePhoto: nil, degraded: false, failed: nativeMode == "failed"))
        }
        let log = cancellations
        return .init(identifier: 51, cancel: { log.append(51) })
    }

    /// 迟到资源完成不能替产品过滤；真实流已取消时必须忽略，而不是生成部分proof。
    func finishDigest() {
        digestComplete?(nil)
    }

    /// 迟到native状态只能通过产品gate，failed由场景决定。
    func finishNative(failed: Bool) {
        nativeResult?(.init(livePhoto: nil, degraded: false, failed: failed))
    }
}

/// 代表调用方已有的账户代际；取消句柄只在ID安装时序测试内使用。
@MainActor private final class LiveReadControl {
    var active = true
    var cancel: (() -> Void)?
    /// 无发布权时抛原始错误，reader不能将其转成普通本机miss。
    func validate() throws {
        if !active {
            throw LocalMediaMetadataError.sourceChanged
        }
    }
}
