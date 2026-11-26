import Foundation

/// 当前手机照片库的公开对象身份/观察版本；仅供只读展示关联，不与任何上传队列或备份成功状态耦合。
nonisolated struct LocalPhotoIdentity: Equatable, Hashable, Sendable {
    /// 图片/视频/LivePhoto决定展示读取方式，不把LivePhoto静态帧关联当作原片配对已备份。
    enum MediaKind: Equatable, Hashable, Sendable { case image, video, livePhoto }
    let localIdentifier: String
    let modificationDate: Date?
    let mediaKind: MediaKind
}

/// 仅匹配官方mobile-app元数据；非法字段不能退化成nil后与未编辑/无位置源相等。
nonisolated enum LocalMediaMetadataError: Error, Equatable, Sendable {
    case invalidMetadata, invalidBatch, permission, sourceChanged
}

/// 官方mobile-app五元组，wire字段名为iCloudId；值来源是元数据，不是原片SHA1。
nonisolated struct LocalMediaMobileMetadata: Codable, Hashable, Sendable {
    let cloudId: String
    let createdAt: Date?
    let adjustmentTime: Date?
    let latitude: Double?
    let longitude: Double?

    private enum CodingKeys: String, CodingKey { case iCloudId, createdAt, adjustmentTime, latitude, longitude }

    /// cloudId保留完整opaque标识；时间保留精度，坐标必须有限且在合法范围内；缺省值由调用者明确传nil。
    init(cloudId: String, createdAt: Date?, adjustmentTime: Date?, latitude: Double?, longitude: Double?) throws {
        guard Self.isUsableCloudID(cloudId),
              createdAt.map(\.timeIntervalSince1970.isFinite) ?? true,
              adjustmentTime.map(\.timeIntervalSince1970.isFinite) ?? true,
              latitude.map({ $0.isFinite && (-90 ... 90).contains($0) }) ?? true,
              longitude.map({ $0.isFinite && (-180 ... 180).contains($0) }) ?? true
        else { throw LocalMediaMetadataError.invalidMetadata }
        self.cloudId = cloudId
        self.createdAt = createdAt
        self.adjustmentTime = adjustmentTime
        self.latitude = latitude
        self.longitude = longitude
    }

    /// decoder读取官方字符串字段；官方toJson明确省略nil entry，因此已知四个nullable键缺失等价于null，坏值仍抛错。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cloudId: container.decode(String.self, forKey: .iCloudId),
                      createdAt: Self.date(container, key: .createdAt), adjustmentTime: Self.date(container, key: .adjustmentTime),
                      latitude: Self.coordinate(container, key: .latitude), longitude: Self.coordinate(container, key: .longitude))
    }

    /// encoder保持官方字符串时间/坐标与省略nil字段的格式；不把本机ID或私有路径写入服务端。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cloudId, forKey: .iCloudId)
        try container.encodeIfPresent(createdAt?.ISO8601Format(), forKey: .createdAt)
        try container.encodeIfPresent(adjustmentTime?.ISO8601Format(), forKey: .adjustmentTime)
        try container.encodeIfPresent(latitude.map { String($0) }, forKey: .latitude)
        try container.encodeIfPresent(longitude.map { String($0) }, forKey: .longitude)
    }

    /// value来自完整PhotoKit映射；拒绝空白及官方已知的不完整尾冒号，不解析标识内部的HASH片段或规范化大小写。
    static func isUsableCloudID(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.hasSuffix(":")
    }

    /// container/key指向一个官方ISO字符串或null；解析失败抛错，绝不以try?吞成nil。remote时间不截秒。
    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { throw LocalMediaMetadataError.invalidMetadata }
        if text.contains(".") {
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        }
        return try Date.ISO8601FormatStyle().parse(text)
    }

    /// 官方坐标编码为字符串；缺失/null为未知，非空坏数值不能与本机未知坐标匹配。
    private static func coordinate(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Double? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = Double(text), value.isFinite else { throw LocalMediaMetadataError.invalidMetadata }
        return value
    }
}

/// 映射失败/缺项和完整映射严格分开；不持久化系统错误原文或凭据，任何未知都不能冒充已匹配。
nonisolated enum LocalPhotoCloudIdentity: Equatable, Sendable {
    case resolved(String), unavailable, incomplete, failed
}

