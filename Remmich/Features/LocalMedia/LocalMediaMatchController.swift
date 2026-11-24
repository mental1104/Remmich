import Foundation
import Observation

/// 现有鉴权client的窄只读边界；上传/备份/媒体HTTP不属于本机显示关联。
nonisolated protocol LocalMediaMatchingReading: Sendable {
    /// cloudIDs完整不截断；只接收完整只读metadata流，不能ACK/reset或发布半截候选。
    func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord]
    /// id是候选远端UUID；返回绕过缓存的新鲜账号状态，缺字段仍由领域层拒绝。
    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset
    /// queries最多64项，只查SHA1；noMatch绝不触发上传。
    func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup]
}

extension LibraryMutationClient: LocalMediaMatchingReading {}

/// 显式前台本机关联扫描；账号代际隔离、批量有界，不将进度/哈希查重写成备份成功。
@MainActor @Observable final class LocalMediaMatchController {
    private(set) var running = false
    private(set) var total = 0
    private(set) var scanned = 0
    private(set) var metadataMatches = 0
    private(set) var checksumMatches = 0
    private(set) var unmatched = 0
    private(set) var metadataFailures = 0
    private(set) var enabled = false
    private(set) var revision = 0
    private(set) var permission = LocalPhotoLibraryAccess.unknown
    private(set) var status = "点击扫描，关联本机与Immich已有照片；不会上传或删除照片。"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private weak var manager: LibraryManagementController?
    @ObservationIgnored private var managerGeneration: UUID?
    @ObservationIgnored private var scope: MediaAccountScope?
    @ObservationIgnored private var access: LocalPhotoLibraryAccess?
    @ObservationIgnored private var associations: [UUID: LocalMediaAssociation] = [:]
    @ObservationIgnored private var restoredNamespace: String?
    @ObservationIgnored private var automaticGeneration: UUID?
    @ObservationIgnored private var permit = LocalMediaSavePermit()
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: LocalPhotoChangeMonitor?
    @ObservationIgnored private let inventory: any LocalPhotoInventoryReading
    @ObservationIgnored private let metadata: any LocalPhotoMetadataReading
    @ObservationIgnored private let checksum: any LocalPhotoChecksumReading
    @ObservationIgnored private let remoteOverride: (any LocalMediaMatchingReading)?
    @ObservationIgnored private let persistence: any LocalMediaAssociationPersisting
    @ObservationIgnored private let observeChanges: Bool

    /// 注入仅替换系统/网络来源；nil remote使用当前manager真实client，全部验证、统计与发布门禁仍执行。
    init(inventory: any LocalPhotoInventoryReading = PhotoKitLocalPhotoInventory(),
         metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader(),
         checksum: any LocalPhotoChecksumReading = PhotoKitCurrentResourceChecksumReader(),
         remote: (any LocalMediaMatchingReading)? = nil,
         persistence: any LocalMediaAssociationPersisting = LocalMediaAssociationStore(), observeChanges: Bool = true)
    {
        self.inventory = inventory; self.metadata = metadata; self.checksum = checksum; remoteOverride = remote
        self.persistence = persistence; self.observeChanges = observeChanges
    }

    /// 兼容在线管理宿主；需要离线恢复的media宿主使用显式scope重载，避免client缺失被当成退出登录。
    func configure(using manager: LibraryManagementController) {
        configure(using: manager, scope: manager.backupScope)
    }

    /// 显式scope来自真实media上下文；nil清登录。同namespace离线/路由变化取消旧网络，保留已验证本机关联。
    func configure(using manager: LibraryManagementController, scope nextScope: MediaAccountScope?) {
        guard self.manager !== manager || managerGeneration != manager.generation || scope != nextScope else {
            permission = inventory.authorization; return
        }
        invalidateRun()
        let changedScope = scope != nextScope
        self.manager = manager; managerGeneration = manager.generation; scope = nextScope
        if changedScope {
            associations = [:]; revision += 1; enabled = false; access = nil; restoredNamespace = nil
            total = 0; scanned = 0; metadataMatches = 0; checksumMatches = 0; unmatched = 0; metadataFailures = 0
            automaticGeneration = nil; monitor?.stop(); monitor = nil
        }
        permission = inventory.authorization
        status = nextScope == nil ? "请先连接Immich服务器。" : "启用后自动关联本机已有照片，优先本机显示和播放。"
    }

