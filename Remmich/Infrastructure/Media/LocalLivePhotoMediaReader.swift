import Foundation
import Photos
import UniformTypeIdentifiers

/// 专用本机Live Photo边界；先交本机motion证明，再准备native current对象，远端配对/校验和由协调器确认。
@MainActor protocol LocalLivePhotoMediaReading: Sendable {
    /// expected含同设备已知修改版本；nil代表不支持/本机不可读，取消和validateContext失效原样抛出。
    func motionProof(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> LocalLivePhotoMotionProof?
    /// targetPixels来自展示规格，expectedSource是前阶段motion证明快照；nil仅用于独立本机读取，关联流程必须传实际proof.source。
    func livePhoto(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, matching expectedSource: LocalPhotoSnapshot?,
                   validateContext: @MainActor () throws -> Void) async throws -> PHLivePhoto?
}

/// native Live Photo回调的窄Sendable值；临时降质/系统错误不会被当作最终完整媒体。
nonisolated struct LocalLivePhotoDelivery: Sendable {
    let livePhoto: PHLivePhoto?
    let degraded: Bool
    let failed: Bool
}

/// 只替换PhotoKit观察、完整字节流和native请求点；生产默认使用公开API，reader持有全部时序和版本门禁。
@MainActor protocol LocalLivePhotoRequesting: Sendable {
    /// identifier限定当前设备；返回公开观察，权限不足或消失返回nil，不弹权限框。
    func source(for identifier: String) -> LocalLivePhotoSource?
    /// source/resource先通过policy，生产调用前再次核源；nil为未启动/本机不可读，取消抛出。
    func motionDigest(for source: LocalLivePhotoSource, resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest?
    /// source必须保持当前，options固定current/network=false；多次/迟到result交上层gate，nil为未启动。
    func requestLivePhoto(for source: LocalLivePhotoSource, targetPixels: MediaPixelSize, options: PHLivePhotoRequestOptions,
                          result: @escaping @Sendable (LocalLivePhotoDelivery) -> Void) -> LocalPhotoMediaRequest?
}

/// 有限本机Live读取编排；不访问Immich、不做账户持久化、不将still映射直接升级为motion已匹配。
@MainActor struct PhotoKitLocalLivePhotoMediaReader: LocalLivePhotoMediaReading {
    private let driver: any LocalLivePhotoRequesting
    private let timeout: Duration

    /// driver默认真实PhotoKit；timeout只限制native准备时间，超时取消真实请求后作为本机miss返回nil。
    init(driver: any LocalLivePhotoRequesting = PhotoKitLocalLivePhotoDriver(), timeout: Duration = .seconds(4)) {
        self.driver = driver; self.timeout = max(.milliseconds(1), timeout)
    }

    /// 不导出或积累movie；前后完整source/权限一致才交SHA1，云端only/失败不产生部分证明。
    func motionProof(for expected: LocalPhotoIdentity, validateContext: @MainActor () throws -> Void) async throws -> LocalLivePhotoMotionProof? {
        try context(validateContext)
        let observed = currentSource(expected)
        try context(validateContext)
        guard let before = observed, let resource = before.motionResource() else { return nil }
        let digest: LocalPhotoByteDigest?
        do { digest = try await driver.motionDigest(for: before, resource: resource) }
        catch {
            try context(validateContext)
            if error is CancellationError {
                throw error
            }
            return nil
        }
        try context(validateContext)
        let after = currentSource(expected)
        try context(validateContext)
        guard before == after, let digest else { return nil }
        return try .init(source: before, resource: resource, digest: digest)
    }

    /// expectedSource非nil时在native请求前比较完整证明来源，关闭跨阶段只凭identity/modDate的空隙；独立读取默认nil。
    /// actual PHImageRequestID使用既有gate取消；degraded不算终态，取消/账号失效不能被包装为普通miss回源。
    func livePhoto(for expected: LocalPhotoIdentity, targetPixels: MediaPixelSize, matching expectedSource: LocalPhotoSnapshot? = nil,
                   validateContext: @MainActor () throws -> Void) async throws -> PHLivePhoto?
    {
        try context(validateContext)
        guard targetPixels.width > 0, targetPixels.height > 0 else { return nil }
        let observed = currentSource(expected)
        try context(validateContext)
        guard let before = observed, before.motionResource() != nil else { return nil }
        // proof.source已将cloudIdentity归零；比较所有可观察资源与元数据，不因本机ID/版本相同就沿用旧movie摘要。
        if let expectedSource, before.snapshot.withCloudIdentity(.unavailable) != expectedSource {
            return nil
        }
        let read = PhotoResourceRead<PHLivePhoto>()
        let duration = timeout
        let timer = Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            read.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try context(validateContext)
            let value: PHLivePhoto? = await withCheckedContinuation { continuation in
                read.begin(continuation)
                guard !Task.isCancelled else { read.cancel(); return }
                let options = PHLivePhotoRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                let request = driver.requestLivePhoto(for: before, targetPixels: targetPixels, options: options) { delivery in
                    if delivery.failed {
                        read.finish(nil)
                    } else if !delivery.degraded {
                        read.finish(delivery.livePhoto)
                    }
                }
                if let request {
                    read.install(request.cancel)
                } else {
                    read.finish(nil)
                }
            }
            try context(validateContext)
            let after = currentSource(expected)
            try context(validateContext)
            guard after == before else { return nil }
            return value
        } onCancel: { read.cancel() }
    }

    /// expected不是普通video身份，且修改版本必须已知；重新fetch完整观察，拒绝旧PHAsset缓存。
    private func currentSource(_ expected: LocalPhotoIdentity) -> LocalLivePhotoSource? {
        guard expected.mediaKind == .livePhoto, !expected.localIdentifier.isEmpty, expected.modificationDate != nil,
              let source = driver.source(for: expected.localIdentifier), source.snapshot.identity == expected else { return nil }
        return source
    }

