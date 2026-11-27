import AVFoundation
import Foundation
import Photos
import Synchronization
import Testing
import UIKit
@testable import Remmich

/// 真实本机媒体adapter编排：只有系统请求点为合成驱动，真实gate/取消/超时/账号与版本校验均执行。
@Suite("Local current photo and video reads")
@MainActor struct LocalPhotoMediaReaderTests {
    /// 图片、视频poster和LivePhoto still都用明确current、允许Photos从iCloud读取的目标像素请求；多回调只接受第一个完整结果。
    @Test(arguments: ["image", "video", "live"])
    func currentImagesUsePhotosCloudOptionsAndIgnoreDegraded(_ kind: String) async throws {
        let identity = localReadIdentity(kind == "video" ? .video : kind == "live" ? .livePhoto : .image)
        let driver = LocalReadDriver(observations: [localReadObservation(identity), localReadObservation(identity)])
        let expected = syntheticLocalImage()
        driver.imageReplies = [.init(image: syntheticLocalImage(), degraded: true, failed: false),
                               .init(image: expected, degraded: false, failed: false), .init(image: nil, degraded: false, failed: true)]
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        let pixels = MediaPixelSize(width: 320, height: 240)
        let value = try await reader.image(for: identity, targetPixels: pixels, validateContext: {})
        #expect(value === expected)
        #expect(driver.imageRequests == 1 && driver.videoRequests == 0)
        #expect(driver.imageVersion == .current && driver.imageNetwork == true && driver.pixels == pixels)
        #expect(driver.cancellations.ids.isEmpty)
    }

    /// 普通视频返回Photos的播放项，保留组合/编辑表示；不要求原片URL或真实磁盘文件。
    @Test func currentVideoReturnsPhotosCloudPlayerItem() async throws {
        let identity = localReadIdentity(.video)
        let driver = LocalReadDriver(observations: [localReadObservation(identity), localReadObservation(identity)])
        let expected = AVPlayerItem(asset: AVMutableComposition())
        driver.videoReplies = [expected, nil]
        let value = try await PhotoKitLocalPhotoMediaReader(driver: driver).playerItem(for: identity, validateContext: {})
        #expect(value === expected && driver.videoRequests == 1 && driver.imageRequests == 0)
        #expect(driver.videoVersion == .current && driver.videoNetwork == true)
        #expect(driver.cancellations.ids.isEmpty)
    }

