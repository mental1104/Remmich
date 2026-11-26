import Foundation

/// 导出前整批只读核查；历史未命中保持待核查，只有导入后新拍摄/新修改且远端元数据无关联的源可读原片。
@MainActor struct PhotoBackupContinuityChecker: PhotoBackupPreflighting {
    private let store: SQLiteLibraryIndexStore
    private let metadata: any LocalPhotoMetadataReading

    /// store复用当前账号数据库；metadata仅替换公开Photos元数据边界，不接触媒体字节。
    init(store: SQLiteLibraryIndexStore, metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader()) {
        self.store = store; self.metadata = metadata
    }

    /// jobs只含待执行版本；progress发布完成核查数，context在每次await前后验证取消、认证和端点代际。
    /// 完整核查成功才返回许可；任何失败均不允许Worker以部分结果开始上传。
    func plan(jobs: [PhotoBackupJob], scope: MediaAccountScope, client: any PhotoBackupContinuityQuerying,
              progress: @MainActor (Int, Int) -> Void,
              validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        try check(validateContext)
        guard let history = try await store.loadPhotoBackupHistory(scope: scope) else { throw PhotoBackupContinuityError.importRequired }
        try check(validateContext)
        let index = try await Self.makeIndex(history)
        try check(validateContext)
        var existing: Set<PhotoBackupSource> = []
        var review: Set<PhotoBackupSource> = []
        var newCandidates: [String: PhotoBackupSource] = [:]
        var done = 0
        progress(0, jobs.count)
        for offset in stride(from: 0, to: jobs.count, by: 64) {
            try check(validateContext)
            let batch = Array(jobs[offset ..< min(offset + 64, jobs.count)])
            let unresolved = batch.filter { index.byLocalID[$0.source.localID] == nil }
            let snapshots = try await metadata.snapshots(for: unresolved.map(\.source.localID), validateContext: validateContext)
            try check(validateContext)
            guard Set(snapshots.map(\.identity.localIdentifier)).count == snapshots.count else { throw PhotoBackupContinuityError.incompleteResponse }
            let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.localIdentifier, $0) })
            var queries: [PhotoBackupCachedChecksumQuery] = []
            var sources: [UUID: PhotoBackupSource] = [:]
            for job in batch {
                let source = job.source
                let snapshot = byID[source.localID]
                let cloud: String? = if let snapshot, case let .resolved(value) = snapshot.cloudIdentity {
                    value
                } else {
                    nil
                }
                if let query = index.query(for: source, cloudID: cloud) {
                    queries.append(query); sources[query.id] = source
                } else if index.byLocalID[source.localID] == nil, let cloud, index.byCloudID[cloud] == nil,
                          !index.ambiguousCloudIDs.contains(cloud), let snapshot,
                          snapshot.identity.modificationDate == source.modifiedAt,
                          let created = snapshot.creationDate, let modified = source.modifiedAt,
                          created > history.importedAt, modified > history.importedAt,
                          job.attempts == 0, job.failure == nil, job.primaryAssetID == nil, job.motionAssetID == nil,
                          job.rawReceipt == nil, job.jpegReceipt == nil
                {
                    // 云ID相同的新候选不能通过字典覆盖变成唯一；两者均留待核查。
                    if let previous = newCandidates.updateValue(source, forKey: cloud) {
                        review.insert(previous); review.insert(source)
                    }
                } else {
                    review.insert(source)
                }
            }
            let results = try await client.lookupBackupChecksums(queries)
            try check(validateContext)
            guard results.count == queries.count, Set(results.map(\.id)) == Set(queries.map(\.id)) else {
                throw PhotoBackupContinuityError.incompleteResponse
            }
            for result in results {
                guard let source = sources[result.id] else { throw PhotoBackupContinuityError.incompleteResponse }
                if case .existing = result.outcome {
                    existing.insert(source)
                } else {
                    // 历史未命中或在回收站都不是新增许可，绝不回退为下载原片后重传。
                    review.insert(source)
                }
            }
            done += batch.count; progress(done, jobs.count)
            await Task.yield()
        }
        let remote = try await client.localMediaMetadata(cloudIDs: Set(newCandidates.keys))
        try check(validateContext)
        var associatedClouds: Set<String> = []
        for record in remote {
            let value = try JSONDecoder().decode(LocalMediaMobileMetadata.self, from: record.value)
            associatedClouds.insert(value.cloudId)
        }
        var allowed: Set<PhotoBackupSource> = []
        for (cloud, source) in newCandidates {
            if associatedClouds.contains(cloud) || review.contains(source) {
                review.insert(source)
            } else {
                allowed.insert(source)
            }
        }
        let plan = PhotoBackupPreflightPlan(allowed: allowed, existing: existing, review: review)
        try plan.validate(sources: Set(jobs.map(\.source)))
        try check(validateContext)
        return plan
    }

    /// history最多20万项，索引构建移出UI线程；取消时不发布半份索引。
    @concurrent private static func makeIndex(_ history: PhotoBackupHistory) async throws -> PhotoBackupHistoryIndex {
        try Task.checkCancellation()
        let result = PhotoBackupHistoryIndex(history)
        try Task.checkCancellation()
        return result
    }

    /// context不替代Task取消；任一门禁失败立即终止，禁止用旧账号的查询结果发放许可。
    private func check(_ context: @MainActor () throws -> Void) throws {
        try Task.checkCancellation(); try context()
    }
}
