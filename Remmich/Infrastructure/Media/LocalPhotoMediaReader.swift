import AVFoundation
import Foundation
import Photos
import UIKit

/// 本机current媒体展示边界；nil仅表示当前本机不可读，取消或调用方代际错误必须抛出，不能触发旧账户回源。
@MainActor protocol LocalPhotoMediaReading: Sendable {
    /// 仅由当前选中图片的详情页触发，可从iCloud取原图；不供网格预取或备份匹配使用。
    func original(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    /// 仅核对当前授权/源版本，不读取图片或联网；nil表示不能安全复用展示缓存。
    func thumbnailSourceVersion(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) throws -> String?
    /// expected来自已验证关联，targetPixels为当前界面请求像素；validateContext在读取前后验证账户/页面发布权。
    func image(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize,
               validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    func thumbnail(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize,
                   validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    /// 仅普通video身份可返回current播放项；LivePhoto motion不能伪装成独立video或原片备份证明。
    func playerItem(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> AVPlayerItem?
}

extension LocalPhotoMediaReading {
    func original(for _: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> UIImage? {
        try Task.checkCancellation(); try validateContext()
        return nil
    }

    func thumbnailSourceVersion(for _: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) throws -> String? {
        try Task.checkCancellation(); try validateContext()
        return nil
    }

    func thumbnail(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize,
                   validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    {
        try await image(for: expected, targetPixels: targetPixels, validateContext: validateContext)
    }
}

/// 只比较当前可访问的公开Photos观察；补充编辑时间/尺寸，防止媒体请求期间的同对象变化被发布。
nonisolated struct LocalPhotoMediaObservation: Equatable, Sendable {
    /// 保留授权范围变化；full切换limited时即使对象仍存在，也重新走调用方关联判断。
    enum Access: Equatable, Sendable { case full, limited }
    let identity: LocalPhotoIdentity
    let access: Access
    let adjustmentTime: Date?
    let hasAdjustments: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let mediaSubtypes: UInt
}

/// PhotoKit异步回调的窄值边界；degraded只能占位，failed/cancelled不得被提升为成功本机图像。
nonisolated struct LocalPhotoImageDelivery: Sendable {
    let image: UIImage?
    let degraded: Bool
    let failed: Bool
}

/// 实际PhotoKit请求身份及线程安全取消动作；不包含URL、原片导出或任何下载许可。
nonisolated struct LocalPhotoMediaRequest: Sendable {
    let identifier: PHImageRequestID
    let cancel: @Sendable () -> Void
}

/// 隔离系统读取点以测试真实reader时序；默认实现只使用公开PhotoKit，options由reader构造并禁止网络。
@MainActor protocol LocalPhotoMediaRequesting: Sendable {
    /// localIdentifier是当前设备Photos身份；返回当前公开观察，权限不足或对象消失返回nil。
    func observation(for localIdentifier: String) -> LocalPhotoMediaObservation?
    /// expected限定当前源版本，targetPixels为界面像素，options禁止网络；任意线程多次result由上层gate收束，nil表示未启动。
    func requestImage(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, options: PHImageRequestOptions,
                      result: @escaping @Sendable (LocalPhotoImageDelivery) -> Void) -> LocalPhotoMediaRequest?
    /// expected仅普通video，options限定current/本机；result可在任意线程迟到，nil句柄表示未启动系统请求。
    func requestPlayerItem(for expected: LocalPhotoIdentity, options: PHVideoRequestOptions,
                           result: @escaping @Sendable (AVPlayerItem?) -> Void) -> LocalPhotoMediaRequest?
}

/// current本机图片/视频读取编排；复用已有PhotoResourceRead的RequestID安装/取消/一次完成机制，不改变Saved Photos语义。
@MainActor struct PhotoKitLocalPhotoMediaReader: LocalPhotoMediaReading {
    private let driver: any LocalPhotoMediaRequesting
    private let timeout: Duration

    /// driver默认真实PhotoKit，timeout限制本机等待时间；超时取消实际请求后返回nil供当前调用方正常回源。
    init(driver: any LocalPhotoMediaRequesting = PhotoKitLocalPhotoMediaDriver(), timeout: Duration = .seconds(4)) {
        self.driver = driver
        self.timeout = max(.milliseconds(1), timeout)
    }

    /// 目标像素沿用调用方界面规格；不请求original数据，不将degraded回调或失效源版本作为最终图像。
    func image(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize,
               validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    {
        try await readImage(for: expected, targetPixels: targetPixels, acceptsDegraded: false, validateContext: validateContext)
    }

    func thumbnail(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize,
                   validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    {
        try await readImage(for: expected, targetPixels: targetPixels, acceptsDegraded: true, validateContext: validateContext)
    }

    func original(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> UIImage? {
        try await readImage(for: expected, targetPixels: .init(width: 4096, height: 4096), acceptsDegraded: false,
                            original: true, validateContext: validateContext)
    }

    func thumbnailSourceVersion(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) throws -> String? {
        try checkContext(validateContext)
        guard let value = currentObservation(expected) else { return nil }
        try checkContext(validateContext)
        return "\(expected.localIdentifier)|\(expected.modificationDate!.timeIntervalSinceReferenceDate)|\(value.adjustmentTime?.timeIntervalSinceReferenceDate ?? -1)|\(value.hasAdjustments)|\(value.pixelWidth)x\(value.pixelHeight)|\(value.duration)|\(value.mediaSubtypes)|\(value.access)"
    }

    private func readImage(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, acceptsDegraded: Bool, original: Bool = false,
                           validateContext: @MainActor () throws -> Void) async throws -> UIImage?
    {
        try checkContext(validateContext)
        guard targetPixels.width > 0, targetPixels.height > 0 else { return nil }
        let observation = currentObservation(expected)
        try checkContext(validateContext)
        guard let before = observation else { return nil }
        let read = PhotoResourceRead<UIImage>()
        let timer = deadline(read, duration: original ? .seconds(20) : nil)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try checkContext(validateContext)
            // gate先安装continuation，再接收可能同步到达的结果；ID返回之前的取消由install补发。
            let value: UIImage? = await withCheckedContinuation { continuation in
                read.begin(continuation)
                guard !Task.isCancelled else { read.cancel(); return }
                let options = PHImageRequestOptions()
                options.version = original ? .original : .current
                options.deliveryMode = acceptsDegraded ? .opportunistic : .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = original
                let request = driver.requestImage(for: expected, targetPixels: targetPixels, options: options) { delivery in
                    if delivery.failed {
                        read.finish(nil)
                    } else if !delivery.degraded || (acceptsDegraded && delivery.image != nil) {
                        read.finish(delivery.image)
                    }
                }
                if let request {
                    read.install(request.cancel)
                } else {
                    read.finish(nil)
                }
            }
            try checkContext(validateContext)
            // 成功或miss都重新观察源；账户失效必须抛错，不能变成nil触发旧账户远端回源。
            let after = currentObservation(expected)
            try checkContext(validateContext)
            guard after == before else { return nil }
            return value
        } onCancel: { read.cancel() }
    }

    /// 视频current表示可包含Photos组合/编辑，直接返回AVPlayerItem；非video/未知版本/本机不可用只返回nil。
    func playerItem(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> AVPlayerItem? {
        try checkContext(validateContext)
        guard expected.mediaKind == .video else { return nil }
        let observation = currentObservation(expected)
        try checkContext(validateContext)
        guard let before = observation else { return nil }
        let read = PhotoResourceRead<AVPlayerItem>()
        let timer = deadline(read)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try checkContext(validateContext)
            // 与图片共用已存在的线程安全gate，避免迟到视频回调重复恢复或漏取消真实请求。
            let value: AVPlayerItem? = await withCheckedContinuation { continuation in
                read.begin(continuation)
                guard !Task.isCancelled else { read.cancel(); return }
                let options = PHVideoRequestOptions()
                options.version = .current
                options.isNetworkAccessAllowed = false
                let request = driver.requestPlayerItem(for: expected, options: options) { read.finish($0) }
                if let request {
                    read.install(request.cancel)
                } else {
                    read.finish(nil)
                }
            }
            try checkContext(validateContext)
            let after = currentObservation(expected)
            try checkContext(validateContext)
            guard after == before else { return nil }
            return value
        } onCancel: { read.cancel() }
    }

    /// expected必须有已知修改版本；身份/权限/版本不可验证时不猜测本机内容可替代Immich显示。
    private func currentObservation(_ expected: LocalPhotoIdentity) -> LocalPhotoMediaObservation? {
        guard !expected.localIdentifier.isEmpty, expected.modificationDate != nil,
              let observed = driver.observation(for: expected.localIdentifier), observed.identity == expected else { return nil }
        return observed
    }

    /// read为单个实际请求gate；系统无最终回调时有界取消，取消计时Task不影响已返回的媒体对象。
    private func deadline(_ read: PhotoResourceRead<some Sendable>, duration: Duration? = nil) -> Task<Void, Never> {
        let duration = duration ?? timeout
        return Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            read.cancel()
        }
    }

    /// validate仅检查调用方发布代际；Task取消另行抛出，不能把用户退出误当本机miss再开始远端请求。
    private func checkContext(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
    }
}

/// 真实公开PhotoKit请求适配；读取当前授权对象，禁止资源导出、私有KVC或把LivePhoto当普通视频。
@MainActor struct PhotoKitLocalPhotoMediaDriver: LocalPhotoMediaRequesting {
    /// localIdentifier限定当前设备；权限不足/对象消失不弹框、不请求文件，返回nil供远端显示回退。
    func observation(for localIdentifier: String) -> LocalPhotoMediaObservation? {
        guard let access = access(), let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let identity = identity(asset), let after = self.access(), after == access else { return nil }
        return .init(identity: identity, access: access, adjustmentTime: asset.adjustmentTimestamp, hasAdjustments: asset.hasAdjustments,
                     pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration, mediaSubtypes: asset.mediaSubtypes.rawValue)
    }

    /// options由真实reader固定current/network=false；result只接收图片/质量状态，不发布原始PhotoKit错误正文。
    func requestImage(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, options: PHImageRequestOptions,
                      result: @escaping @Sendable (LocalPhotoImageDelivery) -> Void) -> LocalPhotoMediaRequest?
    {
        guard let asset = asset(expected),
              (options.version == .current && !options.isNetworkAccessAllowed)
              || (options.version == .original && options.isNetworkAccessAllowed) else { return nil }
        let manager = PHImageManager.default()
        let size = options.version == .original ? PHImageManagerMaximumSize : CGSize(width: targetPixels.width, height: targetPixels.height)
        let id = manager.requestImage(for: asset, targetSize: size,
                                      contentMode: .aspectFit, options: options)
        { @Sendable image, info in
            let failed = (info?[PHImageCancelledKey] as? Bool == true) || info?[PHImageErrorKey] != nil
            result(.init(image: failed ? nil : image, degraded: info?[PHImageResultIsDegradedKey] as? Bool == true, failed: failed))
        }
        return .init(identifier: id, cancel: { manager.cancelImageRequest(id) })
    }

    /// 仅当前普通video生成播放项；Photos可能返回AVComposition，调用方不得强制转换为AVURLAsset。
    func requestPlayerItem(for expected: LocalPhotoIdentity, options: PHVideoRequestOptions,
                           result: @escaping @Sendable (AVPlayerItem?) -> Void) -> LocalPhotoMediaRequest?
    {
        guard expected.mediaKind == .video, let asset = asset(expected), options.version == .current, !options.isNetworkAccessAllowed else { return nil }
        let manager = PHImageManager.default()
        let id = manager.requestPlayerItem(forVideo: asset, options: options) { @Sendable item, info in
            let failed = (info?[PHImageCancelledKey] as? Bool == true) || info?[PHImageErrorKey] != nil
            result(failed ? nil : item)
        }
        return .init(identifier: id, cancel: { manager.cancelImageRequest(id) })
    }

    /// expected是匹配时已观察版本；在真正系统媒体调用前再次验证授权与本机身份，不使用旧PHAsset实例。
    private func asset(_ expected: LocalPhotoIdentity) -> PHAsset? {
        guard access() != nil, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [expected.localIdentifier], options: nil).firstObject,
              identity(asset) == expected, access() != nil else { return nil }
        return asset
    }

    /// asset是当前公开对象；非图片/视频不构造身份，LivePhoto明确保留独立kind以阻止错误视频入口。
    private func identity(_ asset: PHAsset) -> LocalPhotoIdentity? {
        guard asset.mediaType == .image || asset.mediaType == .video else { return nil }
        let kind: LocalPhotoIdentity.MediaKind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .image
        return .init(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate, mediaKind: kind)
    }

    /// 只接受系统已有授权；不在图片/视频加载期间触发权限提示或启用网络下载。
    private func access() -> LocalPhotoMediaObservation.Access? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        default: nil
        }
    }
}
