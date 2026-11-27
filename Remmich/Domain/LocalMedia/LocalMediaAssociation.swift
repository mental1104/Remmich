import Foundation

/// 新鲜官方资源详情的只读安全子集；缺少状态保持未知，不能用旧服务端缺字段推断可替代媒体。
nonisolated struct LocalMediaRemoteAsset: Decodable, Equatable, Sendable {
    let id: UUID
    let ownerId: UUID
    let type: String
    let isTrashed: Bool?
    let isOffline: Bool?
    let isEdited: Bool?
    let checksum: String?
    let updatedAt: Date?
    let livePhotoVideoId: UUID?
    let createdAt: Date?
    let fileCreatedAt: Date?

    /// 与时间线的缩略图键一致；资产updatedAt还会因匹配标记/描述等非像素字段改变。
    var displayRevision: Date? {
        guard let createdAt, let fileCreatedAt else { return nil }
        return max(createdAt, fileCreatedAt)
    }

    private enum CodingKeys: String, CodingKey { case id, ownerId, type, isTrashed, isOffline, isEdited, checksum, updatedAt, livePhotoVideoId, createdAt, fileCreatedAt }

    /// id/owner/type来自GET身份；可选状态、20字节SHA1的Base64与版本缺失时保留nil，供验证层明确拒绝。
    init(id: UUID, ownerId: UUID, type: String, isTrashed: Bool?, isOffline: Bool?, isEdited: Bool?, checksum: String?, updatedAt: Date?, livePhotoVideoId: UUID? = nil,
         createdAt: Date? = nil, fileCreatedAt: Date? = nil)
    {
        self.id = id; self.ownerId = ownerId; self.type = type
        self.isTrashed = isTrashed; self.isOffline = isOffline; self.isEdited = isEdited
        self.checksum = checksum; self.updatedAt = updatedAt; self.livePhotoVideoId = livePhotoVideoId
        self.createdAt = createdAt; self.fileCreatedAt = fileCreatedAt
    }

    /// decoder使用官方ISO字符串版本，支持小数秒；坏日期抛出而不是降级为nil后与未知版本相等。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date? {
            try values.decodeIfPresent(String.self, forKey: key).map { value in
                let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#
                guard value.range(of: pattern, options: .regularExpression) != nil else { throw LocalMediaMetadataError.invalidMetadata }
                if value.contains(".") {
                    return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
                }
                return try Date.ISO8601FormatStyle().parse(value)
            }
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), ownerId: values.decode(UUID.self, forKey: .ownerId),
                      type: values.decode(String.self, forKey: .type), isTrashed: values.decodeIfPresent(Bool.self, forKey: .isTrashed),
                      isOffline: values.decodeIfPresent(Bool.self, forKey: .isOffline), isEdited: values.decodeIfPresent(Bool.self, forKey: .isEdited),
                      checksum: values.decodeIfPresent(String.self, forKey: .checksum), updatedAt: date(.updatedAt),
                      livePhotoVideoId: values.decodeIfPresent(UUID.self, forKey: .livePhotoVideoId),
                      createdAt: date(.createdAt), fileCreatedAt: date(.fileCreatedAt))
    }
}

