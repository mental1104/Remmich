import Foundation
import Testing
@testable import Remmich

/// 只读本地展示关联，合成Cloud ID/日期/位置覆盖官方元组语义；不读取媒体、不生成备份成功或清理决定。
@Suite("Local media metadata association")
struct LocalMediaMatchTests {
    /// 匹配元数据PUT会改变资产updatedAt，但时间线缩略图版本仍是max(createdAt,fileCreatedAt)。
    @Test func assetUpdateDoesNotReplaceDisplayVersion() throws {
        let id = UUID(), owner = UUID()
        let display = Date(timeIntervalSince1970: 200)
        let updated = Date(timeIntervalSince1970: 300)
        let remote = LocalMediaRemoteAsset(id: id, ownerId: owner, type: "IMAGE", isTrashed: false, isOffline: false,
                                           isEdited: false, checksum: Data(repeating: 1, count: 20).base64EncodedString(), updatedAt: updated,
                                           createdAt: display, fileCreatedAt: Date(timeIntervalSince1970: 100))
        let value = try #require(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: owner.uuidString,
                                                                local: localMediaSnapshot().identity, source: .mobileMetadata))
        #expect(value.remoteRevision == updated && value.displayRevision == display)
        #expect(value.matchesDisplayRevision(display) && !value.matchesDisplayRevision(updated))
        let restored = try JSONDecoder().decode(LocalMediaAssociation.self, from: JSONEncoder().encode(value))
        #expect(restored == value && restored.matchesDisplayRevision(display))
    }

    /// wire真实创建/拍摄时间用于显示键；新字段的坏日期不能被吞成nil再猜显示版本。
    @Test func displayVersionDecodesFromAssetDates() throws {
        let id = UUID(), owner = UUID()
        var body: [String: Any] = ["id": id.uuidString, "ownerId": owner.uuidString, "type": "IMAGE",
                                   "updatedAt": "2026-11-27T10:00:00Z", "createdAt": "2024-01-01T00:00:00Z",
                                   "fileCreatedAt": "2023-12-31T09:42:00Z"]
        let value = try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(value.displayRevision == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(value.displayRevision != value.updatedAt)
        body["createdAt"] = "invalid"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: JSONSerialization.data(withJSONObject: body))
        }
    }

    /// 本机时间只按官方整数秒规范化；编辑后的current只要调整时间一致也能关联，不被原片备份政策误拒绝。
    @Test(arguments: [false, true])
    func matchesCurrentRepresentationIncludingEdits(_ edited: Bool) throws {
        let snapshot = localMediaSnapshot(adjustmentTime: edited ? Date(timeIntervalSince1970: 20.75) : nil, hasAdjustments: edited)
        let metadata = try snapshot.mobileMetadata()
        let fields = try #require(metadata)
        #expect(fields.createdAt == Date(timeIntervalSince1970: 10))
        #expect(fields.adjustmentTime == (edited ? Date(timeIntervalSince1970: 20) : nil))
        let candidate = LocalMediaRemoteCandidate(assetID: UUID(), metadata: fields)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: [candidate]) == .candidate(candidate))
    }

    /// Cloud ID、创建/调整时间及坐标每一项都精确比较；null不等于0，remote小数差异不能再截秒后当相等。
    @Test(arguments: ["cloud", "created", "adjustment", "latitude", "longitude", "nil-location"])
    func anyTupleDifferencePreventsAssociation(_ mode: String) throws {
        let snapshot = localMediaSnapshot(adjustmentTime: Date(timeIntervalSince1970: 20.75), hasAdjustments: true, latitude: 1, longitude: 2)
        let fields = try LocalMediaMobileMetadata(cloudId: mode == "cloud" ? "synthetic:cloud:other" : "synthetic:cloud:content",
                                                  createdAt: Date(timeIntervalSince1970: mode == "created" ? 10.001 : 10),
                                                  adjustmentTime: mode == "adjustment" ? nil : Date(timeIntervalSince1970: 20),
                                                  latitude: mode == "latitude" ? 0 : mode == "nil-location" ? nil : 1,
                                                  longitude: mode == "longitude" ? 2.000000001 : 2)
        let candidate = LocalMediaRemoteCandidate(assetID: UUID(), metadata: fields)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: [candidate]) == .noMatch)
    }

    /// 同UUID重复记录与不同UUID重复元组都保持歧义，不能拿第一项当作确定的本地照片关联。
    @Test(arguments: [false, true])
    func duplicateCandidatesAreAmbiguous(_ differentIDs: Bool) throws {
        let snapshot = localMediaSnapshot()
        let metadata = try snapshot.mobileMetadata()
        let fields = try #require(metadata)
        let first = LocalMediaRemoteCandidate(assetID: UUID(), metadata: fields)
        let second = LocalMediaRemoteCandidate(assetID: differentIDs ? UUID() : first.assetID, metadata: first.metadata)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: [first, second]) == .ambiguous)
    }

    /// 元数据版本或对象身份已变则拒绝旧观察；没有创建日期或缺少编辑时间都不能用nil字段假造确定匹配。
    @Test func changedOrIncompleteSnapshotsCannotAssociate() throws {
        let snapshot = localMediaSnapshot()
        let changed = LocalPhotoIdentity(localIdentifier: snapshot.identity.localIdentifier, modificationDate: Date(timeIntervalSince1970: 30), mediaKind: .image)
        #expect(try LocalMediaMatch.resolve(expected: changed, snapshot: snapshot, candidates: []) == .sourceChanged)
        let noCreation = localMediaSnapshot(creationDate: nil)
        #expect(try LocalMediaMatch.resolve(expected: noCreation.identity, snapshot: noCreation, candidates: []) == .insufficientMetadata)
        let unknownEdit = localMediaSnapshot(hasAdjustments: true)
        #expect(try LocalMediaMatch.resolve(expected: unknownEdit.identity, snapshot: unknownEdit, candidates: []) == .insufficientMetadata)
    }

    /// 失败/缺失/不完整映射不等于成功的Cloud ID；这些状态只触发远端显示回退，不伪造另一张照片。
    @Test(arguments: [LocalPhotoCloudIdentity.unavailable, .failed, .incomplete])
    func unresolvedCloudIdentityCannotAssociate(_ identity: LocalPhotoCloudIdentity) throws {
        let snapshot = localMediaSnapshot().withCloudIdentity(identity)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: []) == .insufficientMetadata)
    }

    /// LivePhoto still与RAW+JPEG可以关联同一个Photos对象的current表示；决策没有动态原片/备份完整性含义。
    @Test(arguments: [false, true])
    func representationAssociationDoesNotRequireOriginalResourceShape(_ live: Bool) throws {
        let resources = [localMediaResource(role: .originalPhoto), localMediaResource(role: live ? .pairedVideo : .alternatePhoto)]
        let snapshot = localMediaSnapshot(kind: live ? .livePhoto : .image, resources: resources)
        let metadata = try snapshot.mobileMetadata()
        let fields = try #require(metadata)
        let candidate = LocalMediaRemoteCandidate(assetID: UUID(), metadata: fields)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: [candidate]) == .candidate(candidate))
    }

    /// 官方toJson使用null-aware map entry省略空字段；仅这四个已知nullable字段的缺失/null兼容，iCloudId仍必需。
    @Test func decodesOfficialOmittedAndExplicitNullFields() throws {
        let omitted = try decodeLocalMediaMetadata(#"{"iCloudId":"synthetic:cloud:content"}"#)
        let explicit = try decodeLocalMediaMetadata(#"{"iCloudId":"synthetic:cloud:content","createdAt":null,"adjustmentTime":null,"latitude":null,"longitude":null}"#)
        #expect(omitted == explicit && omitted.createdAt == nil && omitted.adjustmentTime == nil && omitted.latitude == nil && omitted.longitude == nil)
    }

    /// 使用真实wire字段iCloudId和字符串坐标；remote时间保留微秒，不能把坏值/高精度值抹成nil或整秒。
    @Test func decodesWireWithoutLosingFractionalOrOffsetTime() throws {
        let value = try decodeLocalMediaMetadata(#"{"iCloudId":"synthetic:cloud:content","createdAt":"1970-01-01T00:00:10.000001Z","adjustmentTime":"1970-01-01T01:00:20+01:00","latitude":"1.25","longitude":"-2.5"}"#)
        #expect(value.createdAt != Date(timeIntervalSince1970: 10))
        #expect(value.adjustmentTime == Date(timeIntervalSince1970: 20))
        #expect(value.latitude == 1.25 && value.longitude == -2.5)
    }

    /// 非空坏日期/错误类型/非法坐标必须使整个metadata解码失败，不能与本机nil相等后误关联。
    @Test(arguments: [
        #"{}"#, #"{"cloudId":"synthetic:cloud:content"}"#, #"{"iCloudId":""}"#, #"{"iCloudId":"synthetic:cloud:"}"#,
        #"{"iCloudId":"synthetic:cloud:content","createdAt":"bad-date"}"#,
        #"{"iCloudId":"synthetic:cloud:content","adjustmentTime":"2026-11-24"}"#,
        #"{"iCloudId":"synthetic:cloud:content","createdAt":10}"#,
        #"{"iCloudId":"synthetic:cloud:content","latitude":"NaN"}"#,
        #"{"iCloudId":"synthetic:cloud:content","longitude":"inf"}"#,
        #"{"iCloudId":"synthetic:cloud:content","latitude":"91"}"#,
        #"{"iCloudId":"synthetic:cloud:content","longitude":"180.0001"}"#,
        #"{"iCloudId":"synthetic:cloud:content","latitude":1.0}"#,
    ])
    func rejectsInvalidWireRatherThanMatchingNull(_ json: String) {
        #expect(throws: (any Error).self) { try decodeLocalMediaMetadata(json) }
    }
}

/// 只含合成公开字段；参数对应真实Photos观察值，默认创建时间带小数以独立验证官方截秒政策。
nonisolated func localMediaSnapshot(localIdentifier: String = "synthetic-local", modificationDate: Date? = Date(timeIntervalSince1970: 15),
                                    kind: LocalPhotoIdentity.MediaKind = .image, creationDate: Date? = Date(timeIntervalSince1970: 10.9),
                                    adjustmentTime: Date? = nil, hasAdjustments: Bool = false, latitude: Double? = nil, longitude: Double? = nil,
                                    resources: [LocalPhotoResourceDescriptor]? = nil) -> LocalPhotoSnapshot
{
    .init(identity: .init(localIdentifier: localIdentifier, modificationDate: modificationDate, mediaKind: kind),
          creationDate: creationDate, adjustmentTime: adjustmentTime, hasAdjustments: hasAdjustments, latitude: latitude, longitude: longitude,
          pixelWidth: 64, pixelHeight: 48, duration: kind == .video ? 2 : 0, mediaSubtypes: 0,
          resources: resources ?? [localMediaResource(role: kind == .video ? .originalVideo : .originalPhoto)],
          cloudIdentity: .resolved("synthetic:cloud:content"))
}

/// role为合成资源关系，不提供媒体内容或真实文件路径；只用于形态/版本变化测试。
nonisolated func localMediaResource(role: LocalPhotoResourceDescriptor.Role) -> LocalPhotoResourceDescriptor {
    .init(type: role == .pairedVideo ? 9 : 1, role: role, originalFilename: "synthetic.heic", uniformTypeIdentifier: "public.heic", pixelWidth: 64, pixelHeight: 48)
}

/// json为固定测试wire字节；直接调用实际领域decoder，不在fixture内重建比较算法。
private nonisolated func decodeLocalMediaMetadata(_ json: String) throws -> LocalMediaMobileMetadata {
    try JSONDecoder().decode(LocalMediaMobileMetadata.self, from: Data(json.utf8))
}