    /// 只返回同账号、同远端精确版本、当前授权范围未变化的已确认项；媒体读取前后仍须核实Photos源版本。
    func association(assetID: String, revision: Date) -> LocalMediaAssociation? {
        _ = self.revision
        guard enabled, scope != nil, let manager, managerGeneration == manager.generation,
              let access, inventory.authorization == access, let id = UUID(uuidString: assetID),
              let association = associations[id], association.remoteRevision == revision else { return nil }
        return association
    }

    /// 明确停止当前前台扫描；只保留此前已经完成fresh验证的内存关联，不宣称扫描完成。
    func cancel() {
        guard running else { return }
        invalidateRun()
        status = "扫描已停止；保留已确认关联，未完成项目不算匹配成功。"
    }

    /// root在media configure/前台恢复后调用；不弹Photos权限。相同代际只恢复/自动刷新一次，正在运行时复用任务。
    @discardableResult func restoreAndRefresh(using manager: LibraryManagementController, scope: MediaAccountScope?) -> Task<Void, Never>? {
        configure(using: manager, scope: scope)
        if let task {
            return task
        }
        if let changeTask {
            return changeTask
        }
        guard let scope else { return nil }
        if restoredNamespace == scope.cacheNamespace {
            if access != nil, inventory.authorization != access {
                sourcesChanged(); return changeTask
            }
            guard enabled, automaticGeneration != manager.generation, manager.client != nil,
                  inventory.authorization == .full || inventory.authorization == .limited else { return nil }
            automaticGeneration = manager.generation
            return startScan(using: manager, requestPermission: false)
        }
        let run = generation; let owner = manager.generation
        let operation = Task {
            defer {
                if generation == run {
                    task = nil
                }
            }
            do {
                let document = try await persistence.load(scope: scope)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                restoredNamespace = scope.cacheNamespace
                enabled = document?.enabled ?? false
                access = document?.access
                if enabled, document?.access == inventory.authorization {
                    associations = Dictionary(uniqueKeysWithValues: (document?.associations ?? []).map { ($0.remoteID, $0) })
                    publishCounts(); revision += 1
                }
                permission = inventory.authorization
                startMonitoringIfNeeded()
                guard enabled, automaticGeneration != owner, manager.client != nil, permission == .full || permission == .limited else { return }
                automaticGeneration = owner
                task = nil
                if let scan = startScan(using: manager, requestPermission: false) {
                    await scan.value
                }
            } catch {
                guard generation == run, manager.generation == owner else { return }
                status = "无法恢复本机关联：\(error.localizedDescription)。未覆盖已有资料。"
            }
        }
        task = operation; return operation
    }

    /// 仅用户操作改变启用配置；关闭立即失效关联并保存，启用后显式扫描可请求初次Photos授权。
    @discardableResult func setEnabled(_ value: Bool, using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard self.manager === manager, let scope else { return nil }
        invalidateRun(); enabled = value; associations = [:]; revision += 1; publishCounts()
        metadataFailures = 0
        access = nil; automaticGeneration = manager.generation
        if value {
            startMonitoringIfNeeded()
            if let scan = startScan(using: manager, requestPermission: true) {
                return scan
            }
        } else {
            monitor?.stop(); monitor = nil
        }
        let run = generation; let owner = manager.generation; let writePermit = permit
        let document = LocalMediaAssociationDocument(scope: scope, enabled: value, access: nil, associations: [])
        let operation = Task {
            do {
                let saved = try await persistence.save(document, scope: scope, permit: writePermit)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                guard saved else { return }
                status = value ? "已保存启用配置；连接服务器后自动匹配。" : "已关闭本机优先，不修改或删除任何照片。"
            } catch {
                guard generation == run else { return }
                status = "本次设置已改变，但配置保存失败：\(error.localizedDescription)。"
            }
            if generation == run {
                task = nil
            }
        }
        task = operation; return operation
    }

    /// 仅显式按钮调用；授权后有限批次读取metadata，再唯一匹配/本机SHA1及fresh GET，不请求Immich媒体。
    @discardableResult func scan(using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard enabled else { return setEnabled(true, using: manager) }
        return startScan(using: manager, requestPermission: true)
    }

