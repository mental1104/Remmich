import Foundation

/// 导出前整批核查；iCloud元数据交集直接跳过，未匹配新源交给既有Worker按原片摘要查重后备份。
@MainActor struct PhotoBackupContinuityChecker: PhotoBackupPreflighting {
    private let store: SQLiteLibraryIndexStore
    private let metadata: any LocalPhotoMetadataReading

    /// store复用当前账号数据库；metadata仅替换公开Photos元数据边界，不接触媒体字节。
    init(store: SQLiteLibraryIndexStore, metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader()) {
        self.store = store; self.metadata = metadata
    }

    /// jobs只含待执行版本；verificationIDs仅来自明确单项核查或已验证网络恢复，仍不能授权历史源。
    /// progress发布完成核查数，context在每次await前后验证取消、认证和端点代际。
    /// 完整核查成功才返回许可；任何失败均不允许Worker以部分结果开始上传。
    func plan(jobs: [PhotoBackupJob], scope: MediaAccountScope, client: any PhotoBackupContinuityQuerying,
              verificationIDs: Set<UUID> = [],
              progress: @MainActor (Int, Int) -> Void,
              validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        try check(validateContext)
        guard let history = try await store.loadPhotoBackupHistory(scope: scope) else {
            return try await planFromServer(jobs: jobs, scope: scope, client: client, verificationIDs: verificationIDs,
                                            progress: progress, validateContext: validateContext)
        }
        try check(validateContext)
        let index = try await Self.makeIndex(history)
        try check(validateContext)
        var existing: Set<PhotoBackupSource> = []
        var review: Set<PhotoBackupSource> = []
        var newCandidates: [String: PhotoBackupSource] = [:]
        var uploadMetadata: [PhotoBackupSource: LocalMediaMobileMetadata] = [:]
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
                          verificationIDs.contains(job.id) || (job.attempts == 0 && job.failure == nil && job.primaryAssetID == nil && job.motionAssetID == nil
                              && job.rawReceipt == nil && job.jpegReceipt == nil)
                {
                    // 云ID相同的新候选不能通过字典覆盖变成唯一；两者均留待核查。
                    if let previous = newCandidates.updateValue(source, forKey: cloud) {
                        review.insert(previous); review.insert(source)
                    }
                    uploadMetadata[source] = try snapshot.mobileMetadata()
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
                if case .existing = result.outcome, source.kind == .photo || source.kind == .video {
                    existing.insert(source)
                } else {
                    // 历史未命中、回收站或只有Live/RAW主体都不是完整证明，不回退为下载原片后重传。
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
        let plan = PhotoBackupPreflightPlan(allowed: allowed, existing: existing, review: review,
                                            uploadMetadata: uploadMetadata.filter { allowed.contains($0.key) })
        try plan.validate(sources: Set(jobs.map(\.source)))
        try check(validateContext)
        return plan
    }

    /// jobs为当前排队源；读取Photos结构与完整远端关联后返回交集/原片查重许可/待核查分区。
    /// 未匹配且未经尝试的新源允许进入Worker，实际下载仍受allowCloud约束，上传仍先做完整字节查重。
    /// verificationIDs只授权调用方明确核查的既有任务；未知部分上传不会因缺少导入历史而自动重试。
    /// client只在完整分区确认后写独立匹配标记；progress/context沿用原Coordinator的进度、取消和账号门禁。
    private func planFromServer(jobs: [PhotoBackupJob], scope: MediaAccountScope, client: any PhotoBackupContinuityQuerying,
                                verificationIDs: Set<UUID>,
                                progress: @MainActor (Int, Int) -> Void,
                                validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        try check(validateContext)
        var snapshots: [String: LocalPhotoSnapshot] = [:]
        progress(0, jobs.count)
        for offset in stride(from: 0, to: jobs.count, by: 64) {
            let ids = jobs[offset ..< min(offset + 64, jobs.count)].map(\.source.localID)
            let values = try await metadata.snapshots(for: ids, validateContext: validateContext)
            try check(validateContext)
            guard Set(values.map(\.identity.localIdentifier)).count == values.count,
                  values.allSatisfy({ ids.contains($0.identity.localIdentifier) }) else { throw PhotoBackupContinuityError.incompleteResponse }
            for value in values {
                snapshots[value.identity.localIdentifier] = value
            }
            await Task.yield()
        }
        let clouds = Set(snapshots.values.compactMap { snapshot -> String? in
            if case let .resolved(value) = snapshot.cloudIdentity {
                return value
            }
            return nil
        })
        let records = try await client.localMediaMetadata(cloudIDs: clouds)
        try check(validateContext)
        let candidates = try await Self.makeServerCandidates(records, clouds: clouds)
        try check(validateContext)
        var existing: Set<PhotoBackupSource> = [], allowed: Set<PhotoBackupSource> = [], review: Set<PhotoBackupSource> = []
        var matches: [UUID: String] = [:]
        for (index, job) in jobs.enumerated() {
            try check(validateContext)
            // 未匹配新源可能整批走continue；每64项主动交还UI并发布一次进度，避免大图库形成同步热循环。
            if index.isMultiple(of: 64) {
                await Task.yield(); try check(validateContext)
            }
            defer {
                if (index + 1).isMultiple(of: 64) || index + 1 == jobs.count {
                    progress(index + 1, jobs.count)
                }
            }
            let source = job.source
            guard let snapshot = snapshots[source.localID], snapshot.identity.modificationDate == source.modifiedAt,
                  ((source.kind == .photo || source.kind == .rawJPEG) && snapshot.identity.mediaKind == .image)
                  || (source.kind == .video && snapshot.identity.mediaKind == .video)
                  || (source.kind == .livePhoto && snapshot.identity.mediaKind == .livePhoto)
            else { review.insert(source); continue }
            // 完整远端流没有该云关联，或本机尚无云ID时，字节查重仍能识别已有资源；不要求先导入旧数据库。
            let cloud: String? = if case let .resolved(value) = snapshot.cloudIdentity {
                value
            } else {
                nil
            }
            if cloud.flatMap({ candidates[$0] }) == nil {
                let untouched = job.attempts == 0 && job.failure == nil && job.primaryAssetID == nil && job.motionAssetID == nil
                    && job.rawReceipt == nil && job.jpegReceipt == nil
                if untouched || verificationIDs.contains(job.id) {
                    allowed.insert(source)
                } else {
                    review.insert(source)
                }
                continue
            }
            // 官方与自有来源可能保留不同版本；只要求当前公开元组唯一匹配，重复当前候选仍由resolve拒绝。
            guard let cloud, let values = candidates[cloud],
                  case let .candidate(candidate) = try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: values)
            else { review.insert(source); continue }
            let remote: LocalMediaRemoteAsset
            do { remote = try await client.localMediaAsset(candidate.assetID.uuidString) }
            catch LocalMediaCandidateError.inaccessible { try check(validateContext); review.insert(source); continue }
            try check(validateContext)
            guard LocalMediaAssociation.verified(remote: remote, requestedID: candidate.assetID, ownerID: scope.userID,
                                                 local: snapshot.identity, source: .mobileMetadata) != nil
            else {
                review.insert(source); continue
            }
            existing.insert(source); matches[candidate.assetID] = cloud
            await Task.yield()
        }
        var uploadMetadata: [PhotoBackupSource: LocalMediaMobileMetadata] = [:]
        for source in allowed {
            uploadMetadata[source] = try snapshots[source.localID]?.mobileMetadata()
        }
        let plan = PhotoBackupPreflightPlan(allowed: allowed, existing: existing, review: review, uploadMetadata: uploadMetadata)
        try plan.validate(sources: Set(jobs.map(\.source)))
        // 许可新源与跳过交集都重读元数据，避免整批核查期间变化的源获得旧许可。
        let confirmed = Array(existing.union(allowed))
        for offset in stride(from: 0, to: confirmed.count, by: 64) {
            let ids = confirmed[offset ..< min(offset + 64, confirmed.count)].map(\.localID)
            let current = try await metadata.snapshots(for: ids, validateContext: validateContext)
            try check(validateContext)
            guard current.count == ids.count, Set(current.map(\.identity.localIdentifier)) == Set(ids),
                  current.allSatisfy({ snapshots[$0.identity.localIdentifier] == $0 }) else { throw LocalMediaMetadataError.sourceChanged }
        }
        // 已完成整批分类才保存ID匹配依据；字节校验始终为false，部分写入失败不发放任何上传许可。
        let ids = Array(matches.keys)
        for offset in stride(from: 0, to: ids.count, by: 64) {
            try check(validateContext)
            let batch = ids[offset ..< min(offset + 64, ids.count)]
            try await client.recordICloudMatches(Dictionary(uniqueKeysWithValues: batch.compactMap { id in matches[id].map { (id, $0) } }))
            try check(validateContext)
        }
        return plan
    }

    /// records来自完整流，clouds限定本轮本机云标识；后台一次建立索引，坏值/范围外响应或取消均拒绝整批。
    @concurrent private static func makeServerCandidates(_ records: [LocalMediaRemoteMetadataRecord], clouds: Set<String>) async throws -> [String: [LocalMediaRemoteCandidate]] {
        var candidates: [String: [LocalMediaRemoteCandidate]] = [:]
        let decoder = JSONDecoder()
        for record in records {
            try Task.checkCancellation()
            let value = try decoder.decode(LocalMediaMobileMetadata.self, from: record.value)
            guard clouds.contains(value.cloudId) else { throw PhotoBackupContinuityError.incompleteResponse }
            candidates[value.cloudId, default: []].append(.init(assetID: record.assetID, metadata: value))
        }
        return candidates
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
