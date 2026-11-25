import Foundation
import Observation
import Photos

/// 明确的单向增量组织流程；拥有同账号SQLite账本，所有副作用复用既有管理client和唯一备份Coordinator。
@MainActor @Observable final class PhotoBackupAlbumSyncController {
    private(set) var loading = false
    private(set) var running = false
    private(set) var prepared = false
    private(set) var targets: [ManagedAlbum] = []
    private(set) var titles: [String: String] = [:]
    private(set) var state = PhotoBackupAlbumSyncState(namespace: "unloaded")
    private(set) var unmatched = 0
    private(set) var processed = 0
    private(set) var confirmed = 0
    /// 数量按逻辑源乘映射计算；RAW/JPEG两主体均确认才算一组完成。
    var previewCount: Int {
        previewIDs.count
    }

    private(set) var status = "先读取目标并明确选择已有自有相簿，再预览和确认补入。只修改相簿关系。"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadedScope: MediaAccountScope?
    @ObservationIgnored private var previewIDs: Set<UUID> = []
    @ObservationIgnored private var previewSelection: Selection?
    @ObservationIgnored private var monitor: LocalPhotoChangeMonitor?
    @ObservationIgnored private let store: SQLiteLibraryIndexStore
    @ObservationIgnored private let matching: any PhotoBackupAlbumMatchingReading
    @ObservationIgnored private let scanner: @MainActor (Set<String>) throws -> [PhotoBackupAlbumSnapshot]
    @ObservationIgnored private let names: @MainActor (Set<String>) throws -> [String: String]
    @ObservationIgnored private let verifySource: @MainActor (PhotoBackupSource) throws -> Void
    @ObservationIgnored private let authorization: @MainActor () -> PHAuthorizationStatus
    @ObservationIgnored private let observeChanges: Bool

    /// 同步选择来自保存的日志，不引用UI草稿；cloud只用于防止确认期间意愿变化，不触发任何原片读取。
    private struct Selection: Equatable {
        let included: Set<String>
        let excluded: Set<String>
        let cloud: Bool
        /// journal必须已从当前账号冷读；只复制已保存意愿，不采纳页面草稿。
        init(_ journal: PhotoBackupJournal) {
            included = Set(journal.selectedAlbumIDs); excluded = Set(journal.excludedAlbumIDs ?? []); cloud = journal.allowCloud
        }
    }

    /// 计划阶段以完整源/角色证明定位历史组，避免每个成员反复扫描全部历史。
    private struct OperationKey: Hashable {
        let localAlbumID: String
        let targetID: UUID
        let source: PhotoBackupSource
        let assets: [PhotoBackupAlbumSyncAsset]
        /// operation的完整身份作为历史索引键，不以本地ID或目标名称合并不同版本。
        init(_ operation: PhotoBackupAlbumSyncOperation) {
            localAlbumID = operation.localAlbumID; targetID = operation.targetID; source = operation.source; assets = operation.assets
        }
    }