    /// 同一已编辑current版本可以直接显示，不把Photos本地调整误判为必须请求原片或一律远端读取。
    @Test func unchangedPhotosAdjustmentsRemainReadable() async throws {
        let identity = localReadIdentity()
        let observation = localReadObservation(identity, edited: true)
        let driver = LocalReadDriver(observations: [observation, observation])
        let expected = syntheticLocalImage()
        driver.imageReplies = [.init(image: expected, degraded: false, failed: false)]
        let actual = try await PhotoKitLocalPhotoMediaReader(driver: driver).image(for: identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
        #expect(actual === expected && driver.imageVersion == .current)
    }

    /// 只读关联的LivePhoto是image对象；其motion不能从普通video入口请求或冒充视频成功。
    @Test(arguments: [LocalPhotoIdentity.MediaKind.image, .livePhoto])
    func nonVideosNeverStartPlayerRequests(_ kind: LocalPhotoIdentity.MediaKind) async throws {
        let driver = LocalReadDriver(observations: [])
        let value = try await PhotoKitLocalPhotoMediaReader(driver: driver).playerItem(for: localReadIdentity(kind), validateContext: {})
        #expect(value == nil && driver.videoRequests == 0 && driver.observationReads == 0)
    }

    /// 未知expected版本/权限失效/源版本不等只返回nil，没有系统媒体请求；本机不可用不制造账号错误。
    @Test(arguments: ["unknown-version", "permission"])
    func unavailableSourcesNeverStartMediaRequests(_ mode: String) async throws {
        let expected = localReadIdentity()
        let request = mode == "unknown-version" ? LocalPhotoIdentity(localIdentifier: expected.localIdentifier, modificationDate: nil, mediaKind: .image) : expected
        let observation = mode == "changed-version" ? localReadObservation(localReadIdentity(modification: 16)) : localReadObservation(expected)
        let driver = LocalReadDriver(observations: mode == "permission" ? [nil] : [observation])
        let value = try await PhotoKitLocalPhotoMediaReader(driver: driver).image(for: request, targetPixels: .init(width: 10, height: 10), validateContext: {})
        #expect(value == nil && driver.imageRequests == 0)
    }

    /// 关联建立后的Photos编辑以当前版本展示，不因旧修改时间回退到Immich。
    @Test func newerPhotosVersionRemainsAuthoritative() async throws {
        let expected = localReadIdentity()
        let current = localReadIdentity(modification: 16)
        let observation = localReadObservation(current, edited: true)
        let driver = LocalReadDriver(observations: [observation, observation])
        let image = syntheticLocalImage()
        driver.imageReplies = [.init(image: image, degraded: false, failed: false)]
        let result = try await PhotoKitLocalPhotoMediaReader(driver: driver).thumbnail(for: expected, targetPixels: .init(width: 128, height: 128), validateContext: {})
        #expect(result === image && driver.imageNetwork == true)
    }

    /// 请求期间授权范围/对象/修改/编辑变化都不能发布已过期的UIImage，不能只看原请求ID。
    @Test(arguments: ["missing", "version", "kind", "permission", "edit", "pixels"], [false, true])
    func changedPostReadObservationReturnsNil(_ mode: String, _ video: Bool) async throws {
        let identity = localReadIdentity(video ? .video : .image)
        let before = localReadObservation(identity)
        let after = mode == "version" ? localReadObservation(localReadIdentity(identity.mediaKind, modification: 16))
            : mode == "kind" ? localReadObservation(localReadIdentity(video ? .image : .video))
            : localReadObservation(identity, limited: mode == "permission", edited: mode == "edit", width: mode == "pixels" ? 128 : 64)
        let driver = LocalReadDriver(observations: [before, mode == "missing" ? nil : after])
        driver.imageReplies = [.init(image: syntheticLocalImage(), degraded: false, failed: false)]
        driver.videoReplies = [AVPlayerItem(asset: AVMutableComposition())]
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        if video {
            let value = try await reader.playerItem(for: identity, validateContext: {})
            #expect(value == nil && driver.videoRequests == 1)
        } else {
            let value = try await reader.image(for: identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
            #expect(value == nil && driver.imageRequests == 1)
        }
    }

    /// 两次fetch之间对象可能消失而无法启动系统请求；图片/视频都应明确miss，不悬挂continuation或捏造取消ID。
    @Test(arguments: [false, true])
    func missingNativeRequestHandleReturnsNil(_ video: Bool) async throws {
        let identity = localReadIdentity(video ? .video : .image)
        let observation = localReadObservation(identity)
        let driver = LocalReadDriver(observations: [observation, observation])
        driver.startRequests = false
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        if video {
            let value = try await reader.playerItem(for: identity, validateContext: {}); #expect(value == nil)
        } else {
            let value = try await reader.image(for: identity, targetPixels: .init(width: 10, height: 10), validateContext: {}); #expect(value == nil)
        }
        #expect(driver.cancellations.ids.isEmpty)
    }

    /// 云上-only/系统错误不是本机成功；降质标记也不能覆盖终止失败而永久等待或被当作完整图像。
    @Test(arguments: ["cloud-only", "failed", "failed-degraded"])
    func unavailableFinalImageReturnsNil(_ mode: String) async throws {
        let identity = localReadIdentity()
        let driver = LocalReadDriver(observations: [localReadObservation(identity), localReadObservation(identity)])
        driver.imageReplies = [.init(image: nil, degraded: mode == "failed-degraded", failed: mode != "cloud-only")]
        let value = try await PhotoKitLocalPhotoMediaReader(driver: driver).image(for: identity, targetPixels: .init(width: 64, height: 48), validateContext: {})
        #expect(value == nil && driver.imageNetwork == true)
    }

    /// 已取消Task在任何Photos读取前抛出，不能返回nil让旧请求继续访问Immich。
    @Test func cancelledBeforeStartDoesNotTouchPhotoKitDriver() async {
        let driver = LocalReadDriver(observations: [])
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        let operation = Task { try await reader.image(for: localReadIdentity(), targetPixels: .init(width: 1, height: 1), validateContext: {}) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(driver.observationReads == 0 && driver.imageRequests == 0)
    }

    /// 在系统调用尚未返回ID的窗口取消，安装后仍准确取消真实ID；迟到完整/错误回调都不能二次完成。
    @Test func cancellationBeforeRequestIDInstallationCancelsReturnedID() async {
        let identity = localReadIdentity()
        let driver = LocalReadDriver(observations: [localReadObservation(identity)])
        let control = LocalReadControl()
        driver.onImageStart = { control.cancel?() }
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        let operation = Task { try await reader.image(for: identity, targetPixels: .init(width: 10, height: 10), validateContext: {}) }
        control.cancel = { operation.cancel() }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(driver.cancellations.ids == [41])
        driver.deliverImage(.init(image: syntheticLocalImage(), degraded: false, failed: false))
        driver.deliverImage(.init(image: nil, degraded: false, failed: true))
        #expect(driver.cancellations.ids == [41])
    }

    /// 正在运行的图片或视频请求被取消时取消对应ID，真正Task错误向上传播；读取后的旧回调不得发布。
    @Test(arguments: [false, true])
    func runningRequestsCancelRealIdentifier(_ video: Bool) async throws {
        let identity = localReadIdentity(video ? .video : .image)
        let driver = LocalReadDriver(observations: [localReadObservation(identity)])
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        let operation = Task {
            if video {
                _ = try await reader.playerItem(for: identity, validateContext: {})
            } else {
                _ = try await reader.image(for: identity, targetPixels: .init(width: 10, height: 10), validateContext: {})
            }
        }
        do {
            try await waitUntil { driver.imageRequests + driver.videoRequests == 1 }
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(driver.cancellations.ids == [video ? 42 : 41])
            driver.deliverImage(.init(image: syntheticLocalImage(), degraded: false, failed: false))
            driver.deliverVideo(AVPlayerItem(asset: AVMutableComposition()))
        } catch {
            operation.cancel(); _ = await operation.result; throw error
        }
    }

    /// 图片只有降质结果或视频没有终止回调时，有界超时取消真实请求并返回nil，不启用网络或无限挂住查看器。
    @Test(arguments: [false, true])
    func timeoutCancelsUnavailableReadAndAllowsRemoteFallback(_ video: Bool) async throws {
        let identity = localReadIdentity(video ? .video : .image)
        let driver = LocalReadDriver(observations: [localReadObservation(identity), localReadObservation(identity)])
        driver.imageReplies = [.init(image: syntheticLocalImage(), degraded: true, failed: false)]
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver, timeout: .milliseconds(20))
        if video {
            let value = try await reader.playerItem(for: identity, validateContext: {})
            #expect(value == nil)
        } else {
            let value = try await reader.image(for: identity, targetPixels: .init(width: 10, height: 10), validateContext: {})
            #expect(value == nil)
        }
        #expect(!Task.isCancelled && driver.cancellations.ids == [video ? 42 : 41])
    }

    /// 请求await期间撤销账号，回调虽有图片也必须抛出调用方错误，不能返回nil让旧账户远端回源。
    @Test func revokedAccountCannotPublishOrTriggerFallback() async throws {
        let identity = localReadIdentity()
        let driver = LocalReadDriver(observations: [localReadObservation(identity)])
        let control = LocalReadControl()
        let reader = PhotoKitLocalPhotoMediaReader(driver: driver)
        let operation = Task { try await reader.image(for: identity, targetPixels: .init(width: 10, height: 10), validateContext: control.validate) }
        do {
            try await waitUntil { driver.imageRequests == 1 }
            control.active = false
            driver.deliverImage(.init(image: syntheticLocalImage(), degraded: false, failed: false))
            await #expect(throws: LocalMediaMetadataError.sourceChanged) { try await operation.value }
            #expect(driver.observationReads == 1)
        } catch {
            operation.cancel(); _ = await operation.result; throw error
        }
    }

    /// condition只等待真实adapter开始请求；有界观察避免固定sleep猜测回调已安装。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Local PhotoKit request did not start")
    }
}

/// 合成版本/种类与像素均不包含真实照片身份；modification单位为Unix秒。
private nonisolated func localReadIdentity(_ kind: LocalPhotoIdentity.MediaKind = .image, modification: TimeInterval = 15) -> LocalPhotoIdentity {
    .init(localIdentifier: "synthetic-local-media", modificationDate: Date(timeIntervalSince1970: modification), mediaKind: kind)
}

/// identity为目标版本；limited/edited/width控制读取后独立观察，不替换产品比较逻辑。
private nonisolated func localReadObservation(_ identity: LocalPhotoIdentity, limited: Bool = false, edited: Bool = false, width: Int = 64) -> LocalPhotoMediaObservation {
    .init(identity: identity, access: limited ? .limited : .full, adjustmentTime: edited ? Date(timeIntervalSince1970: 20) : nil,
          hasAdjustments: edited, pixelWidth: width, pixelHeight: 48, duration: identity.mediaKind == .video ? 2 : 0, mediaSubtypes: 0)
}

/// 生成2像素颜色块作为UIKit结果，不读磁盘、账户、PhotoKit或网络。
@MainActor private func syntheticLocalImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

/// cancel来自任意线程；Mutex只保护有限实际ID记录，不把取消变成异步模拟。
private final nonisolated class LocalReadCancellations: Sendable {
    private let values = Mutex<[PHImageRequestID]>([])
    /// 返回线程安全快照，顺序和重复均保留以检测漏取消/重复取消。
    var ids: [PHImageRequestID] {
        values.withLock { $0 }
    }

    /// id为真实reader收到的合成系统ID；任意取消线程均同步记入有限数组。
    func append(_ id: PHImageRequestID) {
        values.withLock { $0.append(id) }
    }
}

/// 只替换PHImageManager及授权元数据读点，真实reader构造Photos options并负责全部gate/状态/取消。
@MainActor private final class LocalReadDriver: LocalPhotoMediaRequesting {
    private var observations: [LocalPhotoMediaObservation?]
    var imageReplies: [LocalPhotoImageDelivery] = []
    var videoReplies: [AVPlayerItem?] = []
    var startRequests = true
    var onImageStart: (@MainActor () -> Void)?
    let cancellations = LocalReadCancellations()
    private(set) var imageRequests = 0
    private(set) var videoRequests = 0
    private(set) var observationReads = 0
    private(set) var imageVersion: PHImageRequestOptionsVersion?
    private(set) var imageNetwork: Bool?
    private(set) var pixels: MediaPixelSize?
    private(set) var videoVersion: PHVideoRequestOptionsVersion?
    private(set) var videoNetwork: Bool?
    private var imageResult: (@Sendable (LocalPhotoImageDelivery) -> Void)?
    private var videoResult: (@Sendable (AVPlayerItem?) -> Void)?