/// 公开PHAssetResource结构描述，保留重复项；文件名/UTI仅观察资源形态变化，不作哈希或选择要播放的原片。
nonisolated struct LocalPhotoResourceDescriptor: Equatable, Sendable {
    /// 类型来自公开PHAssetResourceType；current展示交给PHImageManager，不依靠私有isCurrent字段猜资源。
    enum Role: Equatable, Sendable { case originalPhoto, originalVideo, pairedVideo, alternatePhoto, adjusted, adjustmentData, other }
    let type: Int
    let role: Role
    let originalFilename: String
    let uniformTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// 单次公开PhotoKit元数据快照；identity是实际观察版本，资源数据、原片URL和本地可用性私有字段都不进入此模型。
nonisolated struct LocalPhotoSnapshot: Equatable, Sendable {
    let identity: LocalPhotoIdentity
    let creationDate: Date?
    let adjustmentTime: Date?
    let hasAdjustments: Bool
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let mediaSubtypes: UInt
    let resources: [LocalPhotoResourceDescriptor]
    let cloudIdentity: LocalPhotoCloudIdentity

    /// resolution为本轮公开映射结果；保留其余精确元数据，供reader完成前后版本检查后附加映射。
    func withCloudIdentity(_ resolution: LocalPhotoCloudIdentity) -> Self {
        .init(identity: identity, creationDate: creationDate, adjustmentTime: adjustmentTime, hasAdjustments: hasAdjustments,
              latitude: latitude, longitude: longitude, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
              duration: duration, mediaSubtypes: mediaSubtypes, resources: resources, cloudIdentity: resolution)
    }

    /// 本轮匹配Photos current表示；允许明确调整时间相等的编辑照片，不从still候选推断LivePhoto视频或RAW原片备份完整性。
    var supportsCurrentMetadataMatch: Bool {
        pixelWidth > 0 && pixelHeight > 0 && duration.isFinite && duration >= 0
            && (!hasAdjustments || adjustmentTime != nil)
    }

    /// 本机时间按官方PHAssetExtensions的Int64 Unix秒政策规范化；remote端不再取整，不能抹掉不相等的小数。
    func mobileMetadata() throws -> LocalMediaMobileMetadata? {
        guard case let .resolved(identifier) = cloudIdentity, let creationDate else { return nil }
        return try .init(cloudId: identifier, createdAt: Self.officialTime(creationDate),
                         adjustmentTime: adjustmentTime.map(Self.officialTime), latitude: latitude, longitude: longitude)
    }

    /// date是有限Photos时间；向零截断与官方Int64转换一致，不使用当前时间补造缺失的createdAt。
    private static func officialTime(_ date: Date) throws -> Date {
        let value = date.timeIntervalSince1970
        guard value.isFinite else { throw LocalMediaMetadataError.invalidMetadata }
        return Date(timeIntervalSince1970: value.rounded(.towardZero))
    }
}

/// stream阶段仅得到资产UUID和mobile-app字段；owner/类型/版本/服务端编辑状态须由调用方fresh GET验证后才选择本地显示。
nonisolated struct LocalMediaRemoteCandidate: Equatable, Sendable {
    let assetID: UUID
    let metadata: LocalMediaMobileMetadata
}

/// 只读展示关联的唯一元数据候选；不能作为备份完成/原片一致性/设备空间清理证据。
nonisolated enum LocalMediaMatch: Equatable, Sendable {
    case candidate(LocalMediaRemoteCandidate), noMatch, ambiguous, sourceChanged, insufficientMetadata

    /// expected为当前关联计划观察的本机身份，snapshot为fresh快照；candidates来自同认证范围，调用方仍须fresh资产/代际校验。
    static func resolve(expected: LocalPhotoIdentity, snapshot: LocalPhotoSnapshot,
                        candidates: [LocalMediaRemoteCandidate]) throws -> Self
    {
        guard expected == snapshot.identity else { return .sourceChanged }
        guard snapshot.supportsCurrentMetadataMatch, let local = try snapshot.mobileMetadata() else { return .insufficientMetadata }
        let matches = candidates.filter { $0.metadata == local }
        guard matches.count == 1 else { return matches.isEmpty ? .noMatch : .ambiguous }
        return .candidate(matches[0])
    }
}
