import Foundation

/// 本机字节读取不足以证明Photos current时的明确原因；不把云端only、RAW或编辑原片当作未命中后自动上传。
nonisolated enum LocalPhotoChecksumInsufficiency: Error, Equatable, Sendable {
    case sourceUnavailable, versionUnavailable, unsupportedMedia, currentRepresentationUnproven
    case rawOrCompound, ambiguousResources, unsupportedResource, notLocallyAvailable, emptyResource, readFailed
}

/// SHA1读取/查询的稳定错误；不携带本机标识、文件路径、系统异常正文或凭据。
nonisolated enum LocalPhotoChecksumError: Error, Equatable, Sendable {
    case invalidInput, invalidDigest, permission, sourceChanged, networkRequired, emptyResource, readFailed
}

/// 资源UTI的公开分类；RAW单独保留，不能把RAW+JPEG中的任一成员冒充完整current媒体。
nonisolated enum LocalPhotoChecksumFormat: Equatable, Sendable { case image, video, raw, unsupported }

/// 可选哈希资源的完整公开描述；format由公开UTType判定，不依赖文件扩展名或私有isCurrent字段。
nonisolated struct LocalPhotoChecksumResource: Equatable, Sendable {
    let descriptor: LocalPhotoResourceDescriptor
    let format: LocalPhotoChecksumFormat
}

/// 一次本地元数据观察；不执行Cloud ID映射。resources顺序与snapshot中的完整公开描述一致。
nonisolated struct LocalPhotoChecksumAsset: Equatable, Sendable {
    let snapshot: LocalPhotoSnapshot
    let resources: [LocalPhotoChecksumResource]

    /// 普通媒体只选未编辑单一原始资源；严格Live photo+pairedVideo仅选still照片，绝不证明motion/整组备份。
    /// fullSize仅承诺modified版本，不猜它就是Photos current；Live任何调整时间也不能用原片冒充current。
    func selection() -> Result<LocalPhotoChecksumResource, LocalPhotoChecksumInsufficiency> {
        guard !snapshot.identity.localIdentifier.isEmpty,
              snapshot.pixelWidth > 0, snapshot.pixelHeight > 0, snapshot.duration.isFinite, snapshot.duration >= 0 else { return .failure(.unsupportedMedia) }
        guard let modified = snapshot.identity.modificationDate, modified.timeIntervalSince1970.isFinite else { return .failure(.versionUnavailable) }
        guard resources.map(\.descriptor) == snapshot.resources else { return .failure(.ambiguousResources) }
        guard !snapshot.hasAdjustments, !resources.contains(where: { $0.descriptor.role == .adjusted || $0.descriptor.role == .adjustmentData }) else { return .failure(.currentRepresentationUnproven) }
        guard !resources.contains(where: { $0.format == .raw || $0.descriptor.role == .alternatePhoto }) else { return .failure(.rawOrCompound) }
        if snapshot.identity.mediaKind == .livePhoto {
            guard snapshot.adjustmentTime == nil else { return .failure(.currentRepresentationUnproven) }
            let photos = resources.filter { $0.descriptor.role == .originalPhoto && $0.format == .image }
            let motions = resources.filter { $0.descriptor.role == .pairedVideo && $0.format == .video }
            guard resources.count == 2, photos.count == 1, motions.count == 1 else { return .failure(.unsupportedMedia) }
            // 完整paired描述只绑定源版本；此digest必须来自photo，不触及pairedVideo字节或remote配对证明。
            return .success(photos[0])
        }
        guard resources.count == 1, let resource = resources.first else { return .failure(.ambiguousResources) }
        switch snapshot.identity.mediaKind {
        case .image:
            guard resource.descriptor.role == .originalPhoto, resource.format == .image else { return .failure(.unsupportedResource) }
        case .video:
            guard resource.descriptor.role == .originalVideo, resource.format == .video else { return .failure(.unsupportedResource) }
        case .livePhoto: return .failure(.unsupportedMedia)
        }
        return .success(resource)
    }
}

/// 对实际读完的非空本机字节计算的SHA1；十六进制小写40字符，byteCount是实际收到的总字节数。
nonisolated struct LocalPhotoByteDigest: Equatable, Sendable {
    let sha1Hex: String
    let sha1Base64: String
    let byteCount: Int64

    /// sha1Hex为流式计算结果，byteCount必须正数；空文件摘要或非法哈希不能进入远端查询。
    init(sha1Hex: String, byteCount: Int64) throws {
        guard sha1Hex.utf8.count == 40, sha1Hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }), byteCount > 0 else {
            throw LocalPhotoChecksumError.invalidDigest
        }
        let digits = Array(sha1Hex.utf8)
        let bytes: [UInt8] = stride(from: 0, to: digits.count, by: 2).map { index in
            let high = digits[index] <= 57 ? digits[index] - 48 : digits[index] - 87
            let low = digits[index + 1] <= 57 ? digits[index + 1] - 48 : digits[index + 1] - 87
            return high << 4 | low
        }
        self.sha1Hex = sha1Hex; sha1Base64 = Data(bytes).base64EncodedString(); self.byteCount = byteCount
    }
}

/// 只读展示用的本机current字节证明；Live只证明still，source含paired描述不代表已哈希/验证motion。
/// 不是上传回执、远端配对/唯一性或备份/清理凭据；motion另需独立证明与fresh配对校验。
nonisolated struct LocalPhotoChecksumProof: Equatable, Sendable {
    let source: LocalPhotoSnapshot
    let resource: LocalPhotoChecksumResource
    let digest: LocalPhotoByteDigest

    /// asset为前后版本已确认的本地源，resource必须是公开政策唯一选中项，digest来自完整无网络读取。
    init(asset: LocalPhotoChecksumAsset, resource: LocalPhotoChecksumResource, digest: LocalPhotoByteDigest) throws {
        guard case let .success(selected) = asset.selection(), selected == resource else { throw LocalPhotoChecksumError.invalidInput }
        source = asset.snapshot; self.resource = resource; self.digest = digest
    }
}

/// verified仅表明当前本机资源哈希可用；不足不能被转换成空哈希、已上传或关联成功。
nonisolated enum LocalPhotoChecksumOutcome: Equatable, Sendable {
    case verified(LocalPhotoChecksumProof), insufficient(LocalPhotoChecksumInsufficiency)
}

/// 客户端批量校验和查询；id只用于本轮对应关系，与Photos标识及服务端asset UUID无关。
nonisolated struct LocalMediaChecksumQuery: Equatable, Sendable {
    static let batchLimit = 64
    let id: UUID
    let digest: LocalPhotoByteDigest

    /// digest是本轮验证过的字节摘要，id默认新随机nonce；调用者保留它到本机proof的映射。
    init(id: UUID = UUID(), digest: LocalPhotoByteDigest) {
        self.id = id; self.digest = digest
    }
}

/// bulk-upload-check只是查找；accept为未命中，trashed不能关联，existing还必须fresh检查owner/类型/离线/编辑和checksum。
nonisolated struct LocalMediaChecksumLookup: Equatable, Sendable {
    /// 不暴露action=accept为上传指令，避免匹配流程误入备份队列。
    enum Outcome: Equatable, Sendable { case noMatch, existing(UUID), trashed(UUID) }
    let id: UUID
    let outcome: Outcome
}
