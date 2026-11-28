import Foundation
import OSLog

/// 导出前整批核查；iCloud元数据交集直接跳过，未匹配新源交给既有Worker按原片摘要查重后备份。
@MainActor struct PhotoBackupContinuityChecker: PhotoBackupPreflighting {
    typealias DisplayAliasProvider = @MainActor @Sendable ([String], MediaAccountScope) async throws -> [PhotoBackupDisplayAliasEvidence]
    typealias MatchCheckpoint = @MainActor ([PhotoBackupJob]) async throws -> Void
    typealias VerifiedCheckpoint = @MainActor ([PhotoBackupJob], [LocalMediaAssociation]) async throws -> Void
    private let store: SQLiteLibraryIndexStore
    private let metadata: any LocalPhotoMetadataReading
    private let status: @MainActor (String.LocalizationValue) -> Void
    private let phaseProgress: @MainActor (Int, Int) -> Void
    private let checkpointMatches: MatchCheckpoint?
    private let verifiedCheckpoint: VerifiedCheckpoint?
    private var checkpointsEnabled: Bool {
        checkpointMatches != nil || verifiedCheckpoint != nil
    }

    private let displayAliases: DisplayAliasProvider?
    private let serverFirst: Bool
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "BackupPreflight")

    /// store复用当前账号数据库；metadata仅替换公开Photos元数据边界，不接触媒体字节。
    init(store: SQLiteLibraryIndexStore, metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader(),
         status: @escaping @MainActor (String.LocalizationValue) -> Void = { _ in },
         phaseProgress: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
         checkpointMatches: MatchCheckpoint? = nil, serverFirst: Bool = false, verifiedCheckpoint: VerifiedCheckpoint? = nil,
         displayAliases: DisplayAliasProvider? = nil)
    {
        self.store = store; self.metadata = metadata; self.status = status
        self.phaseProgress = phaseProgress; self.checkpointMatches = checkpointMatches
        self.serverFirst = serverFirst
        self.verifiedCheckpoint = verifiedCheckpoint
        self.displayAliases = displayAliases
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
        Self.logger.info("Preflight started jobs=\(jobs.count)")
        if let displayAliases {
            return try await planWithDisplayAliases(jobs: jobs, scope: scope, client: client, verificationIDs: verificationIDs,
                                                    provider: displayAliases, progress: progress, validateContext: validateContext)
        }
        guard let history = try await store.loadPhotoBackupHistory(scope: scope) else {
            return try await planFromServer(jobs: jobs, scope: scope, client: client, verificationIDs: verificationIDs,
                                            progress: progress, validateContext: validateContext)
        }
        try check(validateContext)
        let index = try await Self.makeIndex(history)
        try check(validateContext)
        var existing: Set<PhotoBackupSource> = []
        var checkpointed: Set<PhotoBackupSource> = []
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
            if checkpointsEnabled {
                let saved = try await checkpoint(batch.filter { existing.contains($0.source) }, matches: [:], snapshots: nil,
                                                 client: client, validateContext: validateContext)
                checkpointed.formUnion(saved)
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
                                            uploadMetadata: uploadMetadata.filter { allowed.contains($0.key) }, checkpointedExisting: checkpointed)
        try plan.validate(sources: Set(jobs.map(\.source)))
        try check(validateContext)
        return plan
    }

    /// 保存的展示别名只授予existing：当前Photos身份和fresh远端均重核，绝不写入字节证明表。
    /// 没有可复用本机身份的任务仍走原预检；已知身份的远端拒绝独立review，不能误当无映射上传。
    private func planWithDisplayAliases(jobs: [PhotoBackupJob], scope: MediaAccountScope, client: any PhotoBackupContinuityQuerying,
                                        verificationIDs: Set<UUID>, provider: DisplayAliasProvider,
                                        progress: @MainActor (Int, Int) -> Void,
                                        validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        var existing: Set<PhotoBackupSource> = [], review: Set<PhotoBackupSource> = [], checkpointed: Set<PhotoBackupSource> = []
        var remaining: [PhotoBackupJob] = []
        progress(0, jobs.count)
        for offset in stride(from: 0, to: jobs.count, by: 64) {
            try check(validateContext)
            let batch = Array(jobs[offset ..< min(offset + 64, jobs.count)])
            let ids = Array(Set(batch.map(\.source.localID))).sorted()
            let hints = try await provider(ids, scope)
            try check(validateContext)
            guard hints.count <= ids.count, Set(hints.map(\.work.localID)).count == hints.count,
                  hints.allSatisfy({ ids.contains($0.work.localID) && $0.work.localID == $0.association.localIdentity.localIdentifier })
            else { throw PhotoBackupContinuityError.incompleteResponse }
            let byLocal = Dictionary(uniqueKeysWithValues: hints.map { ($0.work.localID, $0) })
            let snapshots = try await metadata.snapshots(for: ids, validateContext: validateContext)
            try check(validateContext)
            guard Set(snapshots.map(\.identity.localIdentifier)).count == snapshots.count,
                  snapshots.allSatisfy({ ids.contains($0.identity.localIdentifier) }) else { throw PhotoBackupContinuityError.incompleteResponse }
            let before = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.localIdentifier, $0) })
            var accepted: [PhotoBackupJob] = []
            for job in batch {
                try check(validateContext)
                let source = job.source
                guard let hint = byLocal[source.localID], let snapshot = before[source.localID],
                      hint.work.result == .matched, hint.work.reason == .matched,
                      hint.association.source == .exactCloudIdentity,
                      hint.association.localIdentity == snapshot.identity,
                      snapshot.identity.modificationDate == source.modifiedAt,
                      Self.sourceKindMatches(source.kind, snapshot.identity.mediaKind),
                      case let .resolved(cloud) = snapshot.cloudIdentity, cloud == hint.work.cloudID,
                      hint.work.identityVersion == LocalPhotoDisplayReconciler.identityVersion(snapshot)
                else { remaining.append(job); continue }
                let remote: LocalMediaRemoteAsset
                do { remote = try await client.localMediaAsset(hint.association.remoteID.uuidString) }
                catch LocalMediaCandidateError.inaccessible { try check(validateContext); review.insert(source); continue }
                try check(validateContext)
                guard remote.isOffline == false, remote.checksum == hint.association.checksum,
                      LocalMediaAssociation.verified(remote: remote, requestedID: hint.association.remoteID, ownerID: scope.userID,
                                                     local: snapshot.identity, source: .exactCloudIdentity, prefersCurrentPhotos: true) != nil
                else { review.insert(source); continue }
                accepted.append(job)
            }
            if !accepted.isEmpty {
                let acceptedIDs = Array(Set(accepted.map(\.source.localID))).sorted()
                let current = try await metadata.snapshots(for: acceptedIDs, validateContext: validateContext)
                try check(validateContext)
                guard current.count == acceptedIDs.count, Set(current.map(\.identity.localIdentifier)) == Set(acceptedIDs),
                      current.allSatisfy({ before[$0.identity.localIdentifier] == $0 }) else { throw LocalMediaMetadataError.sourceChanged }
                // Photos复核期间服务端快照可能撤销别名；提交前重新读取同一原子proof，不混合旧/新工作行。
                try check(validateContext)
                let refreshed = try await provider(acceptedIDs, scope)
                try check(validateContext)
                guard refreshed.count == acceptedIDs.count, Set(refreshed.map(\.work.localID)) == Set(acceptedIDs),
                      refreshed.allSatisfy({ value in
                          guard let initial = byLocal[value.work.localID] else { return false }
                          return value.work.result == .matched && value.work.reason == .matched
                              && value.association == initial.association
                              && value.work.localID == value.association.localIdentity.localIdentifier
                              && value.work.cloudID == initial.work.cloudID
                              && value.work.identityVersion == initial.work.identityVersion
                      }) else { throw LocalMediaMetadataError.sourceChanged }
                // associations保持空：即使checksum字段相同，也未读取本轮原片，不能升级强关联/上传回执。
                let saved = try await checkpoint(accepted, matches: [:], snapshots: before, associations: [],
                                                 client: client, validateContext: validateContext)
                checkpointed.formUnion(saved)
                existing.formUnion(accepted.map(\.source))
            }
            progress(existing.count + review.count, jobs.count)
            await Task.yield()
        }
        let remainingPlan: PhotoBackupPreflightPlan
        if remaining.isEmpty {
            remainingPlan = .init(allowed: [], existing: [], review: [])
        } else {
            let oldChecker = PhotoBackupContinuityChecker(store: store, metadata: metadata, status: status, phaseProgress: phaseProgress,
                                                          checkpointMatches: checkpointMatches, serverFirst: serverFirst, verifiedCheckpoint: verifiedCheckpoint)
            let alreadyClassified = existing.count + review.count
            remainingPlan = try await oldChecker.plan(jobs: remaining, scope: scope, client: client, verificationIDs: verificationIDs,
                                                      progress: { done, _ in progress(alreadyClassified + done, jobs.count) }, validateContext: validateContext)
        }
        let result = PhotoBackupPreflightPlan(allowed: remainingPlan.allowed, existing: existing.union(remainingPlan.existing),
                                              review: review.union(remainingPlan.review), uploadMetadata: remainingPlan.uploadMetadata,
                                              checkpointedExisting: checkpointed.union(remainingPlan.checkpointedExisting))
        try result.validate(sources: Set(jobs.map(\.source)))
        try check(validateContext)
        progress(jobs.count, jobs.count)
        return result
    }

    private nonisolated static func sourceKindMatches(_ source: PhotoBackupSource.Kind, _ media: LocalPhotoIdentity.MediaKind) -> Bool {
        switch source {
        case .photo: media == .image
        case .video: media == .video
        // 一个展示关系不足证明Live动态成员或RAW/JPEG双原图，继续原有专用预检。
        case .livePhoto, .rawJPEG: false
        }
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
        guard !jobs.isEmpty else { return .init(allowed: [], existing: [], review: []) }
        var snapshots: [String: LocalPhotoSnapshot] = [:]
        var candidates: [String: [LocalMediaRemoteCandidate]]
        progress(0, jobs.count)
        phaseProgress(0, jobs.count)
        if serverFirst {
            // 远端完整流先建一次索引；随后每64项读取本机→fresh服务器核查→复核/落盘，无整库本机预扫。
            status("正在读取服务器匹配信息，可随时暂停。")
            phaseProgress(0, 0)
            let records = try await client.localMediaMetadataSnapshot()
            try check(validateContext)
            candidates = try await Self.makeServerCandidates(records, clouds: nil)
        } else {
            status("正在读取本机 iCloud 信息 0 / \(jobs.count) 项；不下载原片。")
            for offset in stride(from: 0, to: jobs.count, by: 64) {
                let ids = jobs[offset ..< min(offset + 64, jobs.count)].map(\.source.localID)
                let values = try await metadata.snapshots(for: ids, validateContext: validateContext)
                try check(validateContext)
                guard Set(values.map(\.identity.localIdentifier)).count == values.count,
                      values.allSatisfy({ ids.contains($0.identity.localIdentifier) }) else { throw PhotoBackupContinuityError.incompleteResponse }
                for value in values {
                    snapshots[value.identity.localIdentifier] = value
                }
                let done = min(offset + 64, jobs.count)
                phaseProgress(done, jobs.count)
                status("正在读取本机 iCloud 信息 \(done) / \(jobs.count) 项；不下载原片。")
                if done.isMultiple(of: 1024) || done == jobs.count {
                    Self.logger.info("Local metadata progress=\(done) total=\(jobs.count)")
                }
                await Task.yield()
            }
            let clouds = Set(snapshots.values.compactMap { snapshot -> String? in
                if case let .resolved(value) = snapshot.cloudIdentity {
                    return value
                }
                return nil
            })
            status("正在读取服务器匹配信息，可随时暂停。")
            phaseProgress(0, 0)
            Self.logger.info("Reading server metadata cloudCount=\(clouds.count)")
            let records = try await client.localMediaMetadata(cloudIDs: clouds)
            try check(validateContext)
            Self.logger.info("Server metadata received records=\(records.count)")
            candidates = try await Self.makeServerCandidates(records, clouds: clouds)
        }
        try check(validateContext)
        var existing: Set<PhotoBackupSource> = [], allowed: Set<PhotoBackupSource> = [], review: Set<PhotoBackupSource> = []
        var checkpointed: Set<PhotoBackupSource> = []
        var pending: [PhotoBackupJob] = []
        var pendingAssociations: [LocalMediaAssociation] = []
        var matches: [UUID: String] = [:]
        for (index, job) in jobs.enumerated() {
            try check(validateContext)
            // 未匹配新源可能整批走continue；每64项主动交还UI并发布一次进度，避免大图库形成同步热循环。
            if index.isMultiple(of: 64) {
                if !pending.isEmpty {
                    try await checkpointed.formUnion(checkpoint(pending, matches: matches, snapshots: snapshots, associations: pendingAssociations,
                                                                client: client, validateContext: validateContext))
                    pending.removeAll(keepingCapacity: true); matches.removeAll(keepingCapacity: true)
                    pendingAssociations.removeAll(keepingCapacity: true)
                }
                await Task.yield(); try check(validateContext)
                if serverFirst {
                    let ids = jobs[index ..< min(index + 64, jobs.count)].map(\.source.localID)
                    status("正在读取本机 iCloud 信息 \(index) / \(jobs.count) 项；不下载原片。")
                    let values = try await metadata.snapshots(for: ids, validateContext: validateContext)
                    try check(validateContext)
                    guard Set(values.map(\.identity.localIdentifier)).count == values.count,
                          values.allSatisfy({ ids.contains($0.identity.localIdentifier) }) else { throw PhotoBackupContinuityError.incompleteResponse }
                    for value in values {
                        snapshots[value.identity.localIdentifier] = value
                    }
                    phaseProgress(index, jobs.count)
                }
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
            guard let association = LocalMediaAssociation.verified(remote: remote, requestedID: candidate.assetID, ownerID: scope.userID,
                                                                   local: snapshot.identity, source: .mobileMetadata)
            else {
                review.insert(source); continue
            }
            existing.insert(source); matches[candidate.assetID] = cloud
            if checkpointsEnabled {
                pending.append(job)
                pendingAssociations.append(association)
            }
            await Task.yield()
        }
        if !pending.isEmpty {
            try await checkpointed.formUnion(checkpoint(pending, matches: matches, snapshots: snapshots, associations: pendingAssociations,
                                                        client: client, validateContext: validateContext))
            matches.removeAll(keepingCapacity: true)
        }
        var uploadMetadata: [PhotoBackupSource: LocalMediaMobileMetadata] = [:]
        for source in allowed {
            uploadMetadata[source] = try snapshots[source.localID]?.mobileMetadata()
        }
        let plan = PhotoBackupPreflightPlan(allowed: allowed, existing: existing, review: review,
                                            uploadMetadata: uploadMetadata, checkpointedExisting: checkpointed)
        try plan.validate(sources: Set(jobs.map(\.source)))
        // 许可新源与跳过交集都重读元数据，避免整批核查期间变化的源获得旧许可。
        let confirmed = Array(existing.subtracting(checkpointed).union(allowed))
        phaseProgress(0, confirmed.count)
        status("正在复核本机版本 0 / \(confirmed.count) 项。")
        for offset in stride(from: 0, to: confirmed.count, by: 64) {
            let ids = confirmed[offset ..< min(offset + 64, confirmed.count)].map(\.localID)
            let current = try await metadata.snapshots(for: ids, validateContext: validateContext)
            try check(validateContext)
            guard current.count == ids.count, Set(current.map(\.identity.localIdentifier)) == Set(ids),
                  current.allSatisfy({ snapshots[$0.identity.localIdentifier] == $0 }) else { throw LocalMediaMetadataError.sourceChanged }
            status("正在复核本机版本 \(min(offset + 64, confirmed.count)) / \(confirmed.count) 项。")
            phaseProgress(min(offset + 64, confirmed.count), confirmed.count)
        }
        // 已完成整批分类才保存ID匹配依据；字节校验始终为false，部分写入失败不发放任何上传许可。
        let ids = Array(matches.keys)
        status("正在保存匹配结果 0 / \(ids.count) 项。")
        phaseProgress(0, ids.count)
        for offset in stride(from: 0, to: ids.count, by: 64) {
            try check(validateContext)
            let batch = ids[offset ..< min(offset + 64, ids.count)]
            try await client.recordICloudMatches(Dictionary(uniqueKeysWithValues: batch.compactMap { id in matches[id].map { (id, $0) } }))
            try check(validateContext)
            status("正在保存匹配结果 \(min(offset + 64, ids.count)) / \(ids.count) 项。")
            phaseProgress(min(offset + 64, ids.count), ids.count)
        }
        Self.logger.info("Preflight finished matched=\(existing.count) allowed=\(allowed.count) review=\(review.count)")
        return plan
    }

    /// 完整远端候选流之后，只提交已fresh核验的有限匹配批次；先复核本机版本、确认标记，再原子保存任务。
    /// 部分完成可冷恢复为existing，但不会授权任何未完成源上传；账号/权限变化和取消不吞错误。
    private func checkpoint(_ jobs: [PhotoBackupJob], matches: [UUID: String], snapshots: [String: LocalPhotoSnapshot]?, associations: [LocalMediaAssociation] = [],
                            client: any PhotoBackupContinuityQuerying, validateContext: @MainActor () throws -> Void) async throws -> Set<PhotoBackupSource>
    {
        guard checkpointsEnabled, !jobs.isEmpty else { return [] }
        try check(validateContext)
        let ids = jobs.map(\.source.localID)
        let current = try await metadata.snapshots(for: ids, validateContext: validateContext)
        try check(validateContext)
        guard current.count == ids.count, Set(current.map(\.identity.localIdentifier)) == Set(ids) else { throw LocalMediaMetadataError.sourceChanged }
        let sources = Dictionary(uniqueKeysWithValues: jobs.map { ($0.source.localID, $0.source) })
        guard current.allSatisfy({ value in
            if let snapshots {
                return snapshots[value.identity.localIdentifier] == value
            }
            guard let source = sources[value.identity.localIdentifier], source.modifiedAt == value.identity.modificationDate else { return false }
            return (source.kind == .photo && value.identity.mediaKind == .image) || (source.kind == .video && value.identity.mediaKind == .video)
        }) else { throw LocalMediaMetadataError.sourceChanged }
        if !matches.isEmpty {
            try await client.recordICloudMatches(matches)
            try check(validateContext)
        }
        if let verifiedCheckpoint {
            try await verifiedCheckpoint(jobs, associations)
        } else {
            try await checkpointMatches?(jobs)
        }
        try check(validateContext)
        Self.logger.info("Saved matching checkpoint jobs=\(jobs.count)")
        return Set(jobs.map(\.source))
    }

    /// records来自完整流，clouds限定本轮本机云标识；后台一次建立索引，坏值/范围外响应或取消均拒绝整批。
    @concurrent private static func makeServerCandidates(_ records: [LocalMediaRemoteMetadataRecord], clouds: Set<String>?) async throws -> [String: [LocalMediaRemoteCandidate]] {
        var candidates: [String: [LocalMediaRemoteCandidate]] = [:]
        let decoder = JSONDecoder()
        for record in records {
            try Task.checkCancellation()
            let value = try decoder.decode(LocalMediaMobileMetadata.self, from: record.value)
            guard clouds?.contains(value.cloudId) ?? true else { throw PhotoBackupContinuityError.incompleteResponse }
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
