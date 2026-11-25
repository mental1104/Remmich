import Foundation

/// 元数据专用真实快照；与编辑/备份DTO隔离，保留服务端原始评分（包括旧版0），不猜测缺失字段。
nonisolated struct AssetMetadataSnapshot: Decodable, Equatable, Sendable {
    let id: String
    let ownerId: String
    let type: String
    let visibility: String
    let isTrashed: Bool
    let originalFileName: String
    let livePhotoVideoId: String?
    let updatedAt: String?
    let localDateTime: String?
    let exifInfo: Exif?

    /// 只读取本页需要的EXIF；presence标志区分“明确null”与“响应未返回字段”，防止假确认清空。
    struct Exif: Decodable, Equatable, Sendable {
        let dateTimeOriginal: String?
        let timeZone: String?
        let latitude: Double?
        let longitude: Double?
        let rating: Int?
        let containsDate: Bool
        let containsTimeZone: Bool
        let containsLocation: Bool
        let containsRating: Bool

        /// 官方EXIF响应键；其他相机/编辑信息不参与本页写入或被重新编码。
        private enum CodingKeys: String, CodingKey { case dateTimeOriginal, timeZone, latitude, longitude, rating }

        /// decoder为实际EXIF对象；保留null/缺省区别，错误类型拒绝而非隐式转换或清空。
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            dateTimeOriginal = try values.decodeIfPresent(String.self, forKey: .dateTimeOriginal)
            timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone)
            latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
            rating = try values.decodeIfPresent(Int.self, forKey: .rating)
            containsDate = values.contains(.dateTimeOriginal)
            containsTimeZone = values.contains(.timeZone)
            containsLocation = values.contains(.latitude) && values.contains(.longitude)
            containsRating = values.contains(.rating)
        }
    }
}

/// 成对的WGS84坐标；单轴零值合法，0/0虽被PUT接受但后续会按官方Null Island规则丢弃，不能用于清空。
/// 本模型保持官方请求范围，页面明确提示后续派生边界；只写服务端，不调用公共地理查询。
nonisolated struct AssetMetadataCoordinates: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    /// 返回无；拒绝非有限值及越界坐标，必须在发送任何HTTP前完成。
    func validate() throws {
        guard latitude.isFinite, longitude.isFinite, (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
            throw AssetMetadataError.invalidLocation
        }
    }
}

/// 用户明确选择的拍摄瞬间及固定UTC偏移；单项官方接口从ISO偏移派生timeZone，不接受独立IANA写字段。
nonisolated struct AssetMetadataDateValue: Equatable, Sendable {
    let instant: Date
    let offsetMinutes: Int

    /// 返回含毫秒和偏移的官方日期参数；非法日期/不可表达偏移失败，不用设备时区偷偷替换。
    func encodedValue() throws -> String {
        guard instant.timeIntervalSince1970.isFinite, (-62_135_596_800 ... 253_402_300_799.999).contains(instant.timeIntervalSince1970),
              (-18 * 60 ... 18 * 60).contains(offsetMinutes),
              let zone = TimeZone(secondsFromGMT: offsetMinutes * 60) else { throw AssetMetadataError.invalidDate }
        let year = Calendar(identifier: .gregorian).dateComponents(in: zone, from: instant).year ?? 0
        guard (1 ... 9999).contains(year) else { throw AssetMetadataError.invalidDate }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = zone
        return formatter.string(from: instant)
    }

    /// text来自服务器；兼容带/不带毫秒的标准ISO日期，无法识别时返回nil而非猜测本地时间。
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// name为服务端IANA或Luxon固定区名，instant用于历史DST换算；返回分钟偏移，未知不猜测。
    static func offset(name: String?, at instant: Date) -> Int? {
        guard var value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let zone = TimeZone(identifier: value) {
            return zone.secondsFromGMT(for: instant) / 60
        }
        value = value.uppercased()
        if ["UTC", "GMT", "Z"].contains(value) {
            return 0
        }
        if value.hasPrefix("UTC") || value.hasPrefix("GMT") {
            value.removeFirst(3)
        }
        guard let sign = value.first, sign == "+" || sign == "-" else { return nil }
        value.removeFirst()
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int?
        let minutes: Int?
        if parts.count == 1, value.count == 4 {
            hours = Int(value.prefix(2)); minutes = Int(value.suffix(2))
        } else {
            hours = parts.first.flatMap { Int($0) }
            minutes = parts.count == 1 ? 0 : parts.count == 2 ? Int(parts[1]) : nil
        }
        guard let hours, let minutes, (0 ... 18).contains(hours), (0 ... 59).contains(minutes), hours < 18 || minutes == 0 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 60 + minutes)
    }

    /// dateText为当前ISO日期，zoneName是可选EXIF区名；优先使用已知区名，否则只读取日期自己的偏移。
    static func initialOffset(dateText: String?, zoneName: String?, instant: Date) -> Int {
        if let offset = offset(name: zoneName, at: instant) {
            return offset
        }
        if dateText?.hasSuffix("Z") == true {
            return 0
        }
        return Self.offset(name: dateText.map { String($0.suffix(6)) }, at: instant) ?? 0
    }

    /// snapshot是写响应或真实重读；时间与固定偏移均须确认，不只比较服务器规范化后的UTC字符串。
    func isConfirmed(by snapshot: AssetMetadataSnapshot) -> Bool {
        guard let exif = snapshot.exifInfo, exif.containsDate, exif.containsTimeZone,
              let date = Self.parse(exif.dateTimeOriginal), abs(date.timeIntervalSince(instant)) <= 0.001,
              Self.offset(name: exif.timeZone, at: date) == offsetMinutes else { return false }
        return true
    }
}

