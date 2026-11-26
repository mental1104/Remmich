import Foundation

/// 接续导入与预核查的安全错误分类；不包含照片标识、私有路径或数据库原始错误。
nonisolated enum PhotoBackupContinuityError: Error, Equatable, Sendable {
    case importRequired, invalidDatabase, wrongAccount, invalidHistory, incompleteResponse
}

/// 官方客户端曾观察到的本机版本；checksum只用来查询服务器，不能当作本轮原片或完整Live/RAW回执。
nonisolated struct PhotoBackupHistoryRecord: Codable, Sendable {
    let localID: String
    let cloudID: String?
    let checksum: String?
    let modifiedAt: Date?
}

/// 按当前认证namespace隔离的只读导入快照；导入时刻只划定可继续核查的新拍摄边界，不伪称原数据库导出日期。
nonisolated struct PhotoBackupHistory: Codable, Sendable {
    let version: Int
    let namespace: String
    let userID: String
    let importedAt: Date
    let records: [PhotoBackupHistoryRecord]

    /// scope必须是导入时的认证身份；所有记录保留缺失checksum，避免把缺项误认为新照片。
    func validate(scope: MediaAccountScope) throws {
        guard version == 1, namespace == scope.cacheNamespace, userID == scope.userID,
              importedAt.timeIntervalSince1970.isFinite, records.count <= 200_000,
              records.allSatisfy({ !$0.localID.isEmpty && $0.localID.utf8.count <= 4096 })
        else {
            throw PhotoBackupContinuityError.invalidHistory
        }
    }
}

/// 一次整批核查的完整分区；只有allowed源可进入原片导出，existing/review均不生成虚构上传成功回执。
nonisolated struct PhotoBackupPreflightPlan: Sendable {
    let allowed: Set<PhotoBackupSource>
    let existing: Set<PhotoBackupSource>
    let review: Set<PhotoBackupSource>

    /// sources是本轮实际queued源；必须一一覆盖且互斥，部分响应不能留下默认允许的尾队列。
    func validate(sources: Set<PhotoBackupSource>) throws {
        guard allowed.isDisjoint(with: existing), allowed.isDisjoint(with: review), existing.isDisjoint(with: review),
              allowed.union(existing).union(review) == sources else { throw PhotoBackupContinuityError.incompleteResponse }
    }
}

/// 只读网络核查端口；复用官方checksum查询和完整同步元数据，不上传媒体或改变官方同步检查点。
nonisolated protocol PhotoBackupContinuityQuerying: Sendable {
    func lookupBackupChecksums(_ queries: [PhotoBackupCachedChecksumQuery]) async throws -> [LocalMediaChecksumLookup]
    func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord]
}

extension LibraryMutationClient: PhotoBackupContinuityQuerying {}

/// Controller的导出前门禁；任务安全、账号代际和完整分区均由生产调用方继续验证。
@MainActor protocol PhotoBackupPreflighting: Sendable {
    /// jobs为实际待执行项；context必须在每次异步边界核对原账号/端点和取消，不允许发布迟到许可。
    func plan(jobs: [PhotoBackupJob], scope: MediaAccountScope, client: any PhotoBackupContinuityQuerying,
              verificationIDs: Set<UUID>,
              progress: @MainActor (Int, Int) -> Void,
              validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
}

/// 每次运行只构建一次本机ID索引；重复ID或checksum/版本不足的历史都进入review，不做逐项全库搜索。
nonisolated struct PhotoBackupHistoryIndex: Sendable {
    let byLocalID: [String: PhotoBackupHistoryRecord]
    let ambiguous: Set<String>
    let byCloudID: [String: PhotoBackupHistoryRecord]
    let ambiguousCloudIDs: Set<String>

    /// history为已验证账号的完整快照；重复ID一律保留为歧义，不以最后一行覆盖冲突。
    init(_ history: PhotoBackupHistory) {
        var values: [String: PhotoBackupHistoryRecord] = [:]
        var duplicates: Set<String> = []
        var clouds: [String: PhotoBackupHistoryRecord] = [:]
        var duplicateClouds: Set<String> = []
        for record in history.records {
            if values.updateValue(record, forKey: record.localID) != nil {
                duplicates.insert(record.localID)
            }
            if let cloud = record.cloudID, LocalMediaMobileMetadata.isUsableCloudID(cloud), clouds.updateValue(record, forKey: cloud) != nil {
                duplicateClouds.insert(cloud)
            }
        }
        byLocalID = values; ambiguous = duplicates
        byCloudID = clouds; ambiguousCloudIDs = duplicateClouds
    }

    /// 官方iOS把Photos修改时刻截为Int64秒；这里只按相同精度选择缓存查询候选，不冒充当前原片字节证明。
    /// source为当前版本，cloudID仅用于本机ID缺失时回退；歧义、跨秒变化或坏SHA1均不读取原片补哈希。
    func query(for source: PhotoBackupSource, cloudID: String? = nil) -> PhotoBackupCachedChecksumQuery? {
        let record = byLocalID[source.localID] ?? cloudID.flatMap { ambiguousCloudIDs.contains($0) ? nil : byCloudID[$0] }
        guard !ambiguous.contains(source.localID), let record,
              let modified = source.modifiedAt, let previous = record.modifiedAt,
              modified.timeIntervalSince1970.isFinite, previous.timeIntervalSince1970.isFinite,
              modified.timeIntervalSince1970.rounded(.towardZero) == previous.timeIntervalSince1970.rounded(.towardZero),
              let checksum = record.checksum, let bytes = Data(base64Encoded: checksum), bytes.count == 20,
              bytes.base64EncodedString() == checksum else { return nil }
        return try? .init(checksum: checksum)
    }
}