    /// matching返回当前fresh匹配证据；其余可选端口只隔离Photos元数据，默认均为真实公开系统读取。
    /// store仍是真实SQLite，observeChanges=false只用于隔离测试，绝不替换HTTP/计划/回执确认逻辑。
    init(matching: any PhotoBackupAlbumMatchingReading, store: SQLiteLibraryIndexStore = .init(),
         scanner: (@MainActor (Set<String>) throws -> [PhotoBackupAlbumSnapshot])? = nil,
         names: (@MainActor (Set<String>) throws -> [String: String])? = nil,
         verifySource: (@MainActor (PhotoBackupSource) throws -> Void)? = nil,
         authorization: @escaping @MainActor () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) }, observeChanges: Bool = true)
    {
        self.matching = matching; self.store = store; self.scanner = scanner ?? PhotoBackupController.albumSnapshots
        self.names = names ?? Self.albumNames; self.verifySource = verifySource ?? Self.verifyCurrentSource
        self.authorization = authorization; self.observeChanges = observeChanges
    }

    /// 冷读映射/操作及当前自有目标；sending只显示为unknown，不自动执行或据旧UUID建立新映射。
    func load(using manager: LibraryManagementController, backup: PhotoBackupController) async {
        guard !loading, !running, !backup.running, !manager.busy, let scope = manager.backupScope else { return }
        let owner = manager.generation, run = generation, access = authorization()
        loading = true
        defer { loading = false }
        do {
            try validate(manager, backup: backup, scope: scope, owner: owner, run: run, access: access)
            let client = try currentClient(manager)
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope)
            try validate(manager, backup: backup, scope: scope, owner: owner, run: run, access: access)
            let journal = try await store.loadPhotoBackups(scope: scope)
            try validate(manager, backup: backup, scope: scope, owner: owner, run: run, access: access)
            let values = try await client.albumSyncTargets()
            try validate(manager, backup: backup, scope: scope, owner: owner, run: run, access: access)
            for index in saved.operations.indices where saved.operations[index].phase == .sending {
                saved.operations[index].phase = .unknown; saved.operations[index].failure = .unconfirmed
            }
            for index in saved.creations.indices where saved.creations[index].phase == .sending {
                saved.creations[index].phase = .unknown
            }
            let localNames = try names(Set(journal.selectedAlbumIDs).union(journal.excludedAlbumIDs ?? []))
            state = saved; targets = values; titles = localNames; loadedScope = scope; prepared = false; previewIDs = []
            status = "已读取当前账户目标。名称相同也须明确选择；缺失或无权限目标不会自动创建或替换。"
        } catch {
            if generation == run, manager.generation == owner {
                prepared = false; status = "未能确认相簿组织配置；保留已有映射与恢复资料，请检查授权/连接后重读。"
            }
        }
    }

    /// 明确映射或解除映射；仅保存UUID，不创建/改名/删除相簿或移除任何远端成员。
    @discardableResult func setMapping(localID: String, targetID: UUID?, using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] client, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            guard journal.selectedAlbumIDs.contains(localID) else { throw LocalMediaMetadataError.sourceChanged }
            let target: ManagedAlbum?
            if let targetID {
                target = try await client.albumSyncTarget(targetID); try check()
            } else {
                target = nil
            }
            saved.mappings.removeAll { $0.localAlbumID == localID }
            if let targetID, let target {
                saved.mappings.append(.init(localAlbumID: localID, targetID: targetID, targetName: target.albumName))
                for index in saved.creations.indices where saved.creations[index].localAlbumID == localID && saved.creations[index].unresolved {
                    saved.creations[index].phase = .mapped; saved.creations[index].mappedTargetID = targetID
                }
            }
            for index in saved.operations.indices where saved.operations[index].localAlbumID == localID && saved.operations[index].phase != .confirmed {
                saved.operations[index].phase = .cancelled
            }
            try await store.savePhotoBackupAlbumSyncPlan(saved, scope: scope); try check()
            state = saved; prepared = false; previewIDs = []; status = "映射已保存。预览后才会补入；解除映射保留远端相簿与现有成员。"
        }
    }

    /// 只建立元数据组织计划并保存待确认组；未匹配/部分备份不自动上传或读取原片来补证。
    @discardableResult func prepare(using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] client, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            let selection = Selection(journal)
            let sources = try sourcesByAlbum(selection); try check()
            let ids = Set(sources.values.flatMap(\.self).filter { $0.kind != .rawJPEG }.map(\.localID))
            let associations = try await matching.albumOrganizationAssociations(localIDs: ids, using: manager); try check()
            let matches = Dictionary(grouping: associations, by: \.localIdentity.localIdentifier)
            var planned = Set<UUID>(); var missing = 0
            var indexed: [OperationKey: Int] = [:]
            for (index, operation) in saved.operations.enumerated() {
                guard indexed.updateValue(index, forKey: OperationKey(operation)) == nil else { throw PhotoBackupStateError.invalidJournal }
            }
            for mapping in saved.mappings where selection.included.contains(mapping.localAlbumID) {
                _ = try await client.albumSyncTarget(mapping.targetID); try check()
                for source in sources[mapping.localAlbumID] ?? [] {
                    guard let assets = candidateAssets(source, journal: journal, matches: matches[source.localID] ?? []) else { missing += 1; continue }
                    let candidate = PhotoBackupAlbumSyncOperation(localAlbumID: mapping.localAlbumID, targetID: mapping.targetID, source: source, assets: assets)
                    let key = OperationKey(candidate)
                    var operation = indexed[key].map { saved.operations[$0] } ?? candidate
                    operation.phase = .queued; operation.failure = nil
                    try operation.validate()
                    if let index = indexed[key] {
                        saved.operations[index] = operation
                    } else {
                        indexed[key] = saved.operations.count
                        saved.operations.append(operation)
                    }
                    planned.insert(operation.id)
                }
            }
            try await store.savePhotoBackupAlbumSyncPlan(saved, scope: scope); try check()
            state = saved; previewIDs = planned; previewSelection = selection; unmatched = missing; prepared = true
            status = "预览 \(planned.count) 个逻辑项目；\(missing) 项待匹配或待完整回执。确认后只补入缺失关系，不上传/下载原片。"
        }
    }

    /// 用户确认后重新核源/当前metadata证据，再逐组fresh检查成员；未知发送绝不直接重放。
    @discardableResult func synchronize(using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        guard prepared, !previewIDs.isEmpty, let selection = previewSelection else { return nil }
        let planned = previewIDs, mappings = state.mappings
        return start(using: manager, backup: backup) { [self] client, scope, check in
            let saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            guard Selection(journal) == selection, saved.mappings == mappings else { throw LocalMediaMetadataError.sourceChanged }
            let sources = try sourcesByAlbum(selection); try check()
            let selected = saved.operations.filter { planned.contains($0.id) }
            let matches = try await matching.albumOrganizationAssociations(localIDs: Set(selected.filter { $0.source.kind != .rawJPEG }.map(\.source.localID)), using: manager); try check()
            let byLocal = Dictionary(grouping: matches, by: \.localIdentity.localIdentifier)
            let stamp = matching.revision
            let matchEpoch = matching.albumOrganizationGeneration
            let freshCheck: @MainActor () throws -> Void = {
                try check()
                guard self.matching.revision == stamp, self.matching.albumOrganizationGeneration == matchEpoch else { throw LocalMediaMetadataError.sourceChanged }
            }
            processed = 0; confirmed = 0
            for var operation in selected {
                try freshCheck()
                guard sources[operation.localAlbumID]?.contains(operation.source) == true,
                      candidateAssets(operation.source, journal: journal, matches: byLocal[operation.source.localID] ?? []) == operation.assets
                else {
                    operation.phase = .failed; operation.failure = .sourceChanged
                    try await checkpoint(operation, scope: scope, check: freshCheck)
                    processed += 1
                    continue
                }
                try verifySource(operation.source)
                let stop = try await synchronizeOperation(&operation, client: client, scope: scope, check: freshCheck)
                processed += 1
                if operation.phase == .confirmed {
                    confirmed += 1
                }
                status = "已核对 \(processed)/\(selected.count) 组，完整确认 \(confirmed) 组。"
                if stop {
                    break
                }
            }
            try freshCheck(); prepared = false
            let final = try await store.loadPhotoBackupAlbumSync(scope: scope); try freshCheck()
            state = final
            manager.publishChanges(ifGeneration: manager.generation)
            status = "本轮组织已停止或完成；以逐组确认状态为准。未知/部分结果会在下次明确预览后先fresh核查，不自动重发。"
        }
    }

    /// 页面关闭/后台/换号撤销当前操作；sending已在HTTP前落盘，迟到结果不能覆盖新上下文。
    func cancel() {
        generation = UUID(); task?.cancel(); prepared = false; monitor?.stop(); monitor = nil
        status = "相簿组织已停止；映射及部分回执保留，未知项须重新预览核查。"
    }

    /// 所有明确写流程共用manager忙门和原Coordinator；先取得管理忙门，避免自动备份抢占新组织操作。
    private func start(using manager: LibraryManagementController, backup: PhotoBackupController,
                       operation: @escaping @MainActor (LibraryMutationClient, MediaAccountScope, @escaping @MainActor () throws -> Void) async throws -> Void) -> Task<Void, Never>?
    {
        guard !running, !loading, !backup.running, !manager.busy, let scope = manager.backupScope, loadedScope == scope,
              backup.hasCurrentSavedSelection(using: manager) else { return nil }
        let run = generation, owner = manager.generation, access = authorization()
        guard access == .authorized || access == .limited else { status = "需要已有照片访问权限，未启动组织。"; return nil }
        running = true
        if observeChanges, monitor == nil {
            monitor = LocalPhotoChangeMonitor { [weak self] in self?.cancel() }
        }
        let current = Task { [self] in
            defer {
                running = false; task = nil; if !prepared {
                    monitor?.stop(); monitor = nil
                }
            }
            do {
                let check: @MainActor () throws -> Void = { try self.validate(manager, backup: backup, scope: scope, owner: owner, run: run, access: access) }
                try check()
                try await manager.perform(publishChange: false) { client in
                    try await PhotoBackupRunCoordinator.perform(scope: scope) { try check(); try await operation(client, scope, check) }
                }
            } catch {
                if generation == run, manager.generation == owner {
                    prepared = false; status = "组织未确认完成；保留已上传状态与关系回执。检查权限/连接或重新预览后继续。"
                }
            }
        }
        task = current; return current
    }

    /// check同时约束页面epoch、账号/端点、Photos权限和未保存草稿；每次await前后都使用同一捕获上下文。
    private func validate(_ manager: LibraryManagementController, backup: PhotoBackupController, scope: MediaAccountScope,
                          owner: UUID, run: UUID, access: PHAuthorizationStatus) throws
    {
        try Task.checkCancellation()
        guard generation == run, manager.generation == owner, manager.backupScope == scope, backup.hasCurrentSavedSelection(using: manager),
              access == .authorized || access == .limited, authorization() == access else { throw LocalMediaMetadataError.sourceChanged }
    }

    /// manager必须仍有当前client，读流程也不使用旧缓存会话。
    private func currentClient(_ manager: LibraryManagementController) throws -> LibraryMutationClient {
        guard let client = manager.client else { throw LibraryWriteError.unavailable }; return client
    }

    /// 同一完整包含/排除快照先走现有政策，再保留每个包含相簿成员；一图可进入多个明确映射目标。
    private func sourcesByAlbum(_ saved: Selection) throws -> [String: [PhotoBackupSource]] {
        let selection = try PhotoBackupAlbumSelection(included: saved.included, excluded: saved.excluded)
        let snapshots = try scanner(saved.included.union(saved.excluded)), eligible = try Set(selection.scan(snapshots).sources)
        return Dictionary(uniqueKeysWithValues: snapshots.filter { saved.included.contains($0.id) }.map { ($0.id, $0.assets.map(\.source).filter { eligible.contains($0) }) })
    }

    /// RAW只接受完整双原图上传回执；其他媒体接受精确当前版本关联，metadata provenance不要求本机原片hash。
    private func candidateAssets(_ source: PhotoBackupSource, journal: PhotoBackupJournal, matches: [LocalMediaAssociation]) -> [PhotoBackupAlbumSyncAsset]? {
        guard let modified = source.modifiedAt, modified.timeIntervalSince1970.isFinite else { return nil }
        if source.kind == .rawJPEG {
            guard let job = journal.jobs.first(where: { $0.source == source && $0.stage == .completed }), let raw = job.rawReceipt, let jpeg = job.jpegReceipt else { return nil }
            return [.init(role: .raw, assetID: raw.assetID, checksum: raw.checksum, revision: nil, proof: .originalReceipt),
                    .init(role: .jpeg, assetID: jpeg.assetID, checksum: jpeg.checksum, revision: nil, proof: .originalReceipt)]
        }
        let kind: LocalPhotoIdentity.MediaKind = source.kind == .video ? .video : source.kind == .livePhoto ? .livePhoto : .image
        let current = matches.filter { $0.localIdentity == .init(localIdentifier: source.localID, modificationDate: source.modifiedAt, mediaKind: kind) }
        guard current.count == 1, let match = current.first else { return nil }
        return [.init(role: .primary, assetID: match.remoteID, checksum: match.checksum, revision: match.remoteRevision,
                      proof: match.source == .mobileMetadata ? .metadataAssociation : .checksumAssociation)]
    }

    /// 只核公开Photos身份/完整资源描述，不请求媒体字节或下载iCloud。
    private static func verifyCurrentSource(_ source: PhotoBackupSource) throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.localID], options: nil).firstObject,
              PhotoKitBackupResourceExporter.source(for: asset) == source else { throw LocalMediaMetadataError.sourceChanged }
    }

    /// 名称仅展示；包含/排除集合缺失仍报错，不能拿空排除继续。
    private static func albumNames(_ ids: Set<String>) throws -> [String: String] {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids), options: nil)
        var values: [String: String] = [:]
        collections.enumerateObjects { value, _, _ in values[value.localIdentifier] = value.localizedTitle ?? "未命名相簿" }
        guard Set(values.keys) == ids else { throw PhotoBackupAlbumSelectionError.unavailableAlbum }
        return values
    }
}

