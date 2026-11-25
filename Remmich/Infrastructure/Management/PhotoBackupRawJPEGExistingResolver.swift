import Foundation

/// 双原图组织候选的只读解析器：完整本机SHA1→双checksum查询→双fresh详情→本机版本重验，不上传或下载媒体。
@MainActor struct PhotoBackupRawJPEGExistingResolver {
    private let reader: any PhotoBackupRawJPEGChecksumReading

    /// reader只替换Photos系统边界；lookup与详情始终使用调用方当前受限管理client。
    init(reader: any PhotoBackupRawJPEGChecksumReading = PhotoKitRawJPEGChecksumReader()) {
        self.reader = reader
    }

    /// source为完整扫描版本，ownerID是认证账号，check覆盖账号/端点/权限与调用者epoch。
    /// 只有两个独立existing UUID且详情全部一致才返回；未命中/回收站/不足为nil，未知HTTP/取消仍抛错。
    func resolve(_ source: PhotoBackupSource, using client: LibraryMutationClient, ownerID: String,
                 check: @MainActor () throws -> Void) async throws -> PhotoBackupRawJPEGExistingProof?
    {
        try Task.checkCancellation(); try check()
        guard let local = try await reader.checksumPair(for: source, validateContext: check) else { return nil }
        try Task.checkCancellation(); try check()
        guard local.source == source else { throw LocalPhotoChecksumError.sourceChanged }
        let rawQuery = LocalMediaChecksumQuery(digest: local.raw), jpegQuery = LocalMediaChecksumQuery(digest: local.jpeg)
        let results = try await client.lookupLocalMediaChecksums([rawQuery, jpegQuery])
        try Task.checkCancellation(); try check(); try reader.validateCurrent(local, validateContext: check)
        guard results.count == 2, let rawResult = results.first(where: { $0.id == rawQuery.id }),
              let jpegResult = results.first(where: { $0.id == jpegQuery.id }),
              case let .existing(rawID) = rawResult.outcome, case let .existing(jpegID) = jpegResult.outcome, rawID != jpegID else { return nil }
        let raw = try await client.asset(rawID.uuidString)
        try Task.checkCancellation(); try check(); try reader.validateCurrent(local, validateContext: check)
        let jpeg = try await client.asset(jpegID.uuidString)
        try Task.checkCancellation(); try check(); try reader.validateCurrent(local, validateContext: check)
        guard UUID(uuidString: raw.id) == rawID, UUID(uuidString: jpeg.id) == jpegID else { return nil }
        return .init(local: local, raw: raw, jpeg: jpeg, ownerID: ownerID)
    }
}
