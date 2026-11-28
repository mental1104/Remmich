import Foundation

/// 本客户端独立元数据只声明完整Cloud ID关系；不能转换成mobile-app五元组或字节证明。
nonisolated struct LocalMediaDisplayCloudIdentity: Decodable, Hashable, Sendable {
    static let metadataKey = "remmich-icloud-match"
    let cloudID: String

    private enum CodingKeys: String, CodingKey { case version, method, iCloudId, byteVerified }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let cloudID = try values.decode(String.self, forKey: .iCloudId)
        guard try values.decode(Int.self, forKey: .version) == 1,
              try values.decode(String.self, forKey: .method) == "icloud-id",
              LocalMediaMobileMetadata.isUsableCloudID(cloudID), cloudID.utf8.count <= 4096
        else {
            throw LocalMediaMetadataError.invalidMetadata
        }
        // v1固定声明没有字节证明；不接受其他合同，也不授予任何字节验证能力。
        guard try values.decode(Bool.self, forKey: .byteVerified) == false else { throw LocalMediaMetadataError.invalidMetadata }
        self.cloudID = cloudID
    }
}

/// 已收到冲突/不可解析的身份声明时，保持待核查；不能让上层将其转换为本机不存在后换源。
nonisolated enum LocalPhotoDisplayEvidencePending: Error, Equatable, Sendable {
    case conflictingCloudIdentitySources, rejectedIdentityMarker, rejectedDisplayIdentity, displayAssociationPersistenceUnavailable
}

/// 仅当前可见项的展示证据；两种来源保持分离，诊断只含固定匿名分类。
nonisolated struct LocalPhotoDisplayEvidenceRecord: Sendable {
    let remote: LocalMediaRemoteAsset
    let fullMetadataCandidates: [LocalMediaRemoteCandidate]
    let cloudIdentityCandidates: Set<LocalMediaDisplayCloudIdentity>
    let metadataDiagnostics: Set<String>

    var cloudIDs: Set<String> {
        Set(fullMetadataCandidates.map(\.metadata.cloudId)).union(cloudIdentityCandidates.map(\.cloudID))
    }

    var hasConflictingIdentitySources: Bool {
        !cloudIdentityCandidates.isEmpty && cloudIDs.count > 1
    }

    func displaySource(for cloudID: String) -> LocalMediaAssociation.Source? {
        if fullMetadataCandidates.contains(where: { $0.metadata.cloudId == cloudID }) {
            return .mobileMetadata
        }
        if cloudIdentityCandidates.contains(where: { $0.cloudID == cloudID }) {
            return .exactCloudIdentity
        }
        return nil
    }
}
