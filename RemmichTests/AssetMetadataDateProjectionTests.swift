import Foundation
import Testing
@testable import Remmich

/// 只确认当前详情与桶投影的纯领域测试；输入是独立合成JSON，不伪造提取任务完成或Photos/HTTP验收。
@Suite("Metadata capture-date projection")
struct AssetMetadataDateProjectionTests {
    /// 固定偏移和跨月墙上时间来自实际server字段；每次确认获得不同发布身份，并保留账号代际。
    @Test func confirmsFreshFieldsAndIssuesANewIdentity() throws {
        let instant = try projectionDate("2026-11-30T20:30:00.000Z")
        let snapshot = try projectionSnapshot()
        let generation = UUID()
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: generation))
        let again = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: generation))
        #expect(projection.id != again.id)
        #expect(projection.accountGeneration == generation)
        #expect(projection.assetID == projectionAssetID && projection.ownerID == projectionOwnerID)
        #expect(projection.capturedAt == instant)
        let expectedWall = try projectionDate("2026-12-01T02:15:00.000Z")
        #expect(projection.localDateTime == expectedWall)
        #expect(projection.visibility == "timeline")
    }

    /// EXIF-only和两种旧派生反例不能以PUT回执/updatedAt代替真实资产时间；缺/null/未知区也不给投影。
    @Test(arguments: ["exif-only", "file-pending", "wall-pending", "same-wall-new-offset", "same-instant-new-offset", "missing-file", "missing-wall", "missing-date", "missing-zone", "unknown-zone", "empty-zone", "trash", "wrong-id", "wrong-owner", "unknown-visibility", "unknown-type"])
    func rejectsMissingOrInconsistentCurrentFields(_ variant: String) throws {
        var file: String? = "2026-11-30T20:30:00.000Z"
        var wall: String? = "2026-12-01T02:15:00.000Z"
        var date: String? = "2026-11-30T20:30:00.000Z"
        var zone: String? = "UTC+5:45"
        let instant: Date
        switch variant {
        case "exif-only": file = "2026-10-01T20:30:00.000Z"; wall = "2026-10-02T02:15:00.000Z"
        case "file-pending": file = "2026-10-01T20:30:00.000Z"
        case "wall-pending": wall = "2026-10-02T02:15:00.000Z"
        case "same-wall-new-offset": file = "2026-11-30T18:15:00.000Z"; zone = "UTC+5:45"
        case "same-instant-new-offset": zone = "UTC+8"
        case "missing-file": file = nil
        case "missing-wall": wall = nil
        case "missing-date": date = nil
        case "missing-zone": zone = nil
        case "unknown-zone": zone = "Unknown/Synthetic"
        case "empty-zone": zone = "   "
        default: break
        }
        instant = try projectionDate("2026-11-30T20:30:00.000Z")
        let snapshot = try projectionSnapshot(file: file, wall: wall, date: date, zone: zone,
                                              id: variant == "wrong-id" ? "bad-id" : projectionAssetID,
                                              owner: variant == "wrong-owner" ? "bad-owner" : projectionOwnerID,
                                              visibility: variant == "unknown-visibility" ? "future-visibility" : "timeline",
                                              type: variant == "unknown-type" ? "SYNTHETIC" : "IMAGE", trashed: variant == "trash")
        #expect(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()) == nil)
    }

    /// 字段完全省略与显式null均不构成当前投影；历史updatedAt不能补回这些缺失信息。
    @Test(arguments: ["fileCreatedAt", "localDateTime", "exifInfo", "dateTimeOriginal", "timeZone"])
    func refusesAbsentFields(_ field: String) throws {
        let original = try projectionSnapshotData()
        let object = try JSONSerialization.jsonObject(with: original)
        var root = try #require(object as? [String: Any])
        if field == "dateTimeOriginal" || field == "timeZone" {
            var exif = try #require(root["exifInfo"] as? [String: Any])
            exif.removeValue(forKey: field)
            root["exifInfo"] = exif
        } else {
            root.removeValue(forKey: field)
        }
        let bytes = try JSONSerialization.data(withJSONObject: root)
        let snapshot = try JSONDecoder().decode(AssetMetadataSnapshot.self, from: bytes)
        let instant = try projectionDate("2026-11-30T20:30:00.000Z")
        #expect(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()) == nil)
    }

    /// 使用server实际IANA区名和拍摄时DST，不要求原用户固定偏移保留，也不从GPS猜时区。
    @Test(arguments: ["winter", "summer"])
    func usesTheActualServerZoneAtCapture(_ season: String) throws {
        let text = season == "winter" ? "2026-01-01T04:30:00.000Z" : "2026-07-01T04:30:00.000Z"
        let local = season == "winter" ? "2025-12-31T23:30:00.000Z" : "2026-07-01T00:30:00.000Z"
        let snapshot = try projectionSnapshot(file: text, wall: local, date: text, zone: "America/New_York")
        let instant = try projectionDate(text)
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()))
        let expectedWall = try projectionDate(local)
        #expect(projection.localDateTime == expectedWall)
    }

    /// 巴黎1900年有561秒历史偏移，截成9分钟会丢21秒；系统IANA数据必须完整进入投影。
    @Test func preservesHistoricalIANASeconds() throws {
        let text = "1900-01-01T12:00:00.000Z"
        let instant = try projectionDate(text)
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        #expect(paris.secondsFromGMT(for: instant) == 561)
        let snapshot = try projectionSnapshot(file: text, wall: "1900-01-01T12:09:21.000Z", date: text, zone: "Europe/Paris")
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()))
        let member = try projectionMember(capturedAt: text, hours: 561.0 / 3600)
        #expect(projection.matches(member))
    }

    /// 有限日期采用毫秒容差；2ms偏差以及非有限预期日期都不能被确认。
    @Test(arguments: ["one-ms", "two-ms", "nan", "infinity"])
    func boundsTheInstantTolerance(_ variant: String) throws {
        let snapshot = try projectionSnapshot()
        let base = try projectionDate("2026-11-30T20:30:00.000Z")
        let instant: Date = switch variant {
        case "one-ms": base.addingTimeInterval(0.001)
        case "two-ms": base.addingTimeInterval(0.002)
        case "nan": Date(timeIntervalSince1970: .nan)
        default: Date(timeIntervalSince1970: .infinity)
        }
        let projection = AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID())
        #expect((projection != nil) == (variant == "one-ms"))
    }

    /// 成员必须已由同query给出，允许已有stack信息但不制造代表图；身份/瞬间/墙上时间/可见性不符都拒绝。
    @Test(arguments: ["exact", "stack-cover", "wrong-id", "wrong-owner", "wrong-instant", "wrong-offset", "nan", "infinity", "overflow", "upload-order", "visibility"])
    func matchesOnlyAnExistingCompatibleTimelineMember(_ variant: String) throws {
        let instant = try projectionDate("2026-11-30T20:30:00.000Z")
        let snapshot = try projectionSnapshot()
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()))
        let hours: Double = switch variant {
        case "wrong-offset": 8
        case "nan": .nan
        case "infinity": .infinity
        case "overflow": .greatestFiniteMagnitude
        default: 5.75
        }
        var member = try projectionMember(id: variant == "wrong-id" ? projectionOtherID : projectionAssetID,
                                          owner: variant == "wrong-owner" ? projectionOtherID : projectionOwnerID,
                                          capturedAt: variant == "wrong-instant" ? "2026-11-30T20:31:00.000Z" : "2026-11-30T20:30:00.000Z",
                                          hours: hours, visibility: variant == "visibility" ? .archive : .timeline)
        if variant == "stack-cover" {
            member.stack = .init(id: projectionOtherID, assetCount: 3)
        }
        if variant == "upload-order" {
            member.usesUploadDate = true
        }
        #expect(projection.matches(member) == (variant == "exact" || variant == "stack-cover"))
    }

    /// visibility保持服务器实际值；非timeline投影不能把已归档/隐藏/锁定成员误作主时间线成员。
    @Test(arguments: ["archive", "hidden", "locked"])
    func retainsTheActualVisibility(_ visibility: String) throws {
        let snapshot = try projectionSnapshot(visibility: visibility)
        let instant = try projectionDate("2026-11-30T20:30:00.000Z")
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()))
        let actual: TimelineVisibility = switch visibility {
        case "archive": .archive
        case "hidden": .hidden
        default: .locked
        }
        let matching = try projectionMember(visibility: actual)
        let timeline = try projectionMember()
        #expect(projection.matches(matching))
        #expect(!projection.matches(timeline))
    }

    /// 桶解析沿用displayDate，在UTC比较墙上年月；跨年/历史月都不由拍摄UTC瞬间推桶。
    @Test(arguments: ["2026-12-01", "2026-12-01T00:00:00.000Z", "2026-11-01", "2025-12-01", "invalid"])
    func comparesOnlyTheExistingBucketMonth(_ value: String) throws {
        let instant = try projectionDate("2026-11-30T20:30:00.000Z")
        let snapshot = try projectionSnapshot()
        let projection = try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: instant, accountGeneration: UUID()))
        #expect(projection.occupiesMonth(.init(rawValue: value)) == value.hasPrefix("2026-12-"))
    }
}

