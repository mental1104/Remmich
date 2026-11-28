import Foundation
import Photos
import UniformTypeIdentifiers

/// 只读本机current字节证明；expected绑定已观察的Photos版本，validateContext绑定账号/页面，不与上传或SQLite耦合。
@MainActor protocol LocalPhotoChecksumReading: Sendable {
    /// 读取前后都检查expected完整元数据/授权；不足不触发iCloud或Immich媒体下载，取消不交出部分proof。
    func checksum(for expected: LocalPhotoSnapshot, validateContext: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome
}

/// 公开PhotoKit资源的保守current哈希读取器；不调用cloudIdentifierMappings，不用私有isCurrent/locallyAvailable或KVC。
@MainActor struct PhotoKitCurrentResourceChecksumReader: LocalPhotoChecksumReading {
    typealias SourceLoader = @MainActor (String) throws -> LocalPhotoChecksumAsset?
    typealias ByteReader = @MainActor (LocalPhotoIdentity, LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest
    typealias Authorization = @MainActor () -> PHAuthorizationStatus
    private let source: SourceLoader
    private let bytes: ByteReader
    private let authorization: Authorization

    /// source/bytes/authorization只替换系统边界；默认公开Photos+真实流式SHA1，版本/取消/上下文门禁保持执行。
    init(source: SourceLoader? = nil, bytes: ByteReader? = nil, authorization: Authorization? = nil) {
        self.source = source ?? Self.readSource
        self.bytes = bytes ?? Self.readBytes
        self.authorization = authorization ?? { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    }

    /// expected可含Cloud ID，但本路径不依赖它；只比较归零cloudIdentity后的同一完整Photos观察版本。
    func checksum(for expected: LocalPhotoSnapshot, validateContext: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        try context(validateContext)
        let permission = try authorized()
        let expected = expected.withCloudIdentity(.unavailable)
        guard let before = try source(expected.identity.localIdentifier) else { return .insufficient(.sourceUnavailable) }
        try context(validateContext)
        guard before.snapshot.withCloudIdentity(.unavailable) == expected else { throw LocalPhotoChecksumError.sourceChanged }
        let resource: LocalPhotoChecksumResource
        switch before.selection() {
        case let .failure(reason): return .insufficient(reason)
        case let .success(selected): resource = selected
        }
        let digest: LocalPhotoByteDigest
        do { digest = try await bytes(before.snapshot.identity, resource) }
        catch {
            try context(validateContext)
            guard try authorized() == permission else { throw LocalPhotoChecksumError.permission }
            if case LocalPhotoChecksumError.networkRequired = error {
                return .insufficient(.notLocallyAvailable)
            }
            if case LocalPhotoChecksumError.emptyResource = error {
                return .insufficient(.emptyResource)
            }
            if case LocalPhotoChecksumError.readFailed = error {
                return .insufficient(.readFailed)
            }
            throw error
        }
        try context(validateContext)
        guard try authorized() == permission else { throw LocalPhotoChecksumError.permission }
        guard let after = try source(expected.identity.localIdentifier), after == before,
              after.snapshot.withCloudIdentity(.unavailable) == expected else { throw LocalPhotoChecksumError.sourceChanged }
        try context(validateContext)
        return try .verified(.init(asset: after, resource: resource, digest: digest))
    }

    /// validate为当前任务代际；每个异步边界独立检查Task取消，不能凭旧账号source返回新proof。
    private func context(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation(); try validate()
    }

    /// 返回当前已获授权状态；limited允许仅当前可见资源，任何授权变化均使本轮观察作废，不弹授权对话。
    private func authorized() throws -> PHAuthorizationStatus {
        let status = authorization()
        guard status == .authorized || status == .limited else { throw LocalPhotoChecksumError.permission }
        return status
    }

    /// id为已观察的本机标识；只获取公开元数据和资源描述，无云映射、媒体下载或系统私有字段。
    private static func readSource(_ id: String) throws -> LocalPhotoChecksumAsset? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: LocalPhotoExplicitAssetQuery.options()).firstObject, asset.mediaType == .image || asset.mediaType == .video else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).map(describe).sorted(by: precedes)
        let kind: LocalPhotoIdentity.MediaKind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .image
        let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate, mediaKind: kind),
                                          creationDate: asset.creationDate, adjustmentTime: asset.adjustmentTimestamp, hasAdjustments: asset.hasAdjustments,
                                          latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude, pixelWidth: asset.pixelWidth,
                                          pixelHeight: asset.pixelHeight, duration: asset.duration, mediaSubtypes: asset.mediaSubtypes.rawValue,
                                          resources: resources.map(\.descriptor), cloudIdentity: .unavailable)
        return .init(snapshot: snapshot, resources: resources)
    }

    /// identity/resource已通过政策；发请求前再取公开对象并核对唯一描述，Live还须无调整时间且只读photo。
    /// 完整源与paired描述的前后比较由checksum执行；不从still证明跳到forVideo或motion读取。
    private static func readBytes(_ identity: LocalPhotoIdentity, _ resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest {
        try Task.checkCancellation()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identity.localIdentifier], options: LocalPhotoExplicitAssetQuery.options()).firstObject,
              asset.modificationDate == identity.modificationDate, !asset.hasAdjustments,
              identity.mediaKind != .livePhoto || (asset.adjustmentTimestamp == nil && resource.descriptor.role == .originalPhoto && resource.format == .image)
        else { throw LocalPhotoChecksumError.sourceChanged }
        let selected = PHAssetResource.assetResources(for: asset).filter { describe($0) == resource }
        guard selected.count == 1, let selected = selected.first else { throw LocalPhotoChecksumError.sourceChanged }
        return try await PhotoKitLocalResourceRequests().read(selected)
    }

    /// resource类型/UTI均为公开值；格式未知不猜，RAW不通过扩展名或内容大小识别。
    private static func describe(_ resource: PHAssetResource) -> LocalPhotoChecksumResource {
        let role: LocalPhotoResourceDescriptor.Role = switch resource.type {
        case .photo: .originalPhoto
        case .video: .originalVideo
        case .pairedVideo: .pairedVideo
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
        return .init(descriptor: .init(type: resource.type.rawValue, role: role, originalFilename: resource.originalFilename,
                                       uniformTypeIdentifier: resource.uniformTypeIdentifier, pixelWidth: resource.pixelWidth, pixelHeight: resource.pixelHeight), format: format)
    }

    /// lhs/rhs按现有元数据reader同样的公开字段排序；重复资源保留，不能靠排序消除歧义。
    private static func precedes(_ lhs: LocalPhotoChecksumResource, _ rhs: LocalPhotoChecksumResource) -> Bool {
        let lhs = lhs.descriptor; let rhs = rhs.descriptor
        if lhs.type != rhs.type {
            return lhs.type < rhs.type
        }
        if lhs.originalFilename != rhs.originalFilename {
            return lhs.originalFilename < rhs.originalFilename
        }
        if lhs.uniformTypeIdentifier != rhs.uniformTypeIdentifier {
            return lhs.uniformTypeIdentifier < rhs.uniformTypeIdentifier
        }
        if lhs.pixelWidth != rhs.pixelWidth {
            return lhs.pixelWidth < rhs.pixelWidth
        }
        return lhs.pixelHeight < rhs.pixelHeight
    }
}