/// 只有评分支持显式清空；keep不编码、set遵循当前官方-1/1–5语义，clear必须编码null。
nonisolated enum AssetMetadataRatingChange: Equatable, Sendable {
    case keep, set(Int), clear
}

/// 单项元数据补丁只持有用户选定字段；日期/坐标无法表达不受官方接口支持的null清空。
nonisolated struct AssetMetadataPatch: Encodable, Equatable, Sendable {
    var date: AssetMetadataDateValue?
    var location: AssetMetadataCoordinates?
    var rating: AssetMetadataRatingChange = .keep

    /// 返回是否没有任何明确变更；空补丁不能消费确认或触发HTTP。
    var isEmpty: Bool {
        date == nil && location == nil && rating == .keep
    }

    /// 返回无；提前拒绝无变更、非法日期/坐标以及写入语义不支持的0评分。
    func validate() throws {
        guard !isEmpty else { throw AssetMetadataError.noChanges }
        _ = try date?.encodedValue()
        try location?.validate()
        if case let .set(value) = rating, value != -1, !(1 ... 5).contains(value) {
            throw AssetMetadataError.invalidRating
        }
    }

    /// 官方单项PUT键；不包含描述、收藏、可见性、Live Photo关联或任意metadata键值。
    private enum CodingKeys: String, CodingKey { case dateTimeOriginal, latitude, longitude, rating }

    /// encoder只接收已经选定的字段；keep完全省略，只有评分clear发送null，其他属性永远不会被空值覆盖。
    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let date {
            try values.encode(date.encodedValue(), forKey: .dateTimeOriginal)
        }
        if let location {
            try values.encode(location.latitude, forKey: .latitude)
            try values.encode(location.longitude, forKey: .longitude)
        }
        switch rating {
        case .keep: break
        case let .set(value): try values.encode(value, forKey: .rating)
        case .clear: try values.encodeNil(forKey: .rating)
        }
    }

    /// snapshot为200响应/真实重读；所有选定字段必须实际存在且匹配，null和缺失不能混为一谈。
    func isConfirmed(by snapshot: AssetMetadataSnapshot) -> Bool {
        if let date, !date.isConfirmed(by: snapshot) {
            return false
        }
        if let location {
            guard let exif = snapshot.exifInfo, exif.containsLocation,
                  exif.latitude == location.latitude, exif.longitude == location.longitude else { return false }
        }
        switch rating {
        case .keep: return true
        case let .set(value): return snapshot.exifInfo?.containsRating == true && snapshot.exifInfo?.rating == value
        case .clear: return snapshot.exifInfo?.containsRating == true && snapshot.exifInfo?.rating == nil
        }
    }
}

/// 已确认的补丁绑定读取时快照及页面/账号代际；预检只能消费此身份，不能转移到新资源。
nonisolated struct AssetMetadataPlan: Identifiable, Sendable {
    let id = UUID()
    let baseline: AssetMetadataSnapshot
    let patch: AssetMetadataPatch
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 元数据页的安全本地错误，不携带原片路径、坐标或服务器正文。
nonisolated enum AssetMetadataError: LocalizedError {
    case noChanges, invalidDate, invalidLocation, invalidRating, notOwned, unavailable, reloadRequired, changedRemotely, trashed

    var errorDescription: String? {
        switch self {
        case .noChanges: "Choose at least one field to change."
        case .invalidDate: "Choose a valid date and UTC offset."
        case .invalidLocation: "Enter both coordinates: latitude -90 to 90, longitude -180 to 180."
        case .invalidRating: "Choose Rejected, 1 to 5 stars, or Clear rating. Zero is not a valid write value."
        case .notOwned: "Only the owner can change this asset's metadata."
        case .unavailable: "Connect to the current account before managing metadata."
        case .reloadRequired: "Reload the asset before reviewing another change."
        case .changedRemotely: "The asset changed since it was loaded. Reload and review your changes again."
        case .trashed: "Restore this asset from trash before changing metadata."
        }
    }
}
