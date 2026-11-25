import Foundation
import Testing
@testable import Remmich

/// 真实配对领域验证，不用still关联替motion猜测字节、版本或权限。
@Suite("Local Live Photo remote pair")
@MainActor struct LocalLivePhotoRemotePairTests {
    /// 同账号fresh still精确绑定motion且未编辑/离线/回收时才给出可继续比较本机哈希的配对。
    @Test func verifiedPairPreservesIndependentMotionVersionAndChecksum() throws {
        let fixture = liveRemoteFixture()
        let pair = try #require(LocalLivePhotoRemotePair.verified(still: fixture.still, motion: fixture.motion, association: fixture.association,
                                                                  ownerID: liveRemoteOwner.uuidString, expectedMotionID: liveRemoteMotionID))
        #expect(pair.stillID == liveRemoteStillID && pair.motionID == liveRemoteMotionID && pair.ownerID == liveRemoteOwner)
        #expect(pair.stillRevision == fixture.association.remoteRevision && pair.motionRevision == fixture.motion.updatedAt)
        #expect(pair.motionChecksum == Data(repeating: 2, count: 20).base64EncodedString())
        let changed = liveRemoteFixture(mode: "new-motion-version")
        let next = try #require(LocalLivePhotoRemotePair.verified(still: changed.still, motion: changed.motion, association: changed.association,
                                                                  ownerID: liveRemoteOwner.uuidString, expectedMotionID: liveRemoteMotionID))
        #expect(next != pair)
    }

    /// 缺失/冲突pair、旧still版本、普通图片及motion各类未知/危险字段都不能被默认成有效本机动态。
    @Test(arguments: ["pair-missing", "pair-wrong", "still-version", "still-checksum", "still-id", "still-owner", "still-type", "ordinary-photo",
                      "motion-id", "motion-owner", "motion-type", "trash", "offline", "edited", "unknown-trash", "unknown-offline", "unknown-edited",
                      "checksum-missing", "checksum-invalid", "version-missing", "version-infinite"])
    func unsafeRemotePairIsNotConfirmed(_ mode: String) {
        let fixture = liveRemoteFixture(mode: mode)
        #expect(LocalLivePhotoRemotePair.verified(still: fixture.still, motion: fixture.motion, association: fixture.association,
                                                  ownerID: liveRemoteOwner.uuidString, expectedMotionID: liveRemoteMotionID) == nil)
    }

    /// 真正DTO解码保留可选pair；缺失和null不伪造motion，坏UUID拒绝而非当作无配对。
    @Test(arguments: ["valid", "missing", "null", "invalid"])
    func freshDetailsDecodePairStrictly(_ mode: String) throws {
        var object: [String: Any] = ["id": liveRemoteStillID.uuidString, "ownerId": liveRemoteOwner.uuidString, "type": "IMAGE"]
        if mode == "valid" {
            object["livePhotoVideoId"] = liveRemoteMotionID.uuidString
        }
        if mode == "null" {
            object["livePhotoVideoId"] = NSNull()
        }
        if mode == "invalid" {
            object["livePhotoVideoId"] = "not-a-uuid"
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        if mode == "invalid" {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: bytes) }
        } else {
            let value = try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: bytes)
            #expect(value.livePhotoVideoId == (mode == "valid" ? liveRemoteMotionID : nil))
        }
    }
}

private nonisolated let liveRemoteOwner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let liveRemoteStillID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private nonisolated let liveRemoteMotionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private nonisolated let liveRemoteOtherID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

/// mode只改变一个不安全维度，association保持此前已确认的still身份，避免夹具替验证层计算预期。
private nonisolated func liveRemoteFixture(mode: String = "valid") -> (still: LocalMediaRemoteAsset, motion: LocalMediaRemoteAsset, association: LocalMediaAssociation) {
    let revision = Date(timeIntervalSince1970: 100.125)
    let stillChecksum = Data(repeating: 1, count: 20).base64EncodedString()
    let still = LocalMediaRemoteAsset(id: mode == "still-id" ? liveRemoteOtherID : liveRemoteStillID,
                                      ownerId: mode == "still-owner" ? liveRemoteOtherID : liveRemoteOwner,
                                      type: mode == "still-type" ? "VIDEO" : "IMAGE", isTrashed: false, isOffline: false, isEdited: false,
                                      checksum: mode == "still-checksum" ? Data(repeating: 9, count: 20).base64EncodedString() : stillChecksum,
                                      updatedAt: mode == "still-version" ? revision.addingTimeInterval(0.001) : revision,
                                      livePhotoVideoId: mode == "pair-missing" ? nil : mode == "pair-wrong" ? liveRemoteOtherID : liveRemoteMotionID)
    let motionRevision: Date? = mode == "version-missing" ? nil : mode == "version-infinite" ? Date(timeIntervalSince1970: .infinity)
        : Date(timeIntervalSince1970: mode == "new-motion-version" ? 201 : 200)
    let motion = LocalMediaRemoteAsset(id: mode == "motion-id" ? liveRemoteOtherID : liveRemoteMotionID,
                                       ownerId: mode == "motion-owner" ? liveRemoteOtherID : liveRemoteOwner,
                                       type: mode == "motion-type" ? "IMAGE" : "VIDEO", isTrashed: mode == "unknown-trash" ? nil : mode == "trash",
                                       isOffline: mode == "unknown-offline" ? nil : mode == "offline", isEdited: mode == "unknown-edited" ? nil : mode == "edited",
                                       checksum: mode == "checksum-missing" ? nil : mode == "checksum-invalid" ? "invalid" : Data(repeating: 2, count: 20).base64EncodedString(), updatedAt: motionRevision)
    let identity = LocalPhotoIdentity(localIdentifier: "synthetic-live", modificationDate: Date(timeIntervalSince1970: 55),
                                      mediaKind: mode == "ordinary-photo" ? .image : .livePhoto)
    let association = LocalMediaAssociation(remoteID: liveRemoteStillID, remoteRevision: revision, localIdentity: identity, checksum: stillChecksum, source: .mobileMetadata)
    return (still, motion, association)
}
