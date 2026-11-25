import Foundation

/// 已经由fresh详情确认的当前拍摄时间投影；只供同账号代际核对现有时间线成员，不代表后台队列完成。
/// 本模型不制造桶/成员、不推断GPS时区，也不改变堆叠或可见性过滤。
nonisolated struct AssetMetadataDateProjection: Identifiable, Equatable, Sendable {
    let id: UUID
    let assetID: String
    let ownerID: String
    let capturedAt: Date
    let localDateTime: Date
    let accountGeneration: UUID
    let visibility: String

    /// snapshot必须来自真实当前详情；expectedInstant为本次已确认日期的UTC瞬间，accountGeneration绑定发布上下文。
    /// 仅当资产时间、EXIF时间及server真实时区对应墙上时间一致时返回新身份投影；未知/缺省/旧派生返回nil。
    static func confirmed(_ snapshot: AssetMetadataSnapshot, expectedInstant: Date, accountGeneration: UUID) -> Self? {
        guard expectedInstant.timeIntervalSinceReferenceDate.isFinite,
              let assetID = UUID(uuidString: snapshot.id), let ownerID = UUID(uuidString: snapshot.ownerId),
              !snapshot.isTrashed, ["IMAGE", "VIDEO"].contains(snapshot.type),
              ["timeline", "archive", "hidden", "locked"].contains(snapshot.visibility),
              let capturedAt = AssetMetadataDateValue.parse(snapshot.fileCreatedAt),
              let localDateTime = AssetMetadataDateValue.parse(snapshot.localDateTime),
              let exif = snapshot.exifInfo, exif.containsDate, exif.containsTimeZone,
              let exifInstant = AssetMetadataDateValue.parse(exif.dateTimeOriginal),
              datesMatch(capturedAt, expectedInstant), datesMatch(exifInstant, expectedInstant),
              let zoneName = exif.timeZone?.trimmingCharacters(in: .whitespacesAndNewlines), !zoneName.isEmpty,
              let offset = serverOffsetSeconds(zoneName, at: capturedAt),
              datesMatch(localDateTime, capturedAt.addingTimeInterval(TimeInterval(offset))) else { return nil }
        return .init(id: UUID(), assetID: assetID.uuidString.lowercased(), ownerID: ownerID.uuidString.lowercased(),
                     capturedAt: capturedAt, localDateTime: localDateTime,
                     accountGeneration: accountGeneration, visibility: snapshot.visibility)
    }

    /// asset是相同query真实返回的现有成员；核对身份、可见性、拍摄瞬间与秒级墙上投影，不接受上传日期模式。
    /// 返回false只表示该成员不符合此投影，不能据此插入被stack或其他过滤条件隐藏的资产。
    func matches(_ asset: TimelineAssetSummary) -> Bool {
        guard let memberID = UUID(uuidString: asset.id), let expectedID = UUID(uuidString: assetID), memberID == expectedID,
              let memberOwner = UUID(uuidString: asset.ownerID), let expectedOwner = UUID(uuidString: ownerID), memberOwner == expectedOwner,
              asset.usesUploadDate != true, asset.localOffsetHours.isFinite,
              Self.datesMatch(asset.capturedAt, capturedAt),
              asset.visibility == timelineVisibility else { return false }
        let seconds = (asset.localOffsetHours * 3600).rounded()
        guard seconds.isFinite, (-86400.0 ... 86400.0).contains(seconds) else { return false }
        return Self.datesMatch(asset.capturedAt.addingTimeInterval(seconds), localDateTime)
    }

    /// bucket沿用已有displayDate解析；只比较UTC年月，不从输入字符串猜测或创建新的桶标识。
    func occupiesMonth(_ bucket: TimelineBucketID) -> Bool {
        guard let date = bucket.displayDate, date.timeIntervalSinceReferenceDate.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = calendar.dateComponents([.year, .month], from: localDateTime)
        let actual = calendar.dateComponents([.year, .month], from: date)
        return expected.year == actual.year && expected.month == actual.month
    }

    /// 根据已验证的官方visibility映射现有时间线枚举；未知值已在confirmed阶段拒绝。
    private var timelineVisibility: TimelineVisibility {
        switch visibility {
        case "timeline": .timeline
        case "archive": .archive
        case "hidden": .hidden
        case "locked": .locked
        default: .unknown(visibility)
        }
    }

    /// name为fresh服务端实际区名、instant为拍摄瞬间；IANA保留历史秒级偏移，只有固定区fallback为分钟解析。
    /// 未知区名返回nil，绝不使用当前设备时区或根据坐标推断。
    private static func serverOffsetSeconds(_ name: String, at instant: Date) -> Int? {
        if let zone = TimeZone(identifier: name) {
            let seconds = zone.secondsFromGMT(for: instant)
            return (-86400 ... 86400).contains(seconds) ? seconds : nil
        }
        guard let minutes = AssetMetadataDateValue.offset(name: name, at: instant) else { return nil }
        return minutes * 60
    }

    /// 两个日期必须有限且相差至多1ms；额外只容纳Date二进制表示的一个ULP，不扩大业务毫秒容差。
    private static func datesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        let left = lhs.timeIntervalSinceReferenceDate
        let right = rhs.timeIntervalSinceReferenceDate
        guard left.isFinite, right.isFinite else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 0.001 + max(left.ulp, right.ulp)
    }
}