    /// requestPermission只来自明确用户操作；自动刷新只检查当前已有授权，绝不主动弹框。
    private func startScan(using manager: LibraryManagementController, requestPermission: Bool) -> Task<Void, Never>? {
        guard self.manager === manager, !running, let scope, manager.backupScope == scope, let client = manager.client else { return nil }
        let remote: any LocalMediaMatchingReading = remoteOverride ?? client
        let owner = manager.generation
        automaticGeneration = owner
        let run = UUID(); generation = run; running = true
        permit.invalidate(); permit = LocalMediaSavePermit(); let writePermit = permit
        // 保留已确认映射供当前窗口/离线使用；本轮发现的变更由实际媒体reader复核，不把扫描进度当作完成。
        total = 0; scanned = 0; unmatched = 0; metadataFailures = 0
        status = "正在确认照片访问权限…"
        let operation = Task {
            defer {
                if generation == run {
                    running = false; task = nil
                }
            }
            do {
                try validate(manager, owner: owner, scope: scope, run: run)
                let setting = LocalMediaAssociationDocument(scope: scope, enabled: enabled, access: access, associations: Array(associations.values))
                let settingSaved = try await persistence.save(setting, scope: scope, permit: writePermit)
                try validate(manager, owner: owner, scope: scope, run: run)
                guard settingSaved else { throw CancellationError() }
                let permission: LocalPhotoLibraryAccess = if requestPermission {
                    await inventory.requestAuthorization()
                } else {
                    inventory.authorization
                }
                try validate(manager, owner: owner, scope: scope, run: run)
                self.permission = permission
                guard permission == .full || permission == .limited else { throw LocalMediaMetadataError.permission }
                access = permission
                startMonitoringIfNeeded()
                let validateContext: @MainActor () throws -> Void = { try self.validate(manager, owner: owner, scope: scope, run: run, expectedAccess: permission) }
                let ids = try await inventory.localIdentifiers(validateContext: validateContext)
                try validateContext()
                guard ids.count == Set(ids).count, ids.allSatisfy({ !$0.isEmpty }) else { throw LocalMediaMetadataError.invalidBatch }
                total = ids.count
                // 先只收集CloudID再读一次完整流，避免每64项反复下载整个metadata流，也不保留全库资源快照。
                var cloudIDs = Set<String>()
                for start in stride(from: 0, to: ids.count, by: 64) {
                    let batch = Array(ids[start ..< min(start + 64, ids.count)])
                    let snapshots = try await metadata.snapshots(for: batch, validateContext: validateContext)
                    try validateContext()
                    try validateSnapshots(snapshots, requested: batch)
                    for snapshot in snapshots {
                        if case let .resolved(id) = snapshot.cloudIdentity {
                            cloudIDs.insert(id)
                        }
                    }
                    status = "读取本机元数据 \(min(start + 64, ids.count))/\(total)…"
                    await Task.yield(); try validateContext()
                }
                status = "只读匹配Immich元数据…"
                var candidates: [String: [LocalMediaRemoteCandidate]] = [:]
                if !cloudIDs.isEmpty {
                    do {
                        let records = try await remote.localMediaMetadata(cloudIDs: cloudIDs)
                        try validateContext()
                        let decoded = try await metadataCandidates(records, validateContext: validateContext)
                        try validateContext()
                        candidates = decoded.candidates
                        metadataFailures = decoded.rejected
                    } catch {
                        // metadata只是独立证明来源；半截/不可用流不提供任何候选，当前合法上下文仍可用本机字节证明。
                        try validateContext()
                        if error is CancellationError {
                            throw error
                        }
                        if case LibraryWriteError.changedAccount = error {
                            throw error
                        }
                        if case LocalMediaMetadataError.sourceChanged = error {
                            throw error
                        }
                        if case LocalMediaMetadataError.permission = error {
                            throw error
                        }
                        metadataFailures += 1
                        status = "Immich元数据暂不可用，继续仅用本机校验和匹配。"
                    }
                }
                var confirmedRemoteIDs = Set<UUID>()
                for start in stride(from: 0, to: ids.count, by: 64) {
                    let batch = Array(ids[start ..< min(start + 64, ids.count)])
                    let snapshots = try await metadata.snapshots(for: batch, validateContext: validateContext)
                    try validateContext(); try validateSnapshots(snapshots, requested: batch)
                    var hashes: [(query: LocalMediaChecksumQuery, proof: LocalPhotoChecksumProof)] = []
                    for snapshot in snapshots {
                        try validateContext()
                        var confirmed = false
                        if case let .resolved(cloudID) = snapshot.cloudIdentity,
                           case let .candidate(candidate) = try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot, candidates: candidates[cloudID] ?? [])
                        {
                            let fresh = try await remote.localMediaAsset(candidate.assetID.uuidString)
                            try validateContext()
                            if let value = LocalMediaAssociation.verified(remote: fresh, requestedID: candidate.assetID, ownerID: scope.userID, local: snapshot.identity, source: .mobileMetadata) {
                                accept(value); confirmedRemoteIDs.insert(value.remoteID); confirmed = true
                            } else {
                                removeAssociation(candidate.assetID)
                            }
                        }
                        if !confirmed {
                            let outcome = try await checksum.checksum(for: snapshot, validateContext: validateContext)
                            try validateContext()
                            if case let .verified(proof) = outcome, proof.source == snapshot.withCloudIdentity(.unavailable) {
                                hashes.append((LocalMediaChecksumQuery(digest: proof.digest), proof))
                            } else {
                                unmatched += 1
                            }
                        }
                        scanned += 1
                        status = "已检查 \(scanned)/\(total)，仅确认安全可用关联。"
                    }
                    // 当前batch内最多64个本机证明；返回ID集合必须完全对应，noMatch/trashed只统计未确认。
                    if !hashes.isEmpty {
                        let lookups = try await remote.lookupLocalMediaChecksums(hashes.map(\.query))
                        try validateContext()
                        guard lookups.count == hashes.count, Set(lookups.map(\.id)) == Set(hashes.map(\.query.id)) else { throw LocalMediaMetadataError.invalidMetadata }
                        let byID = Dictionary(uniqueKeysWithValues: lookups.map { ($0.id, $0) })
                        for item in hashes {
                            guard let lookup = byID[item.query.id] else { throw LocalMediaMetadataError.invalidMetadata }
                            if case let .existing(id) = lookup.outcome {
                                let fresh = try await remote.localMediaAsset(id.uuidString)
                                try validateContext()
                                if let value = LocalMediaAssociation.verified(remote: fresh, requestedID: id, ownerID: scope.userID, local: item.proof.source.identity,
                                                                              source: .checksum, expectedChecksum: item.proof.digest.sha1Base64)
                                {
                                    accept(value); confirmedRemoteIDs.insert(value.remoteID)
                                } else {
                                    removeAssociation(id); unmatched += 1
                                }
                            } else {
                                unmatched += 1
                            }
                        }
                    }
                    scanned += batch.count - snapshots.count
                    unmatched += batch.count - snapshots.count
                    await Task.yield(); try validateContext()
                }
                let freshAssociations = associations.filter { confirmedRemoteIDs.contains($0.key) }
                if freshAssociations != associations {
                    associations = freshAssociations; revision += 1; publishCounts()
                }
                let document = LocalMediaAssociationDocument(scope: scope, enabled: enabled, access: access, associations: Array(associations.values))
                let saved = try await persistence.save(document, scope: scope, permit: writePermit)
                try validateContext()
                guard saved else { throw CancellationError() }
                restoredNamespace = scope.cacheNamespace
                status = permission == .limited ? "已完成当前授权范围匹配并保存；未授权照片未扫描。" : "已完成匹配并保存；下次启动自动恢复，本机优先显示和播放。"
                if metadataFailures > 0 {
                    status += " 部分元数据不可用，已独立尝试本机校验和。"
                }
            } catch {
                guard generation == run, manager.generation == owner, manager.backupScope == scope else { return }
                self.permission = inventory.authorization
                status = error is CancellationError ? "扫描已停止，未完成项目不算匹配成功。" : "扫描未完成：\(error.localizedDescription)。只保留已确认关联，可重新扫描。"
            }
        }
        task = operation
        return operation
    }

    /// run/manager/scope均绑定本次明确操作；expectedAccess开启后禁止在授权范围改变时继续发布旧清单。
    private func validate(_ manager: LibraryManagementController, owner: UUID, scope: MediaAccountScope, run: UUID,
                          expectedAccess: LocalPhotoLibraryAccess? = nil, requireOnline: Bool = true) throws
    {
        try Task.checkCancellation()
        guard generation == run, manager.generation == owner, self.scope == scope,
              !requireOnline || manager.backupScope == scope else { throw LocalMediaMetadataError.sourceChanged }
        if let expectedAccess, inventory.authorization != expectedAccess {
            throw LocalMediaMetadataError.permission
        }
    }

    /// snapshots只能来自该有限batch；重复/越界返回不能被字典覆盖或混入其他本机对象。
    private func validateSnapshots(_ snapshots: [LocalPhotoSnapshot], requested: [String]) throws {
        let ids = snapshots.map(\.identity.localIdentifier)
        guard Set(ids).count == ids.count, Set(ids).isSubset(of: Set(requested)) else { throw LocalMediaMetadataError.invalidBatch }
    }

    /// 同CloudID的坏metadata阻止其元数据路径；重复候选保留供领域层拒绝，每128条yield后由validateContext核验代际。
    private func metadataCandidates(_ records: [LocalMediaRemoteMetadataRecord], validateContext: @MainActor () throws -> Void) async throws -> (candidates: [String: [LocalMediaRemoteCandidate]], rejected: Int) {
        var candidates: [String: [LocalMediaRemoteCandidate]] = [:]
        var blocked = Set<String>()
        var rejected = 0
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 128) {
                await Task.yield(); try validateContext()
            }
            do {
                let metadata = try JSONDecoder().decode(LocalMediaMobileMetadata.self, from: record.value)
                candidates[metadata.cloudId, default: []].append(.init(assetID: record.assetID, metadata: metadata))
            } catch {
                guard let object = try JSONSerialization.jsonObject(with: record.value) as? [String: Any], let id = object["iCloudId"] as? String else { throw LocalMediaMetadataError.invalidMetadata }
                blocked.insert(id); rejected += 1
            }
        }
        for id in blocked {
            candidates[id] = []
        }
        try validateContext()
        return (candidates, rejected)
    }

    /// 同远端对象保留最新确认版本；按变化增减来源计数，避免每确认一项都全库重算。
    private func accept(_ association: LocalMediaAssociation) {
        let previous = associations[association.remoteID]
        guard previous != association else { return }
        if let previous {
            if previous.source == .mobileMetadata {
                metadataMatches -= 1
            } else {
                checksumMatches -= 1
            }
        }
        associations[association.remoteID] = association
        if association.source == .mobileMetadata {
            metadataMatches += 1
        } else {
            checksumMatches += 1
        }
        revision += 1
    }

    /// 派生来源计数与已确认远端对象一致；本机重复副本不伪造新增照片数。
    private func publishCounts() {
        metadataMatches = associations.values.filter { $0.source == .mobileMetadata }.count
        checksumMatches = associations.values.filter { $0.source == .checksum }.count
    }

    /// 新鲜详情明确不可用时撤销旧同ID关联，不能在已知trash/offline/编辑变化后继续沿用恢复记录。
    private func removeAssociation(_ id: UUID) {
        guard let removed = associations.removeValue(forKey: id) else { return }
        if removed.source == .mobileMetadata {
            metadataMatches -= 1
        } else {
            checksumMatches -= 1
        }
        revision += 1
    }

    /// 每次取消/路由变化撤销原子写许可；同namespace已确认关联独立保留，新的任务拿新的代际。
    private func invalidateRun() {
        permit.invalidate(); permit = LocalMediaSavePermit()
        task?.cancel(); task = nil; changeTask?.cancel(); changeTask = nil
        generation = UUID(); running = false
    }

    /// 只有已启用的生产PhotoKit上下文才注册观察；测试显式关闭，账号清除或停用释放观察对象。
    private func startMonitoringIfNeeded() {
        guard enabled, observeChanges, monitor == nil, inventory.authorization == .full || inventory.authorization == .limited else { return }
        monitor = LocalPhotoChangeMonitor { [weak self] in self?.sourcesChanged() }
    }

    /// Photos变化立即撤销全部旧源关联，再合并短时间通知；未授权/离线只保存失效，不偷偷请求系统权限。
    private func sourcesChanged() {
        guard enabled, let manager, let scope else { return }
        invalidateRun(); associations = [:]; access = nil; revision += 1; publishCounts(); automaticGeneration = nil
        metadataFailures = 0
        permission = inventory.authorization
        status = "本机照片库或权限已变化，旧关联已失效；等待重新匹配。"
        let run = generation; let owner = manager.generation; let writePermit = permit
        changeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                let document = LocalMediaAssociationDocument(scope: scope, enabled: true, access: nil, associations: [])
                _ = try await persistence.save(document, scope: scope, permit: writePermit)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                changeTask = nil
                guard manager.client != nil, inventory.authorization == .full || inventory.authorization == .limited else { return }
                automaticGeneration = owner
                if let task = startScan(using: manager, requestPermission: false) {
                    await task.value
                }
            } catch {
                guard generation == run else { return }
                changeTask = nil; status = "照片库已变化，旧关联失效；等待下次可用刷新。"
            }
        }
    }
}