extension PhotoBackupAlbumSyncController {
    /// localID/name来自明确输入；先fresh检查保存规则和目标列表，只保存待确认意图，不发POST或同名认领。
    @discardableResult func prepareCreation(localID: String, name: String, using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] client, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            guard journal.selectedAlbumIDs.contains(localID), !saved.creations.contains(where: { $0.localAlbumID == localID && $0.unresolved }) else { throw LibraryWriteError.busy }
            _ = try sourcesByAlbum(Selection(journal)); try check()
            let intent = PhotoBackupAlbumCreation(localAlbumID: localID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            try intent.validate()
            let values = try await client.albumSyncTargets(); try check()
            saved.version = 2; saved.creations.append(intent)
            try await saveCreationState(saved, scope: scope, check: check)
            targets = values
            status = "创建预览已保存：‘\(intent.name)’。当前有 \(values.count { $0.albumName == intent.name }) 本同名相簿；确认会另建空相簿，不会按名称认领。原目标及成员保留。"
        }
    }

    /// id只能是尚未发送的已保存意图；sending在POST前落盘，取消/坏回执/未知网络结果都禁止重发。
    @discardableResult func createAndMap(_ id: UUID, using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] client, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            guard let index = saved.creations.firstIndex(where: { $0.id == id }), saved.creations[index].phase == .prepared,
                  journal.selectedAlbumIDs.contains(saved.creations[index].localAlbumID) else { throw LibraryWriteError.unavailable }
            _ = try sourcesByAlbum(Selection(journal)); try check()
            saved.creations[index].phase = .sending
            try await saveCreationState(saved, scope: scope, check: check)
            let receipt: ManagedAlbum
            do { receipt = try await client.albumSyncCreate(name: saved.creations[index].name) }
            catch {
                try check()
                if case let LibraryWriteError.http(status) = error, [400, 401, 403].contains(status) {
                    saved.creations[index].phase = .rejected
                } else {
                    saved.creations[index].phase = .unknown
                }
                try await saveCreationState(saved, scope: scope, check: check)
                status = saved.creations[index].phase == .rejected ? "创建请求被拒绝。原映射保留；修正权限/输入后可重新预览明确创建。" : "创建结果未知，未重发。请只读重核并明确选择现有目标；同名或新增列表项不能证明是本次创建。"
                return
            }
            try check()
            guard let targetID = UUID(uuidString: receipt.id) else { throw LibraryWriteError.malformedResponse }
            saved.creations[index].receiptID = targetID; saved.creations[index].phase = .received
            try await saveCreationState(saved, scope: scope, check: check)
            try await confirmCreatedMapping(&saved, index: index, client: client, scope: scope, check: check)
        }
    }

    /// 恢复只GET；有持久201 UUID才核同一对象并自动完成映射，无UUID只刷新目标供明确选择，绝不POST。
    @discardableResult func recoverCreation(_ id: UUID, using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] client, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            let journal = try await store.loadPhotoBackups(scope: scope); try check()
            guard let index = saved.creations.firstIndex(where: { $0.id == id }), saved.creations[index].unresolved, saved.creations[index].phase != .prepared,
                  journal.selectedAlbumIDs.contains(saved.creations[index].localAlbumID) else { throw LibraryWriteError.unavailable }
            _ = try sourcesByAlbum(Selection(journal)); try check()
            if saved.creations[index].receiptID != nil {
                try await confirmCreatedMapping(&saved, index: index, client: client, scope: scope, check: check)
            } else {
                let values = try await client.albumSyncTargets(); try check()
                saved.creations[index].phase = .unknown
                try await saveCreationState(saved, scope: scope, check: check)
                targets = values
                status = "已刷新现有目标；无法唯一核实本次创建。请在相簿选择器明确选目标，未按名称认领，也未再次POST。"
            }
        }
    }

    /// 仅未发送预览可撤销，保留终态历史；未知/已发送意图须只读核查或明确映射，不能以撤销绕过防重放。
    @discardableResult func abandonPreparedCreation(_ id: UUID, using manager: LibraryManagementController, backup: PhotoBackupController) -> Task<Void, Never>? {
        start(using: manager, backup: backup) { [self] _, scope, check in
            var saved = try await store.loadPhotoBackupAlbumSync(scope: scope); try check()
            guard let index = saved.creations.firstIndex(where: { $0.id == id }), saved.creations[index].phase == .prepared else { throw LibraryWriteError.unavailable }
            saved.creations[index].phase = .abandoned
            try await saveCreationState(saved, scope: scope, check: check)
            status = "未发送的创建预览已取消；没有创建或删除远端相簿。"
        }
    }

    /// index必须持有本次201的精确UUID；fresh相同owner/name才原子保存映射，不能用列表同名填补丢失回执。
    private func confirmCreatedMapping(_ saved: inout PhotoBackupAlbumSyncState, index: Int, client: LibraryMutationClient,
                                       scope: MediaAccountScope, check: @MainActor () throws -> Void) async throws
    {
        guard let id = saved.creations[index].receiptID else { throw LibraryWriteError.unavailable }
        let fresh = try await client.albumSyncTarget(id); try check()
        guard fresh.albumName == saved.creations[index].name else { throw LibraryWriteError.malformedResponse }
        let localID = saved.creations[index].localAlbumID
        saved.mappings.removeAll { $0.localAlbumID == localID }
        saved.mappings.append(.init(localAlbumID: localID, targetID: id, targetName: fresh.albumName))
        saved.creations[index].phase = .mapped; saved.creations[index].mappedTargetID = id
        for offset in saved.operations.indices where saved.operations[offset].localAlbumID == localID && saved.operations[offset].phase != .confirmed {
            saved.operations[offset].phase = .cancelled
        }
        try await saveCreationState(saved, scope: scope, check: check)
        if !targets.contains(where: { UUID(uuidString: $0.id) == id }) {
            targets.append(fresh)
        }
        status = "新空相簿已fresh核实并保存映射；原相簿与成员保留。照片仍须另行预览并确认增量补入。"
    }

    /// 保存同一账本的创建状态；写前后核上下文，失败上抛，不发POST或覆盖上传任务。
    private func saveCreationState(_ saved: PhotoBackupAlbumSyncState, scope: MediaAccountScope, check: @MainActor () throws -> Void) async throws {
        try check(); try await store.savePhotoBackupAlbumSyncPlan(saved, scope: scope); try check()
        state = saved; prepared = false; previewIDs = []
    }
}

