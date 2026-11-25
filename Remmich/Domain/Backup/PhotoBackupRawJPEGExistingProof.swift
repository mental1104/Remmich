import Foundation

/// 本轮本机完整双原图证明；只绑定已扫描源和完整公开观察，不是上传完成回执或可清理手机的凭据。
nonisolated struct PhotoBackupRawJPEGLocalProof: Sendable {
    /// 本轮Photos可见范围；后续fresh重验不能把授权变化当作同一读取上下文。
    enum Access: Equatable, Sendable { case full, limited }
    let source: PhotoBackupSource
    let observation: LocalPhotoChecksumAsset
    let raw: LocalPhotoByteDigest
    let jpeg: LocalPhotoByteDigest
    let access: Access

    /// source/observation代表同一未编辑版本；raw/jpeg来自各自完整非空资源，摘要不同；access固定本轮Photos可见范围。
    init(source: PhotoBackupSource, observation: LocalPhotoChecksumAsset, raw: LocalPhotoByteDigest, jpeg: LocalPhotoByteDigest, access: Access) throws {
        _ = try observation.rawJPEGResources(for: source)
        guard raw.sha1Base64 != jpeg.sha1Base64 else { throw LocalPhotoChecksumError.invalidDigest }
        self.source = source; self.observation = observation; self.raw = raw; self.jpeg = jpeg; self.access = access
    }
}

extension LocalPhotoChecksumAsset {
    /// expected是已扫描版本；只接受恰一photo/alternatePhoto、恰一公开RAW/JPEG，拒绝编辑、Live/motion及额外资源。
    /// 返回原资源描述供独立读取，不能从文件名、大小或PhotoKit枚举位置猜角色。
    nonisolated func rawJPEGResources(for expected: PhotoBackupSource) throws -> (raw: LocalPhotoChecksumResource, jpeg: LocalPhotoChecksumResource) {
        guard !expected.localID.isEmpty, expected.kind == .rawJPEG, let pair = expected.rawJPEG, let modified = expected.modifiedAt,
              modified.timeIntervalSince1970.isFinite, snapshot.identity == .init(localIdentifier: expected.localID, modificationDate: modified, mediaKind: .image),
              !snapshot.hasAdjustments, snapshot.adjustmentTime == nil, snapshot.pixelWidth > 0, snapshot.pixelHeight > 0,
              snapshot.duration.isFinite, snapshot.duration == 0, resources.count == 2, resources.map(\.descriptor) == snapshot.resources
        else { throw LocalPhotoChecksumError.sourceChanged }
        try pair.validate()
        var selected: [PhotoBackupImageRole: LocalPhotoChecksumResource] = [:]
        for resource in resources {
            let descriptor = resource.descriptor
            let kind: PhotoBackupOriginalImage.Kind = switch descriptor.role {
            case .originalPhoto: .photo
            case .alternatePhoto: .alternatePhoto
            default: .unsupported
            }
            let image = PhotoBackupOriginalImage(kind: kind, uniformTypeIdentifier: descriptor.uniformTypeIdentifier,
                                                 originalFilename: descriptor.originalFilename, pixelWidth: descriptor.pixelWidth, pixelHeight: descriptor.pixelHeight)
            guard let role = image.format, image == (role == .raw ? pair.raw : pair.jpeg), selected[role] == nil,
                  resource.format == (role == .raw ? .raw : .image) else { throw LocalPhotoChecksumError.sourceChanged }
            selected[role] = resource
        }
        guard let raw = selected[.raw], let jpeg = selected[.jpeg] else { throw LocalPhotoChecksumError.sourceChanged }
        return (raw, jpeg)
    }
}

/// 两个独立远端原图UUID均与当前本机双摘要fresh一致；仅授权本轮相簿组织，绝不标记上传完成。
nonisolated struct PhotoBackupRawJPEGExistingProof: Sendable {
    let source: PhotoBackupSource
    let assets: [PhotoBackupAlbumSyncAsset]

    /// local绑定完整本机版本，raw/jpeg为独立fresh原图详情，ownerID来自当前认证账号；未知状态/版本拒绝。
    init?(local: PhotoBackupRawJPEGLocalProof, raw: ManagedAsset, jpeg: ManagedAsset, ownerID: String) {
        guard let owner = UUID(uuidString: ownerID), let rawID = UUID(uuidString: raw.id), let jpegID = UUID(uuidString: jpeg.id), rawID != jpegID,
              let rawVersion = Self.verify(raw, owner: owner, digest: local.raw),
              let jpegVersion = Self.verify(jpeg, owner: owner, digest: local.jpeg) else { return nil }
        source = local.source
        assets = [.init(role: .raw, assetID: rawID, checksum: local.raw.sha1Base64, revision: rawVersion, proof: .rawJPEGChecksum),
                  .init(role: .jpeg, assetID: jpegID, checksum: local.jpeg.sha1Base64, revision: jpegVersion, proof: .rawJPEGChecksum)]
    }

    /// value为真实完整详情；只接受同owner IMAGE、在线/未入回收站、timeline/archive与同一规范原片SHA1。
    private static func verify(_ value: ManagedAsset, owner: UUID, digest: LocalPhotoByteDigest) -> Date? {
        guard UUID(uuidString: value.ownerId) == owner, value.type == "IMAGE", !value.isTrashed, value.isOffline == false,
              ["timeline", "archive"].contains(value.visibility), value.checksum == digest.sha1Base64,
              let checksum = value.checksum, let bytes = Data(base64Encoded: checksum), bytes.count == 20, bytes.base64EncodedString() == checksum,
              let timestamp = value.updatedAt,
              timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil
        else { return nil }
        let date = timestamp.contains(".") ? try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
            : try? Date.ISO8601FormatStyle().parse(timestamp)
        return date.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }
}