private nonisolated let projectionAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let projectionOwnerID = "11111111-1111-4111-8111-111111111111"
private nonisolated let projectionOtherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

/// text是独立固定ISO毫秒夹具；返回Foundation日期，格式非法时抛错，不调用生产投影解析器。
private nonisolated func projectionDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let value = formatter.date(from: text) else { throw CocoaError(.coderInvalidValue) }
    return value
}

/// 参数均为固定ASCII合成值，file/wall/date/zone的nil明确产生JSON null；返回独立字节，不用生产模型编码器。
private nonisolated func projectionSnapshotData(file: String? = "2026-11-30T20:30:00.000Z", wall: String? = "2026-12-01T02:15:00.000Z",
                                                date: String? = "2026-11-30T20:30:00.000Z", zone: String? = "UTC+5:45",
                                                id: String = projectionAssetID, owner: String = projectionOwnerID,
                                                visibility: String = "timeline", type: String = "IMAGE", trashed: Bool = false) throws -> Data
{
    let fileValue = file.map { #""\#($0)""# } ?? "null"
    let wallValue = wall.map { #""\#($0)""# } ?? "null"
    let dateValue = date.map { #""\#($0)""# } ?? "null"
    let zoneValue = zone.map { #""\#($0)""# } ?? "null"
    return Data(#"{"id":"\#(id)","ownerId":"\#(owner)","type":"\#(type)","visibility":"\#(visibility)","isTrashed":\#(trashed),"originalFileName":"synthetic-date.jpg","updatedAt":"2026-12-02T00:00:00.000Z","fileCreatedAt":\#(fileValue),"localDateTime":\#(wallValue),"exifInfo":{"dateTimeOriginal":\#(dateValue),"timeZone":\#(zoneValue)}}"#.utf8)
}

/// 参数与projectionSnapshotData对应，只解码独立JSON夹具为真实Snapshot以运行确认规则。
private nonisolated func projectionSnapshot(file: String? = "2026-11-30T20:30:00.000Z", wall: String? = "2026-12-01T02:15:00.000Z",
                                            date: String? = "2026-11-30T20:30:00.000Z", zone: String? = "UTC+5:45",
                                            id: String = projectionAssetID, owner: String = projectionOwnerID,
                                            visibility: String = "timeline", type: String = "IMAGE", trashed: Bool = false) throws -> AssetMetadataSnapshot
{
    let data = try projectionSnapshotData(file: file, wall: wall, date: date, zone: zone, id: id, owner: owner, visibility: visibility, type: type, trashed: trashed)
    return try JSONDecoder().decode(AssetMetadataSnapshot.self, from: data)
}

/// 身份/日期/偏移/可见性均为独立桶输入；返回真实Summary，不调用生产projection工厂或映射代码造预期。
private nonisolated func projectionMember(id: String = projectionAssetID, owner: String = projectionOwnerID,
                                          capturedAt: String = "2026-11-30T20:30:00.000Z", hours: Double = 5.75,
                                          visibility: TimelineVisibility = .timeline) throws -> TimelineAssetSummary
{
    let instant = try projectionDate(capturedAt)
    return TimelineAssetSummary(id: id, ownerID: owner, capturedAt: instant, uploadedAt: instant,
                                localOffsetHours: hours, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                                isFavorite: false, visibility: visibility, livePhotoVideoID: nil, stack: nil,
                                projectionType: nil, thumbhash: nil, thumbnailRevision: instant)
}