/// 组织账本保存失败必须退出，不得再以网络/权限错误覆盖未确认恢复资料。
private nonisolated struct PhotoBackupAlbumSyncStorageError: Error { let underlying: any Error }

extension PhotoBackupAlbumSyncController {
    /// operation可包含两份RAW/JPEG；每份都先核当前身份/成员，发送前保存sending，独立fresh存在才确认。
    /// 返回true表示未知/连接问题，停止后续组；下一次明确恢复仍先查成员，绝不盲目重发。
    private func synchronizeOperation(_ operation: inout PhotoBackupAlbumSyncOperation, client: LibraryMutationClient,
                                      scope: MediaAccountScope, check: @MainActor () throws -> Void) async throws -> Bool
    {
        // 旧逐项回执保留作恢复资料；本轮只有重新fresh核过全部主体才可再次记整组confirmed。
        var freshConfirmed = Set<UUID>()
        do {
            for asset in operation.assets {
                try check(); try verifySource(operation.source)
                _ = try await client.albumSyncTarget(operation.targetID); try check()
                let before = try await client.albumSyncAsset(asset.assetID); try check()
                try verifyRemote(before, proof: asset, source: operation.source, owner: scope.userID)
                let present = try await client.albumSyncContains(asset.assetID, target: operation.targetID); try check()
                if !present {
                    operation.confirmedAssetIDs.remove(asset.assetID); operation.phase = .sending; operation.failure = nil
                    try await checkpoint(operation, scope: scope, check: check)
                    try verifySource(operation.source)
                    let receipt: PhotoBackupAlbumMemberReceipt?
                    do { receipt = try await client.albumSyncAdd(asset.assetID, target: operation.targetID) }
                    catch { try check(); receipt = nil }
                    try check()
                    if case .denied = receipt {
                        operation.phase = .failed; operation.failure = .permission
                        try await checkpoint(operation, scope: scope, check: check)
                        return false
                    }
                    // success、duplicate或响应未知都fresh核实际期望状态；不会因HTTP200/旧回执直接记完成。
                    try verifySource(operation.source)
                    _ = try await client.albumSyncTarget(operation.targetID); try check()
                    let after = try await client.albumSyncAsset(asset.assetID); try check()
                    try verifyRemote(after, proof: asset, source: operation.source, owner: scope.userID)
                    let confirmed = try await client.albumSyncContains(asset.assetID, target: operation.targetID); try check()
                    guard confirmed else {
                        operation.phase = .unknown; operation.failure = .unconfirmed
                        try await checkpoint(operation, scope: scope, check: check)
                        return true
                    }
                }
                try verifySource(operation.source)
                freshConfirmed.insert(asset.assetID)
                operation.confirmedAssetIDs.insert(asset.assetID)
                operation.phase = freshConfirmed.count == operation.assets.count ? .confirmed : .queued
                operation.failure = nil
                try await checkpoint(operation, scope: scope, check: check)
            }
            return false
        } catch {
            try check()
            if error is PhotoBackupAlbumSyncStorageError {
                throw error
            }
            operation.phase = operation.phase == .sending ? .unknown : .failed
            operation.failure = operation.phase == .unknown ? .unconfirmed : .unavailable
            try await checkpoint(operation, scope: scope, check: check)
            return true
        }
    }

    /// expected revision属于当前匹配证据；RAW回执只要求原图SHA1，组织不会把编辑表示或旧UUID当作原片一致证明。
    private func verifyRemote(_ value: LocalMediaRemoteAsset, proof: PhotoBackupAlbumSyncAsset, source: PhotoBackupSource, owner: String) throws {
        guard value.id == proof.assetID, value.ownerId == UUID(uuidString: owner), value.isTrashed == false, value.isOffline == false,
              value.type == (source.kind == .video ? "VIDEO" : "IMAGE"), value.checksum == proof.checksum,
              proof.revision == nil || value.updatedAt == proof.revision else { throw LocalMediaMetadataError.sourceChanged }
    }

    /// 逐组热写之前/之后都核上下文；磁盘失败不能被后续错误处理抹成另一种成功/失败事实。
    private func checkpoint(_ operation: PhotoBackupAlbumSyncOperation, scope: MediaAccountScope, check: @MainActor () throws -> Void) async throws {
        try check()
        do { try await store.savePhotoBackupAlbumSyncOperation(operation, scope: scope) }
        catch { throw PhotoBackupAlbumSyncStorageError(underlying: error) }
        try check()
    }
}
