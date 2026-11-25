import Foundation

/// 本机Live Photo的远端配对身份；只证明fresh详情与既有关联一致，仍须比较实际本机motion字节。
nonisolated struct LocalLivePhotoRemotePair: Equatable, Sendable {
    let stillID: UUID
    let motionID: UUID
    let ownerID: UUID
    let stillRevision: Date
    let motionRevision: Date
    let motionChecksum: String

    /// 所有字段都由verified校验产生，调用方不能用未检查的可选状态直接构造可用配对。
    private init(stillID: UUID, motionID: UUID, ownerID: UUID, stillRevision: Date, motionRevision: Date, motionChecksum: String) {
        self.stillID = stillID; self.motionID = motionID; self.ownerID = ownerID
        self.stillRevision = stillRevision; self.motionRevision = motionRevision; self.motionChecksum = motionChecksum
    }

    /// still/motion为两次fresh GET；关联必须是当前本机Live Photo，motion身份/状态/版本与SHA1全部已知。
    /// 返回nil表示不能确认配对；成功也不推断Photos current motion相同或已备份，调用方还须本机哈希和前后复核。
    static func verified(still: LocalMediaRemoteAsset, motion: LocalMediaRemoteAsset, association: LocalMediaAssociation,
                         ownerID: String, expectedMotionID: UUID) -> Self?
    {
        guard association.localIdentity.mediaKind == .livePhoto,
              let owner = UUID(uuidString: ownerID), still.livePhotoVideoId == expectedMotionID,
              LocalMediaAssociation.verified(remote: still, requestedID: association.remoteID, ownerID: ownerID,
                                             local: association.localIdentity, source: association.source,
                                             expectedChecksum: association.checksum) == association,
              motion.id == expectedMotionID, motion.id != still.id, motion.ownerId == owner, motion.type == "VIDEO",
              motion.isTrashed == false, motion.isOffline == false, motion.isEdited == false,
              let motionRevision = motion.updatedAt, motionRevision.timeIntervalSince1970.isFinite,
              let checksum = motion.checksum, let bytes = Data(base64Encoded: checksum), bytes.count == 20,
              bytes.base64EncodedString() == checksum else { return nil }
        return .init(stillID: still.id, motionID: motion.id, ownerID: owner, stillRevision: association.remoteRevision,
                     motionRevision: motionRevision, motionChecksum: checksum)
    }
}
