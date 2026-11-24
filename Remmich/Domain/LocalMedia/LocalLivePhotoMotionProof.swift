import Foundation

/// 本机Live Photo的公开完整观察；只包含值，不携带PHAsset/文件URL，不推断远端配对已验证。
nonisolated struct LocalLivePhotoSource: Equatable, Sendable {
    /// 明确授权范围，变化后旧读取不能发布；无授权不构造来源。
    enum Access: Equatable, Sendable { case full, limited }
    let snapshot: LocalPhotoSnapshot
    let resources: [LocalPhotoChecksumResource]
    let access: Access
    let isLivePlayback: Bool

    /// 只认未编辑的单一photo+pairedVideo；原始movie才可证明等于当前motion，RAW/调整/多资源不猜。
    func motionResource() -> LocalPhotoChecksumResource? {
        guard snapshot.identity.mediaKind == .livePhoto, isLivePlayback,
              !snapshot.identity.localIdentifier.isEmpty, let version = snapshot.identity.modificationDate, version.timeIntervalSince1970.isFinite,
              snapshot.pixelWidth > 0, snapshot.pixelHeight > 0, snapshot.duration.isFinite, snapshot.duration >= 0,
              !snapshot.hasAdjustments, snapshot.adjustmentTime == nil,
              resources.count == 2, resources.map(\.descriptor) == snapshot.resources else { return nil }
        let photos = resources.filter { $0.descriptor.role == .originalPhoto && $0.format == .image }
        let motions = resources.filter { $0.descriptor.role == .pairedVideo && $0.format == .video }
        guard photos.count == 1, motions.count == 1 else { return nil }
        return motions[0]
    }
}

/// 本机完整pairedVideo字节证明；digest需由远端协调器对fresh motion checksum验证，不能当备份或remote-pair回执。
nonisolated struct LocalLivePhotoMotionProof: Equatable, Sendable {
    let source: LocalPhotoSnapshot
    let resource: LocalPhotoResourceDescriptor
    let digest: LocalPhotoByteDigest

    /// source为前后稳定的当前本机观察；resource必须是纯policy唯一选中的motion，digest是完整非空字节摘要。
    init(source: LocalLivePhotoSource, resource: LocalPhotoChecksumResource, digest: LocalPhotoByteDigest) throws {
        guard source.motionResource() == resource else { throw LocalPhotoChecksumError.invalidInput }
        self.source = source.snapshot.withCloudIdentity(.unavailable)
        self.resource = resource.descriptor
        self.digest = digest
    }
}