    /// validate为调用方账户/页面代际；本层单独检查Task取消，调用方错误不降级成nil。
    private func context(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation(); try validate()
    }
}

/// 公开PhotoKit实现；movie仅流式摘要，native对象用requestLivePhoto，不提供movie URL/导出/联网开关。
@MainActor struct PhotoKitLocalLivePhotoDriver: LocalLivePhotoRequesting {
    /// 读已有授权与当前完整资源观察；playbackStyle可排除Loop/Bounce/Live关闭等非标准展示，不猜current资源。
    func source(for identifier: String) -> LocalLivePhotoSource? {
        guard let access = access(), let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: LocalPhotoExplicitAssetQuery.options()).firstObject,
              asset.mediaType == .image, asset.mediaSubtypes.contains(.photoLive) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).map(Self.describe).sorted(by: Self.precedes)
        let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate, mediaKind: .livePhoto),
                                          creationDate: asset.creationDate, adjustmentTime: asset.adjustmentTimestamp, hasAdjustments: asset.hasAdjustments,
                                          latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                                          pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration, mediaSubtypes: asset.mediaSubtypes.rawValue,
                                          resources: resources.map(\.descriptor), cloudIdentity: .unavailable)
        guard self.access() == access else { return nil }
        return .init(snapshot: snapshot, resources: resources, access: access, isLivePlayback: asset.playbackStyle == .livePhoto)
    }

    /// source为先前真实观察；复用已有network=false/有界内存/真实ID取消的SHA1流，不增加原片文件写入。
    func motionDigest(for source: LocalLivePhotoSource, resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest? {
        try Task.checkCancellation()
        guard source.motionResource() == resource, self.source(for: source.snapshot.identity.localIdentifier) == source,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.snapshot.identity.localIdentifier], options: LocalPhotoExplicitAssetQuery.options()).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .pairedVideo && Self.describe($0) == resource }
        guard resources.count == 1, let selected = resources.first else { return nil }
        return try await PhotoKitLocalResourceRequests().read(selected)
    }

    /// targetPixels为调用方已裁限像素；只接受current高质量/network=false，回调字典当场收束为Sendable状态。
    func requestLivePhoto(for source: LocalLivePhotoSource, targetPixels: MediaPixelSize, options: PHLivePhotoRequestOptions,
                          result: @escaping @Sendable (LocalLivePhotoDelivery) -> Void) -> LocalPhotoMediaRequest?
    {
        guard source.motionResource() != nil, self.source(for: source.snapshot.identity.localIdentifier) == source,
              options.version == .current, !options.isNetworkAccessAllowed,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.snapshot.identity.localIdentifier], options: LocalPhotoExplicitAssetQuery.options()).firstObject else { return nil }
        let manager = PHImageManager.default()
        let id = manager.requestLivePhoto(for: asset, targetSize: CGSize(width: targetPixels.width, height: targetPixels.height), contentMode: .aspectFit, options: options) { @Sendable value, info in
            let failed = info?[PHImageCancelledKey] as? Bool == true || info?[PHImageErrorKey] != nil
            result(.init(livePhoto: failed ? nil : value, degraded: info?[PHImageResultIsDegradedKey] as? Bool == true, failed: failed))
        }
        return .init(identifier: id, cancel: { manager.cancelImageRequest(id) })
    }

    /// 已有full/limited之外一律不访问库，不在播放请求中弹权限。
    private func access() -> LocalLivePhotoSource.Access? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) { case .authorized: .full; case .limited: .limited; default: nil }
    }

    /// 仅使用公开资源类型/UTI/像素；RAW与未知类型独立保留，不用文件扩展名或私有KVC。
    private static func describe(_ resource: PHAssetResource) -> LocalPhotoChecksumResource {
        let role: LocalPhotoResourceDescriptor.Role = switch resource.type {
        case .photo: .originalPhoto
        case .pairedVideo: .pairedVideo
        case .video: .originalVideo
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: .adjusted
        case .adjustmentData: .adjustmentData
        default: .other
        }
        let format: LocalPhotoChecksumFormat = if let type = UTType(resource.uniformTypeIdentifier) {
            if type.conforms(to: .rawImage) {
                .raw
            } else if type.conforms(to: .image) {
                .image
            } else if type.conforms(to: .movie) {
                .video
            } else {
                .unsupported
            }
        } else {
            .unsupported
        }
        return .init(descriptor: .init(type: resource.type.rawValue, role: role, originalFilename: resource.originalFilename, uniformTypeIdentifier: resource.uniformTypeIdentifier,
                                       pixelWidth: resource.pixelWidth, pixelHeight: resource.pixelHeight), format: format)
    }

    /// 稳定规范公开资源顺序，重复资源不消除；完整snapshot比较可观察重复/调整/资源变化。
    private static func precedes(_ lhs: LocalPhotoChecksumResource, _ rhs: LocalPhotoChecksumResource) -> Bool {
        let left = lhs.descriptor; let right = rhs.descriptor
        if left.type != right.type {
            return left.type < right.type
        }
        if left.originalFilename != right.originalFilename {
            return left.originalFilename < right.originalFilename
        }
        if left.uniformTypeIdentifier != right.uniformTypeIdentifier {
            return left.uniformTypeIdentifier < right.uniformTypeIdentifier
        }
        if left.pixelWidth != right.pixelWidth {
            return left.pixelWidth < right.pixelWidth
        }
        return left.pixelHeight < right.pixelHeight
    }
}