/// 已确认的本机展示关联；按scope原子保存和恢复，不作为备份回执或删除设备原片的依据。
nonisolated struct LocalMediaAssociation: Codable, Equatable, Sendable {
    /// 来源区分官方元数据关系和本机字节SHA1；两者仍必须通过新鲜远端详情检查。
    enum Source: String, Codable, Sendable { case mobileMetadata, checksum }
    let remoteID: UUID
    let remoteRevision: Date
    let displayRevision: Date?
    let localIdentity: LocalPhotoIdentity
    let checksum: String
    let source: Source

    private enum CodingKeys: String, CodingKey { case remoteID, remoteRevision, displayRevision, localID, modifiedAt, kind, checksum, source }

    /// remoteRevision/checksum为实际新鲜GET值；localIdentity是已验证Photos版本，source不改变其只读展示语义。
    init(remoteID: UUID, remoteRevision: Date, localIdentity: LocalPhotoIdentity, checksum: String, source: Source, displayRevision: Date? = nil) {
        self.remoteID = remoteID; self.remoteRevision = remoteRevision; self.localIdentity = localIdentity
        self.checksum = checksum; self.source = source
        self.displayRevision = displayRevision
    }

    func matchesDisplayRevision(_ revision: Date) -> Bool {
        (displayRevision ?? remoteRevision).timeIntervalSince1970 == revision.timeIntervalSince1970
    }

    /// 显式编码本机身份，避免为历史领域模型添加跨文件隐式Codable合成；不写任何token或服务器凭据。
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(remoteID, forKey: .remoteID); try values.encode(remoteRevision, forKey: .remoteRevision)
        try values.encodeIfPresent(displayRevision, forKey: .displayRevision)
        try values.encode(localIdentity.localIdentifier, forKey: .localID); try values.encodeIfPresent(localIdentity.modificationDate, forKey: .modifiedAt)
        let kind = localIdentity.mediaKind == .video ? "video" : localIdentity.mediaKind == .livePhoto ? "livePhoto" : "image"
        try values.encode(kind, forKey: .kind); try values.encode(checksum, forKey: .checksum); try values.encode(source, forKey: .source)
    }

    /// 未知kind/缺失已知版本拒绝恢复；原子存储另检查版本、账号namespace和SHA1，不能默认为可用。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        let mediaKind: LocalPhotoIdentity.MediaKind
        switch kind {
        case "image": mediaKind = .image
        case "video": mediaKind = .video
        case "livePhoto": mediaKind = .livePhoto
        default: throw LocalMediaMetadataError.invalidMetadata
        }
        let localID = try values.decode(String.self, forKey: .localID)
        let modified = try values.decode(Date.self, forKey: .modifiedAt)
        let displayRevision = try values.decodeIfPresent(Date.self, forKey: .displayRevision)
        guard !localID.isEmpty, displayRevision?.timeIntervalSince1970.isFinite ?? true else { throw LocalMediaMetadataError.invalidMetadata }
        try self.init(remoteID: values.decode(UUID.self, forKey: .remoteID), remoteRevision: values.decode(Date.self, forKey: .remoteRevision),
                      localIdentity: .init(localIdentifier: localID, modificationDate: modified, mediaKind: mediaKind),
                      checksum: values.decode(String.self, forKey: .checksum), source: values.decode(Source.self, forKey: .source), displayRevision: displayRevision)
    }

    /// remote必须是当前账号同一可显示对象；未知状态/服务端编辑/坏SHA1均拒绝，expectedChecksum仅用于字节匹配路径。
    static func verified(remote: LocalMediaRemoteAsset, requestedID: UUID, ownerID: String, local: LocalPhotoIdentity,
                         source: Source, expectedChecksum: String? = nil) -> LocalMediaAssociation?
    {
        guard let owner = UUID(uuidString: ownerID), remote.id == requestedID, remote.ownerId == owner, !local.localIdentifier.isEmpty,
              let modified = local.modificationDate, modified.timeIntervalSince1970.isFinite,
              remote.isTrashed == false, remote.isOffline == false, remote.isEdited == false,
              remote.type == (local.mediaKind == .video ? "VIDEO" : "IMAGE"),
              let revision = remote.updatedAt, revision.timeIntervalSince1970.isFinite,
              let checksum = remote.checksum, let bytes = Data(base64Encoded: checksum), bytes.count == 20,
              bytes.base64EncodedString() == checksum, expectedChecksum == nil || checksum == expectedChecksum else { return nil }
        return .init(remoteID: remote.id, remoteRevision: revision, localIdentity: local, checksum: checksum, source: source, displayRevision: remote.displayRevision)
    }
}
