import Foundation
import Photos
import UniformTypeIdentifiers

/// 只读本机双原图；context绑定当前账号/页面，每份完整哈希及最终fresh远端核查后都能重验本机版本。
@MainActor protocol PhotoBackupRawJPEGChecksumReading: Sendable {
    /// expected必须是当前扫描的RAW+JPEG；本机不可用返回nil，权限/版本/取消错误抛出，不请求云下载。
    func checksumPair(for expected: PhotoBackupSource, validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupRawJPEGLocalProof?
    /// proof为本轮完整哈希观察；仅重读元数据和权限，不再次传输媒体，变化则拒绝组织。
    func validateCurrent(_ proof: PhotoBackupRawJPEGLocalProof, validateContext: @MainActor () throws -> Void) throws
}

/// 公开Photos原资源与已有network=false流式SHA1桥接；不调用上传Exporter，不读取motion或Immich原片。
@MainActor struct PhotoKitRawJPEGChecksumReader: PhotoBackupRawJPEGChecksumReading {
    typealias SourceLoader = @MainActor (String) throws -> LocalPhotoChecksumAsset?
    typealias ByteReader = @MainActor (LocalPhotoChecksumAsset, LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest
    private let source: SourceLoader
    private let bytes: ByteReader
    private let authorization: @MainActor () -> PHAuthorizationStatus

    /// 可选端口只替换公开Photos观察/实际资源流；默认复用已有SHA1流，永不开放allowCloud参数。
    init(source: SourceLoader? = nil, bytes: ByteReader? = nil, authorization: (@MainActor () -> PHAuthorizationStatus)? = nil) {
        self.source = source ?? Self.readSource; self.bytes = bytes ?? Self.readBytes
        self.authorization = authorization ?? { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    }

    /// 两份资源各自读完才交出证明；每次await前后都检查同一完整观察/授权/账号，部分资源不够建立配对。
    func checksumPair(for expected: PhotoBackupSource, validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupRawJPEGLocalProof? {
        try check(validateContext)
        let permission = try authorized()
        guard let before = try source(expected.localID) else { return nil }
        let selected = try before.rawJPEGResources(for: expected)
        do {
            let raw = try await bytes(before, selected.raw)
            try validate(before, permission: permission, context: validateContext)
            let jpeg = try await bytes(before, selected.jpeg)
            try validate(before, permission: permission, context: validateContext)
            return try .init(source: expected, observation: before, raw: raw, jpeg: jpeg, access: permission == .authorized ? .full : .limited)
        } catch {
            try validate(before, permission: permission, context: validateContext)
            if let failure = error as? LocalPhotoChecksumError, [.networkRequired, .emptyResource, .readFailed].contains(failure) {
                return nil
            }
            throw error
        }
    }

    /// fresh读取必须仍是本轮已哈希公开观察；既有云下载意愿不会放宽本机-only证明。
    func validateCurrent(_ proof: PhotoBackupRawJPEGLocalProof, validateContext: @MainActor () throws -> Void) throws {
        try validate(proof.observation, permission: proof.access == .full ? .authorized : .limited, context: validateContext)
        _ = try proof.observation.rawJPEGResources(for: proof.source)
    }

    /// snapshot为完整资源版本；permission固定本轮授权，context每次独立传播取消和原账号退休。
    private func validate(_ snapshot: LocalPhotoChecksumAsset, permission: PHAuthorizationStatus, context: @MainActor () throws -> Void) throws {
        try check(context)
        guard try authorized() == permission, let current = try source(snapshot.snapshot.identity.localIdentifier), current == snapshot else {
            throw LocalPhotoChecksumError.sourceChanged
        }
        try check(context)
    }

    /// context为调用者原账号门禁；取消不能被网络不足路径转成可用证明。
    private func check(_ context: @MainActor () throws -> Void) throws {
        try Task.checkCancellation(); try context()
    }

    /// 不弹授权面板，limited只读取当前可见资源；任何其它状态均明确拒绝。
    private func authorized() throws -> PHAuthorizationStatus {
        let value = authorization(); guard value == .authorized || value == .limited else { throw LocalPhotoChecksumError.permission }; return value
    }

    /// id为已扫描本机标识；读取全部公开资源描述，不访问Cloud ID、私有可用性、文件路径或媒体字节。
    private static func readSource(_ id: String) throws -> LocalPhotoChecksumAsset? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: LocalPhotoExplicitAssetQuery.options()).firstObject, asset.mediaType == .image else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).map(describe).sorted { $0.descriptor.type < $1.descriptor.type }
        let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate,
                                                          mediaKind: asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .image),
                                          creationDate: asset.creationDate, adjustmentTime: asset.adjustmentTimestamp, hasAdjustments: asset.hasAdjustments,
                                          latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                                          pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
                                          mediaSubtypes: asset.mediaSubtypes.rawValue, resources: resources.map(\.descriptor), cloudIdentity: .unavailable)
        return .init(snapshot: snapshot, resources: resources)
    }

    /// before/resource来自完整观察；开始实际流前再比对版本并唯一定位资源，固定复用network=false原始SHA1读取。
    private static func readBytes(_ before: LocalPhotoChecksumAsset, _ resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest {
        try Task.checkCancellation()
        let id = before.snapshot.identity.localIdentifier
        guard try readSource(id) == before, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: LocalPhotoExplicitAssetQuery.options()).firstObject else { throw LocalPhotoChecksumError.sourceChanged }
        let matches = PHAssetResource.assetResources(for: asset).filter { describe($0) == resource }
        guard matches.count == 1, let selected = matches.first else { throw LocalPhotoChecksumError.sourceChanged }
        return try await PhotoKitLocalResourceRequests().read(selected)
    }

    /// 角色/UTI均由公开资源给出；额外/编辑/动态项保留到完整验证时拒绝，不按文件扩展名猜RAW/JPEG。
    private static func describe(_ resource: PHAssetResource) -> LocalPhotoChecksumResource {
        let role: LocalPhotoResourceDescriptor.Role = switch resource.type {
        case .photo: .originalPhoto
        case .alternatePhoto: .alternatePhoto
        case .pairedVideo: .pairedVideo
        case .adjustmentData: .adjustmentData
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: .adjusted
        default: .other
        }
        let type = UTType(resource.uniformTypeIdentifier)
        let format: LocalPhotoChecksumFormat = type?.conforms(to: .rawImage) == true ? .raw : type?.conforms(to: .image) == true ? .image : .unsupported
        return .init(descriptor: .init(type: resource.type.rawValue, role: role, originalFilename: resource.originalFilename,
                                       uniformTypeIdentifier: resource.uniformTypeIdentifier, pixelWidth: resource.pixelWidth, pixelHeight: resource.pixelHeight), format: format)
    }
}