    /// observations按真实前后读取次序提供，缺项也有意返回nil。
    init(observations: [LocalPhotoMediaObservation?]) {
        self.observations = observations
    }

    /// 返回下一份独立观察并记录读取次数，不在fixture内推导产品应当成功还是失败。
    func observation(for _: String) -> LocalPhotoMediaObservation? {
        observationReads += 1
        return observations.isEmpty ? nil : observations.removeFirst()
    }

    /// 接收真实构造的options，先发脚本回调再返回ID以覆盖同步/ID安装前取消窗口。
    func requestImage(for _: LocalPhotoIdentity, targetPixels: MediaPixelSize, options: PHImageRequestOptions,
                      result: @escaping @Sendable (LocalPhotoImageDelivery) -> Void) -> LocalPhotoMediaRequest?
    {
        imageRequests += 1; imageVersion = options.version; imageNetwork = options.isNetworkAccessAllowed; pixels = targetPixels
        guard startRequests else { return nil }
        imageResult = result; onImageStart?()
        for reply in imageReplies {
            result(reply)
        }
        let log = cancellations
        return .init(identifier: 41, cancel: { log.append(41) })
    }

    /// 只提供空组合AVPlayerItem，不播放实际文件；options与实际取消ID由真实reader接收。
    func requestPlayerItem(for _: LocalPhotoIdentity, options: PHVideoRequestOptions,
                           result: @escaping @Sendable (AVPlayerItem?) -> Void) -> LocalPhotoMediaRequest?
    {
        videoRequests += 1; videoVersion = options.version; videoNetwork = options.isNetworkAccessAllowed; videoResult = result
        guard startRequests else { return nil }
        for reply in videoReplies {
            result(reply)
        }
        let log = cancellations
        return .init(identifier: 42, cancel: { log.append(42) })
    }

    /// delivery为系统迟到或多次图片回调，产品gate负责是否仍能发布。
    func deliverImage(_ delivery: LocalPhotoImageDelivery) {
        imageResult?(delivery)
    }

    /// value为系统迟到视频回调，产品gate负责丢弃而非fixture静默过滤。
    func deliverVideo(_ value: AVPlayerItem?) {
        videoResult?(value)
    }
}

/// 仅表示调用方现有账户代际与取消动作，不引入第二个账户控制器。
@MainActor private final class LocalReadControl {
    var cancel: (() -> Void)?
    var active = true

    /// 失去发布权时抛出明确错误供真实reader传播，不能转化成普通本机miss。
    func validate() throws {
        if !active {
            throw LocalMediaMetadataError.sourceChanged
        }
    }
}
