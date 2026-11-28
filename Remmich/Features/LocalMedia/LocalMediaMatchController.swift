import Foundation
import Observation

/// 现有鉴权client的窄只读边界；上传/备份/媒体HTTP不属于本机显示关联。
nonisolated protocol LocalMediaMatchingReading: Sendable {
    /// cloudIDs完整不截断；只接收完整只读metadata流，不能ACK/reset或发布半截候选。
    func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord]
    /// id是候选远端UUID；返回绕过缓存的新鲜账号状态，缺字段仍由领域层拒绝；明确不可读抛LocalMediaCandidateError。
    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset
    /// queries最多64项，只查SHA1；noMatch绝不触发上传。
    func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup]
}

extension LibraryMutationClient: LocalMediaMatchingReading {}

/// 明确相簿组织只读取当前已启用关联并重新核证；不调用原片checksum reader，不把结果写为备份完成。
@MainActor protocol PhotoBackupAlbumMatchingReading: Sendable {
    var revision: Int { get }
    var albumOrganizationGeneration: UUID { get }
    func albumOrganizationAssociations(localIDs: Set<String>, using manager: LibraryManagementController) async throws -> [LocalMediaAssociation]
}

extension LocalMediaMatchController: PhotoBackupAlbumMatchingReading {}

/// 显式前台本机关联扫描；账号代际隔离、批量有界，不将进度/哈希查重写成备份成功。
@MainActor @Observable final class LocalMediaMatchController {
    private(set) var followsBackup = false
    @ObservationIgnored var backupAssociationLoader: (@MainActor (MediaAccountScope) async throws -> [LocalMediaAssociation])?
    @ObservationIgnored var backupAssociationSaver: (@MainActor ([LocalMediaAssociation], MediaAccountScope) async throws -> Void)?
    @ObservationIgnored var completedBackupLoader: (@MainActor (MediaAccountScope) async throws -> [PhotoBackupJob])?
    private(set) var recoveringCompletedAssociations = false
    @ObservationIgnored private var completedRecoveryGeneration: UUID?
    @ObservationIgnored private var completedRecoveryActive = true
    @ObservationIgnored private(set) var displayLookupDiagnostics: [String: Int] = [:]
    private func traceDisplayLookup(_ reason: String) {
        #if DEBUG
            displayLookupDiagnostics[reason, default: 0] += 1
        #endif
    }

    @ObservationIgnored private var checksumAssociationIDs: [String: Set<UUID>] = [:]
    @ObservationIgnored private var activeDisplayLookups = 0
    @ObservationIgnored private var pendingDisplayLookups = Set<String>()
    @ObservationIgnored private var sharedDisplayLookups: [String: Task<LocalMediaAssociation?, Error>] = [:]
    @ObservationIgnored private var missedDisplayLookups: [String: ContinuousClock.Instant] = [:]
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
    /// 当前语言只影响展示；保留原任务、源版本和账号代际。
    var status: String {
        L10n.text(statusMessage) + (statusSuffix.map { L10n.text($0) } ?? "")
    }

    private(set) var statusMessage: String.LocalizationValue = "点击扫描，关联本机与Immich已有照片；不会上传或删除照片。" {
        didSet { statusSuffix = nil }
    }

    private var statusSuffix: String.LocalizationValue?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private weak var manager: LibraryManagementController?
    @ObservationIgnored private var managerGeneration: UUID?
    @ObservationIgnored private var scope: MediaAccountScope?
    @ObservationIgnored private var access: LocalPhotoLibraryAccess?
    @ObservationIgnored private var associations: [UUID: LocalMediaAssociation] = [:]
    @ObservationIgnored private var displayAssociations: [UUID: LocalMediaAssociation] = [:]
    @ObservationIgnored private var displayAssociationsAccess: LocalPhotoLibraryAccess?
    @ObservationIgnored private var rejectedDisplayAssociationIDs = Set<UUID>()
    @ObservationIgnored private var displayMutations: [UUID: (id: UUID, task: Task<Bool, Error>)] = [:]
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
    @ObservationIgnored private let displayPersistence: any LocalPhotoDisplayAssociationPersisting
    @ObservationIgnored private let observeChanges: Bool
    @ObservationIgnored private let strictPhotoSourcePolicy: Bool

    /// 未确认身份不能被解释为Immich-only。生产共享同步启用严格来源，测试可单独注入旧合同。
    var requiresConfirmedPhotoSource: Bool {
        strictPhotoSourcePolicy && (fullLibraryReconciler != nil || enabled)
    }

    private(set) var sourcePolicyReady = true
    private(set) var fullLibraryReconciler: LocalPhotoDisplayReconciler?
    @ObservationIgnored private let reconciliationStore: (any LocalPhotoDisplayReconciliationStoring)?
    @ObservationIgnored private var knownDisplayRemoteIDs = Set<UUID>()
    @ObservationIgnored private var displayHotOrder: [UUID] = []
    @ObservationIgnored private var fullLibraryActive = true
    @ObservationIgnored private var fullLibraryUserPaused = false
    @ObservationIgnored private var fullLibraryPublicationValid = true
    @ObservationIgnored private var fullLibraryEnabledOverride: Bool?
    @ObservationIgnored private var fullLibraryCallbackOwner: UUID?
    @ObservationIgnored private var fullLibraryFlowOwner: UUID?
    @ObservationIgnored private var fullLibraryEvidenceRefreshRequested = false
    @ObservationIgnored private var displayIndexEpoch = UUID()
    @ObservationIgnored private var fallbackDecisionEpoch = UUID()
    @ObservationIgnored private var fallbackWritePermit = LocalMediaSavePermit()
    @ObservationIgnored private var immichUnlinkedFacts: [UUID: LocalPhotoDisplaySourceFact] = [:]
    @ObservationIgnored private var immichUnlinkedOrder: [UUID] = []
    @ObservationIgnored private var declaredPhotoIdentityIDs = Set<UUID>()
    private let displayHotLimit = 512

    /// Production shares one account SQLite between bulk matching and visible-item reads.
    /// Default test construction retains the former matching contract and injected fixtures.
    static func production() -> LocalMediaMatchController {
        let store = LocalPhotoDisplayReconciliationStore()
        return LocalMediaMatchController(inventory: PhotoKitDisplayReconciliationInventory(),
                                         displayPersistence: LocalPhotoDisplayAssociationStore(reconciliationStore: store),
                                         strictPhotoSourcePolicy: true, reconciliationStore: store,
                                         reconciliationDiagnosticsURL: URL.documentsDirectory.appendingPathComponent("remmich-photo-reconciliation-diagnostics.json"))
    }

    func hasLocalPhotoIdentity(assetID: UUID, revision _: Date) -> Bool {
        guard enabled, sourcePolicyReady, scope != nil, let manager, managerGeneration == manager.generation,
              !rejectedDisplayAssociationIDs.contains(assetID) else { return false }
        if access == inventory.authorization, associations[assetID] != nil {
            return true
        }
        return displayAssociationsAccess == inventory.authorization && (knownDisplayRemoteIDs.contains(assetID) || displayAssociations[assetID] != nil)
    }

    func hasLocalPhotoIdentity(assetID: String, revision: Date) -> Bool {
        guard let id = UUID(uuidString: assetID) else { return false }
        return hasLocalPhotoIdentity(assetID: id, revision: revision)
    }

    /// A positive Photos identity always wins. This fact only means a complete fresh metadata
    /// response declared no portable Photos identity; it never asserts that iCloud lacks a photo.
    func permitsImmichFallback(assetID: String, revision: Date) -> Bool {
        guard let id = UUID(uuidString: assetID), sourcePolicyReady, enabled,
              let manager, managerGeneration == manager.generation, scope != nil,
              !hasPositivePhotoIdentity(id), !declaredPhotoIdentityIDs.contains(id),
              !rejectedDisplayAssociationIDs.contains(id),
              let fact = immichUnlinkedFacts[id], fact.displayRevision == revision,
              fact.access == inventory.authorization,
              fact.access == .full || fact.access == .limited else { return false }
        return true
    }

    private func hasPositivePhotoIdentity(_ id: UUID) -> Bool {
        if access == inventory.authorization, associations[id] != nil {
            return true
        }
        return displayAssociationsAccess == inventory.authorization
            && (knownDisplayRemoteIDs.contains(id) || displayAssociations[id] != nil)
    }

    private func forgetImmichUnlinked(_ id: UUID) {
        immichUnlinkedFacts.removeValue(forKey: id)
        immichUnlinkedOrder.removeAll { $0 == id }
    }

    private func cacheImmichUnlinked(_ fact: LocalPhotoDisplaySourceFact) {
        guard !hasPositivePhotoIdentity(fact.assetID), !declaredPhotoIdentityIDs.contains(fact.assetID) else { return }
        immichUnlinkedFacts[fact.assetID] = fact
        immichUnlinkedOrder.removeAll { $0 == fact.assetID }
        immichUnlinkedOrder.append(fact.assetID)
        while immichUnlinkedOrder.count > displayHotLimit {
            immichUnlinkedFacts.removeValue(forKey: immichUnlinkedOrder.removeFirst())
        }
    }

    private func invalidateImmichUnlinkedDecisions() {
        fallbackDecisionEpoch = UUID()
        fallbackWritePermit.invalidate(); fallbackWritePermit = LocalMediaSavePermit()
        immichUnlinkedFacts.removeAll(); immichUnlinkedOrder.removeAll()
    }

    /// 注入仅替换系统/网络来源；nil remote使用当前manager真实client，全部验证、统计与发布门禁仍执行。
    init(inventory: any LocalPhotoInventoryReading = PhotoKitLocalPhotoInventory(),
         metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader(),
         checksum: any LocalPhotoChecksumReading = PhotoKitCurrentResourceChecksumReader(),
         remote: (any LocalMediaMatchingReading)? = nil,
         persistence: any LocalMediaAssociationPersisting = LocalMediaAssociationStore(),
         displayPersistence: any LocalPhotoDisplayAssociationPersisting = LocalPhotoDisplayAssociationStore(), observeChanges: Bool = true,
         strictPhotoSourcePolicy: Bool = false,
         reconciliationStore: (any LocalPhotoDisplayReconciliationStoring)? = nil,
         reconciliationDiagnosticsURL: URL? = nil)
    {
        self.inventory = inventory; self.metadata = metadata; self.checksum = checksum; remoteOverride = remote
        self.persistence = persistence; self.displayPersistence = displayPersistence; self.observeChanges = observeChanges
        self.strictPhotoSourcePolicy = strictPhotoSourcePolicy
        self.reconciliationStore = reconciliationStore
        if let reconciliationStore {
            sourcePolicyReady = false
            fullLibraryReconciler = LocalPhotoDisplayReconciler(inventory: inventory, metadata: metadata, store: reconciliationStore,
                                                                diagnosticsURL: reconciliationDiagnosticsURL)
        }
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
        if fullLibraryReconciler != nil {
            sourcePolicyReady = false
        }
        let changedScope = scope != nextScope
        self.manager = manager; managerGeneration = manager.generation; scope = nextScope
        if changedScope {
            fullLibraryEvidenceRefreshRequested = false
            followsBackup = false
            knownDisplayRemoteIDs = []; displayHotOrder = []; declaredPhotoIdentityIDs = []
            fullLibraryUserPaused = fullLibraryReconciler != nil && nextScope.map {
                UserDefaults.standard.bool(forKey: "LocalPhotoDisplayReconciliation.userPaused.\($0.cacheNamespace)")
            } == true
            fullLibraryEnabledOverride = nil
            associations = [:]; displayAssociations = [:]; displayAssociationsAccess = nil; rejectedDisplayAssociationIDs = []; checksumAssociationIDs = [:]; revision += 1; enabled = false; access = nil; restoredNamespace = nil
            total = 0; scanned = 0; metadataMatches = 0; checksumMatches = 0; unmatched = 0; metadataFailures = 0
            automaticGeneration = nil; monitor?.stop(); monitor = nil
        }
        permission = inventory.authorization
        statusMessage = nextScope == nil ? "请先连接Immich服务器。" : "启用后自动关联本机已有照片，优先本机显示和播放。"
    }

    /// 同账号及授权下复用已确认Photos身份；Immich显示版本不作身份门禁，媒体读取仍重核Photos当前源。
    func association(assetID: String, revision _: Date) -> LocalMediaAssociation? {
        _ = revision
        guard enabled, sourcePolicyReady, scope != nil, let manager, managerGeneration == manager.generation,
              let id = UUID(uuidString: assetID), !rejectedDisplayAssociationIDs.contains(id) else { return nil }
        if let access, inventory.authorization == access, let stronger = associations[id] {
            return stronger
        }
        guard let displayAssociationsAccess, inventory.authorization == displayAssociationsAccess, !rejectedDisplayAssociationIDs.contains(id) else { return nil }
        return displayAssociations[id]
    }

    /// 只暴露不透明证明epoch；新扫描/关闭/权限或账号退役都撤销尚未完成的明确组织操作。
    var albumOrganizationGeneration: UUID {
        generation
    }

    /// localIDs只来自已保存包含减排除后的当前相簿源；只重核已有匹配，不发起新字节匹配或请求Photos授权。
    /// metadata来源重新取当前完整metadata证据链；缺本机hash不等于缺组织依据，但旧UUID/旧revision单独不够。
    func albumOrganizationAssociations(localIDs: Set<String>, using manager: LibraryManagementController) async throws -> [LocalMediaAssociation] {
        guard self.manager === manager, let scope, manager.backupScope == scope, enabled,
              let access, inventory.authorization == access, access == .full || access == .limited else { return [] }
        let owner = manager.generation, run = generation, stamp = revision
        let validateContext: @MainActor () throws -> Void = {
            try self.validate(manager, owner: owner, scope: scope, run: run, expectedAccess: access)
            guard self.enabled, self.revision == stamp else { throw LocalMediaMetadataError.sourceChanged }
        }
        let remote: any LocalMediaMatchingReading
        if let remoteOverride {
            remote = remoteOverride
        } else if let client = manager.client {
            remote = client
        } else {
            throw LibraryWriteError.unavailable
        }
        let selected = associations.values.filter { $0.source != .exactCloudIdentity && localIDs.contains($0.localIdentity.localIdentifier) }
        let ids = Array(Set(selected.map(\.localIdentity.localIdentifier))).sorted()
        var snapshots: [String: LocalPhotoSnapshot] = [:]
        for start in stride(from: 0, to: ids.count, by: 64) {
            let batch = Array(ids[start ..< min(start + 64, ids.count)])
            let values = try await metadata.snapshots(for: batch, validateContext: validateContext)
            try validateContext(); try validateSnapshots(values, requested: batch)
            for value in values {
                snapshots[value.identity.localIdentifier] = value
            }
        }
        var result: [LocalMediaAssociation] = []
        for association in selected {
            try validateContext()
            guard let snapshot = snapshots[association.localIdentity.localIdentifier], snapshot.identity == association.localIdentity else { continue }
            if association.source == .mobileMetadata {
                guard let client = manager.client else { throw LibraryWriteError.unavailable }
                // 已有精确UUID不需重扫全库stream；官方单资产GET提供当前mobile-app，仍逐字段与当前Photos metadata比较。
                let current = try await client.albumSyncMetadata(association.remoteID)
                try validateContext()
                let candidateValue = LocalMediaRemoteCandidate(assetID: association.remoteID, metadata: current)
                guard case let .candidate(candidate) = try LocalMediaMatch.resolve(expected: association.localIdentity, snapshot: snapshot, candidates: [candidateValue]),
                      candidate.assetID == association.remoteID else { continue }
            }
            guard let fresh = try await freshCandidate(association.remoteID, using: remote, validateContext: validateContext),
                  fresh.updatedAt == association.remoteRevision,
                  let verified = LocalMediaAssociation.verified(remote: fresh, requestedID: association.remoteID, ownerID: scope.userID,
                                                                local: snapshot.identity, source: association.source, expectedChecksum: association.checksum) else { continue }
            result.append(verified)
        }
        try validateContext()
        return result
    }

    /// 明确停止当前前台扫描；只保留此前已经完成fresh验证的内存关联，不宣称扫描完成。
    func cancel() {
        if fullLibraryReconciler != nil {
            pauseFullLibraryMatching(); return
        }
        guard running else { return }
        invalidateRun()
        statusMessage = "扫描已停止；保留已确认关联，未完成项目不算匹配成功。"
    }

    /// root在media configure/前台恢复后调用；不弹Photos权限。相同代际只恢复/自动刷新一次，正在运行时复用任务。
    /// Suspends network and Photos matching without revoking already committed display identities.
    func suspendFullLibraryMatching() {
        guard let fullLibraryReconciler else { return }
        fullLibraryActive = false
        fullLibraryReconciler.pause()
        task?.cancel()
    }

    /// Explicit pause survives foreground transitions; it never pauses or changes backup uploads.
    func pauseFullLibraryMatching() {
        guard fullLibraryReconciler != nil else { return }
        fullLibraryUserPaused = true
        if let scope {
            UserDefaults.standard.set(true, forKey: "LocalPhotoDisplayReconciliation.userPaused.\(scope.cacheNamespace)")
        }
        suspendFullLibraryMatching()
    }

    @discardableResult
    func resumeFullLibraryMatching(using manager: LibraryManagementController, userInitiated: Bool = true) -> Task<Void, Never>? {
        guard fullLibraryReconciler != nil else { return nil }
        configure(using: manager, scope: manager.backupScope ?? scope)
        if userInitiated {
            fullLibraryUserPaused = false
            if let scope {
                UserDefaults.standard.set(false, forKey: "LocalPhotoDisplayReconciliation.userPaused.\(scope.cacheNamespace)")
            }
        }
        fullLibraryActive = true
        return startFullLibraryFlow(using: manager, requestPermission: userInitiated)
    }

    /// Hints are metadata identity evidence only. The backup checker revalidates Photos and
    /// the remote asset; it must not promote these links to original-byte completion proof.
    func backupDisplayAliasEvidence(localIDs: [String], scope requestedScope: MediaAccountScope) async throws -> [PhotoBackupDisplayAliasEvidence] {
        guard localIDs.count <= 64, Set(localIDs).count == localIDs.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        guard !localIDs.isEmpty, fullLibraryReconciler != nil, let reconciliationStore,
              scope == requestedScope, let manager, managerGeneration == manager.generation else { return [] }
        let owner = manager.generation, run = generation, expectedAccess = inventory.authorization
        guard expectedAccess == .full || expectedAccess == .limited else { throw LocalMediaMetadataError.permission }
        let evidence = try await reconciliationStore.displayAliasEvidence(localIDs: localIDs, scope: requestedScope, access: expectedAccess)
        try validate(manager, owner: owner, scope: requestedScope, run: run, expectedAccess: expectedAccess, requireOnline: false)
        let requested = Set(localIDs)
        guard evidence.count <= 64, Set(evidence.map(\.work.localID)).count == evidence.count,
              evidence.allSatisfy({ requested.contains($0.work.localID) && $0.work.localID == $0.association.localIdentity.localIdentifier
                      && $0.work.result == .matched && $0.work.reason == .matched && $0.work.cloudID != nil })
        else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        return evidence
    }

    /// One coalesced refresh after original backup publishes new identity evidence. It reads
    /// accepted metadata before changing counts and preserves the user's explicit pause.
    @discardableResult
    func originalBackupEvidenceDidChange(using manager: LibraryManagementController) -> Task<Void, Never>? {
        guard fullLibraryReconciler != nil, self.manager === manager,
              managerGeneration == manager.generation, let scope, manager.backupScope == scope else { return nil }
        fullLibraryEvidenceRefreshRequested = true
        guard enabled, fullLibraryActive, !fullLibraryUserPaused else { return nil }
        if task != nil {
            fullLibraryReconciler?.pause()
            task?.cancel()
        }
        return startFullLibraryFlow(using: manager, requestPermission: false)
    }

    private func cacheDisplayAssociation(_ value: LocalMediaAssociation) {
        forgetImmichUnlinked(value.remoteID)
        guard !rejectedDisplayAssociationIDs.contains(value.remoteID) else { return }
        let inserted = knownDisplayRemoteIDs.insert(value.remoteID).inserted
        displayAssociations[value.remoteID] = value
        displayHotOrder.removeAll { $0 == value.remoteID }
        displayHotOrder.append(value.remoteID)
        while displayHotOrder.count > displayHotLimit {
            displayAssociations.removeValue(forKey: displayHotOrder.removeFirst())
        }
        if inserted, associations[value.remoteID] == nil {
            metadataMatches += 1
        }
    }

    /// Cold restore loads only keys plus at most 512 mapping payloads. The worker awaits this
    /// callback after accepting a snapshot, so an old page can never overwrite newer batches.
    private func restoreFullLibraryDisplayIndex(using manager: LibraryManagementController, scope: MediaAccountScope,
                                                owner: UUID, run: UUID, access expectedAccess: LocalPhotoLibraryAccess) async throws
    {
        sourcePolicyReady = false
        invalidateImmichUnlinkedDecisions()
        displayIndexEpoch = UUID()
        for lookup in sharedDisplayLookups.values {
            lookup.cancel()
        }
        sharedDisplayLookups.removeAll()
        permit.invalidate(); permit = LocalMediaSavePermit()
        let known = try await displayPersistence.knownRemoteIDs(scope: scope, access: expectedAccess)
        try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: expectedAccess, requireOnline: false)
        var hot: [UUID: LocalMediaAssociation] = [:], order: [UUID] = [], after: UUID?
        while hot.count < displayHotLimit {
            let page = try await displayPersistence.loadPage(after: after, limit: min(64, displayHotLimit - hot.count), scope: scope, access: expectedAccess)
            try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: expectedAccess, requireOnline: false)
            for value in page where !rejectedDisplayAssociationIDs.contains(value.remoteID) {
                hot[value.remoteID] = value; order.append(value.remoteID)
            }
            guard let last = page.last, page.count == 64 else { break }
            after = last.remoteID
        }
        knownDisplayRemoteIDs = known.subtracting(rejectedDisplayAssociationIDs)
        displayAssociations = hot; displayHotOrder = order; displayAssociationsAccess = expectedAccess
        publishCounts(); sourcePolicyReady = true; revision += 1
    }

    @discardableResult
    private func startFullLibraryFlow(using manager: LibraryManagementController, requestPermission: Bool) -> Task<Void, Never>? {
        guard let worker = fullLibraryReconciler, reconciliationStore != nil, self.manager === manager,
              let scope, fullLibraryActive else { return nil }
        let retiringOperation = task
        if let task, !task.isCancelled {
            return task
        }
        let owner = manager.generation, run = generation, callbackOwner = UUID()
        fullLibraryFlowOwner = callbackOwner
        running = true
        let operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if fullLibraryCallbackOwner == callbackOwner {
                    worker.onSnapshotAccepted = nil; worker.onLinksCommitted = nil
                    fullLibraryCallbackOwner = nil
                }
                if fullLibraryFlowOwner == callbackOwner {
                    fullLibraryFlowOwner = nil
                    if generation == run {
                        running = false; task = nil
                    }
                }
            }
            do {
                await retiringOperation?.value
                await worker.waitForRetirement()
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                fullLibraryPublicationValid = true
                try await worker.restoreSavedProgress(scope: scope)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                if restoredNamespace != scope.cacheNamespace {
                    let document = try await persistence.load(scope: scope)
                    try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                    enabled = fullLibraryEnabledOverride ?? document?.enabled ?? true; followsBackup = true
                    access = document?.access
                    if enabled, access == inventory.authorization {
                        associations = Dictionary(uniqueKeysWithValues: (document?.associations ?? []).map { ($0.remoteID, $0) })
                    }
                    // Legacy strong proofs remain isolated from the display-only SQLite and backup journal.
                    if enabled, let shared = try await backupAssociationLoader?(scope) {
                        try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                        access = inventory.authorization
                        for value in shared {
                            accept(value)
                        }
                    }
                    restoredNamespace = scope.cacheNamespace
                }
                if let enabledOverride = fullLibraryEnabledOverride {
                    let setting = LocalMediaAssociationDocument(scope: scope, enabled: enabledOverride, access: access,
                                                                associations: Array(associations.values), followsBackup: true)
                    guard try await persistence.save(setting, scope: scope, permit: permit) else { throw CancellationError() }
                    try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                    fullLibraryEnabledOverride = nil
                }
                guard enabled else { sourcePolicyReady = true; return }
                let currentPermission: LocalPhotoLibraryAccess = if requestPermission {
                    await inventory.requestAuthorization()
                } else {
                    inventory.authorization
                }
                permission = currentPermission
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                guard permission == .full || permission == .limited else { throw LocalMediaMetadataError.permission }
                let authorizedAccess = permission
                access = authorizedAccess
                if !sourcePolicyReady || displayAssociationsAccess != authorizedAccess {
                    try await restoreFullLibraryDisplayIndex(using: manager, scope: scope, owner: owner, run: run, access: authorizedAccess)
                }
                startMonitoringIfNeeded()
                guard fullLibraryActive, !fullLibraryUserPaused, let client = manager.client, manager.backupScope == scope else { return }
                if !requestPermission, !fullLibraryEvidenceRefreshRequested,
                   [.completed, .needsReview, .waiting, .blocked].contains(worker.state)
                {
                    return
                }
                let validateContext: @MainActor @Sendable () throws -> Void = {
                    try self.validate(manager, owner: owner, scope: scope, run: run, expectedAccess: authorizedAccess)
                    guard self.enabled, self.fullLibraryActive, !self.fullLibraryUserPaused,
                          self.fullLibraryPublicationValid else { throw CancellationError() }
                }
                fullLibraryCallbackOwner = callbackOwner
                worker.onSnapshotAccepted = { [weak self] in
                    guard let self else { return }
                    do {
                        try validateContext()
                        try await restoreFullLibraryDisplayIndex(using: manager, scope: scope, owner: owner, run: run, access: authorizedAccess)
                    } catch {
                        if generation == run {
                            sourcePolicyReady = false; fullLibraryPublicationValid = false
                        }
                    }
                }
                worker.onLinksCommitted = { [weak self] links in
                    guard let self else { return }
                    do { try validateContext() } catch { return }
                    for value in links {
                        cacheDisplayAssociation(value)
                    }
                    displayAssociationsAccess = authorizedAccess
                    total = worker.progress.totalLocal
                    scanned = worker.progress.processedLocal
                    revision += 1
                }
                if let work = worker.run(scope: scope, remote: client, mode: .resumePersistedIdentities, validateContext: validateContext) {
                    fullLibraryEvidenceRefreshRequested = false
                    await work.value
                    try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: authorizedAccess, requireOnline: false)
                    total = worker.progress.totalLocal; scanned = worker.progress.processedLocal
                    unmatched = worker.progress.unmatchedLocal; metadataFailures = worker.progress.pendingLocal
                }
            } catch {
                guard generation == run, manager.generation == owner else { return }
                permission = inventory.authorization
                if !sourcePolicyReady {
                    statusMessage = "Photos identity matching is not ready. Saved progress is retained."
                }
            }
        }
        task = operation
        return operation
    }

    @discardableResult func restoreAndRefresh(using manager: LibraryManagementController, scope: MediaAccountScope?) -> Task<Void, Never>? {
        configure(using: manager, scope: scope)
        if fullLibraryReconciler != nil {
            return startFullLibraryFlow(using: manager, requestPermission: false)
        }
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
            if enabled, followsBackup {
                return startCompletedAssociationRecovery(using: manager)
            }
            guard enabled, !followsBackup, automaticGeneration != manager.generation, manager.client != nil,
                  inventory.authorization == .full || inventory.authorization == .limited else { return nil }
            automaticGeneration = manager.generation
            return startScan(using: manager, requestPermission: false)
        }
        let run = generation; let owner = manager.generation
        let operation = Task {
            var restored = false
            defer {
                if generation == run {
                    task = nil
                    if restored {
                        _ = startCompletedAssociationRecovery(using: manager)
                    }
                }
            }
            do {
                let document = try await persistence.load(scope: scope)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                restoredNamespace = scope.cacheNamespace
                enabled = document?.enabled ?? false
                // 旧配置升级到共享匹配，不因缺少新字段而重新启动独立整库扫描。
                followsBackup = document?.followsBackup ?? true
                access = document?.access
                if enabled, document?.access == inventory.authorization {
                    associations = Dictionary(uniqueKeysWithValues: (document?.associations ?? []).map { ($0.remoteID, $0) })
                    publishCounts(); revision += 1
                }
                if enabled, followsBackup {
                    let shared = try await backupAssociationLoader?(scope) ?? []
                    try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                    access = inventory.authorization
                    for value in shared {
                        accept(value)
                    }
                }
                let displayAccess = inventory.authorization
                if enabled, displayAccess == .full || displayAccess == .limited {
                    let display = try await displayPersistence.load(scope: scope, access: displayAccess)
                    try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: displayAccess, requireOnline: false)
                    displayAssociations = Dictionary(uniqueKeysWithValues: display.filter { !rejectedDisplayAssociationIDs.contains($0.remoteID) }.map { ($0.remoteID, $0) })
                    displayAssociationsAccess = displayAccess; publishCounts(); revision += 1
                }
                permission = inventory.authorization
                startMonitoringIfNeeded()
                restored = true
                guard enabled, !followsBackup, automaticGeneration != owner, manager.client != nil, permission == .full || permission == .limited else { return }
                automaticGeneration = owner
                task = nil
                if let scan = startScan(using: manager, requestPermission: false) {
                    await scan.value
                }
            } catch {
                guard generation == run, manager.generation == owner else { return }
                statusMessage = "无法恢复本机关联：\(error.localizedDescription)。未覆盖已有资料。"
            }
        }
        task = operation; return operation
    }

    /// headless组织专用冷恢复：只读取同账号已保存关联，不启动全库扫描/hash、Photos授权或iCloud媒体访问。
    /// manager/scope是当前processing租约身份；应使用独立Controller，所有关联随后仍由组织路径逐项fresh核证。
    func restoreForAlbumOrganization(using manager: LibraryManagementController, scope: MediaAccountScope) async throws {
        configure(using: manager, scope: scope)
        guard !running else { throw LibraryWriteError.busy }
        let run = generation, owner = manager.generation
        let document = try await persistence.load(scope: scope)
        try validate(manager, owner: owner, scope: scope, run: run)
        enabled = document?.enabled ?? false
        access = document?.access
        if enabled, document?.access == inventory.authorization {
            associations = Dictionary(uniqueKeysWithValues: (document?.associations ?? []).map { ($0.remoteID, $0) })
        } else {
            associations = [:]
        }
        restoredNamespace = scope.cacheNamespace
        publishCounts(); revision += 1
    }

    /// 仅用户操作改变启用配置；关闭立即失效关联并保存，启用后显式扫描可请求初次Photos授权。
    @discardableResult func setEnabled(_ value: Bool, using manager: LibraryManagementController, followBackup: Bool = false) -> Task<Void, Never>? {
        guard self.manager === manager, let scope else { return nil }
        if fullLibraryReconciler != nil {
            invalidateRun()
            enabled = value; followsBackup = true; fullLibraryEnabledOverride = value
            fullLibraryActive = true
            if !value {
                monitor?.stop(); monitor = nil
            }
            return startFullLibraryFlow(using: manager, requestPermission: value)
        }
        invalidateRun(); enabled = value; followsBackup = followBackup; associations = [:]; displayAssociations = [:]; displayAssociationsAccess = nil; revision += 1; publishCounts()
        metadataFailures = 0
        access = nil; automaticGeneration = manager.generation
        if value {
            startMonitoringIfNeeded()
            if !followBackup, let scan = startScan(using: manager, requestPermission: true) {
                return scan
            }
        } else {
            monitor?.stop(); monitor = nil
        }
        let run = generation; let owner = manager.generation; let writePermit = permit
        let document = LocalMediaAssociationDocument(scope: scope, enabled: value, access: nil, associations: [], followsBackup: followsBackup)
        let operation = Task {
            do {
                let saved = try await persistence.save(document, scope: scope, permit: writePermit)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                guard saved else { return }
                if value, followBackup, inventory.authorization == .full || inventory.authorization == .limited {
                    let shared = try await backupAssociationLoader?(scope) ?? []
                    try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                    access = inventory.authorization; permission = inventory.authorization
                    for association in shared {
                        accept(association)
                    }
                }
                let displayAccess = inventory.authorization
                if value, displayAccess == .full || displayAccess == .limited {
                    let display = try await displayPersistence.load(scope: scope, access: displayAccess)
                    try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: displayAccess, requireOnline: false)
                    displayAssociations = Dictionary(uniqueKeysWithValues: display.filter { !rejectedDisplayAssociationIDs.contains($0.remoteID) }.map { ($0.remoteID, $0) })
                    displayAssociationsAccess = displayAccess; publishCounts(); revision += 1
                }
                statusMessage = value ? (followBackup ? "使用照片同步的匹配结果，无需单独扫描。" : "已保存启用配置；连接服务器后自动匹配。") : "已关闭本机优先，不修改或删除任何照片。"
            } catch {
                guard generation == run else { return }
                statusMessage = "本次设置已改变，但配置保存失败：\(error.localizedDescription)。"
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
        if fullLibraryReconciler != nil {
            return startFullLibraryFlow(using: manager, requestPermission: requestPermission)
        }
        guard self.manager === manager, !running, let scope, manager.backupScope == scope, let client = manager.client else { return nil }
        let baseRemote: any LocalMediaMatchingReading = remoteOverride ?? client
        let owner = manager.generation
        automaticGeneration = owner
        let run = UUID(); generation = run; running = true
        permit.invalidate(); permit = LocalMediaSavePermit(); let writePermit = permit
        // 保留已确认映射供当前窗口/离线使用；本轮发现的变更由实际媒体reader复核，不把扫描进度当作完成。
        total = 0; scanned = 0; unmatched = 0; metadataFailures = 0
        statusMessage = "正在确认照片访问权限…"
        let operation = Task {
            defer {
                if generation == run {
                    running = false; task = nil
                }
            }
            do {
                try validate(manager, owner: owner, scope: scope, run: run)
                let setting = LocalMediaAssociationDocument(scope: scope, enabled: enabled, access: access, associations: Array(associations.values), followsBackup: followsBackup)
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
                let remote = LocalMediaRetryingQueries(base: baseRemote, retry: .init(validate: validateContext, status: { [weak self] message in
                    self?.statusMessage = message
                }))
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
                    statusMessage = "读取本机元数据 \(min(start + 64, ids.count))/\(total)…"
                    await Task.yield(); try validateContext()
                }
                statusMessage = "只读匹配Immich元数据…"
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
                        statusMessage = "Immich元数据暂不可用，继续仅用本机校验和匹配。"
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
                            let fresh = try await freshCandidate(candidate.assetID, using: remote, validateContext: validateContext)
                            if let fresh,
                               let value = LocalMediaAssociation.verified(remote: fresh, requestedID: candidate.assetID, ownerID: scope.userID, local: snapshot.identity, source: .mobileMetadata)
                            {
                                accept(value); confirmedRemoteIDs.insert(value.remoteID); confirmed = true
                            } else {
                                // 明确不可读只撤销此候选；独立本机字节仍可能找到另一个当前可读副本。
                                try await removeAssociation(candidate.assetID, invalidatingDisplay: rejectsDisplayIdentity(fresh, requestedID: candidate.assetID, ownerID: scope.userID, local: snapshot.identity))
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
                        statusMessage = "已检查 \(scanned)/\(total)，仅确认安全可用关联。"
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
                                let fresh = try await freshCandidate(id, using: remote, validateContext: validateContext)
                                if let fresh,
                                   let value = LocalMediaAssociation.verified(remote: fresh, requestedID: id, ownerID: scope.userID, local: item.proof.source.identity,
                                                                              source: .checksum, expectedChecksum: item.proof.digest.sha1Base64)
                                {
                                    accept(value); confirmedRemoteIDs.insert(value.remoteID)
                                } else {
                                    try await removeAssociation(id, invalidatingDisplay: rejectsDisplayIdentity(fresh, requestedID: id, ownerID: scope.userID, local: item.proof.source.identity)); unmatched += 1
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
                let document = LocalMediaAssociationDocument(scope: scope, enabled: enabled, access: access, associations: Array(associations.values), followsBackup: followsBackup)
                let saved = try await persistence.save(document, scope: scope, permit: writePermit)
                try validateContext()
                guard saved else { throw CancellationError() }
                restoredNamespace = scope.cacheNamespace
                statusMessage = permission == .limited ? "已完成当前授权范围匹配并保存；未授权照片未扫描。" : "已完成匹配并保存；下次启动自动恢复，本机优先显示和播放。"
                if metadataFailures > 0 {
                    statusSuffix = " 部分元数据不可用，已独立尝试本机校验和。"
                }
            } catch {
                guard generation == run, manager.generation == owner, manager.backupScope == scope else { return }
                self.permission = inventory.authorization
                statusMessage = error is CancellationError ? "扫描已停止，未完成项目不算匹配成功。" : "扫描未完成：\(error.localizedDescription)。只保留已确认关联，可重新扫描。"
            }
        }
        task = operation
        return operation
    }

    /// id来自本轮metadata/precheck；remote只读候选，validateContext在解释成功或错误前重验Task/账号/权限。
    /// 仅窄typed不可读返回nil，由调用方撤销该ID并继续；其他HTTP、解码和网络错误原样抛出。
    private func freshCandidate(_ id: UUID, using remote: any LocalMediaMatchingReading,
                                validateContext: @MainActor () throws -> Void) async throws -> LocalMediaRemoteAsset?
    {
        try validateContext()
        let fresh: LocalMediaRemoteAsset
        do { fresh = try await remote.localMediaAsset(id.uuidString) }
        catch {
            try validateContext()
            if case LocalMediaCandidateError.inaccessible = error {
                return nil
            }
            throw error
        }
        try validateContext()
        return fresh
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
        try validateContext()
        let result = try await Self.decodeMetadataCandidates(records)
        try validateContext()
        return result
    }

    @concurrent private static func decodeMetadataCandidates(_ records: [LocalMediaRemoteMetadataRecord]) async throws -> (candidates: [String: [LocalMediaRemoteCandidate]], rejected: Int) {
        var candidates: [String: [LocalMediaRemoteCandidate]] = [:]
        var blocked = Set<String>()
        var rejected = 0
        let decoder = JSONDecoder()
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            do {
                let metadata = try decoder.decode(LocalMediaMobileMetadata.self, from: record.value)
                candidates[metadata.cloudId, default: []].append(.init(assetID: record.assetID, metadata: metadata))
            } catch {
                guard let object = try JSONSerialization.jsonObject(with: record.value) as? [String: Any], let id = object["iCloudId"] as? String else { throw LocalMediaMetadataError.invalidMetadata }
                blocked.insert(id); rejected += 1
            }
        }
        for id in blocked {
            candidates[id] = []
        }
        try Task.checkCancellation()
        return (candidates, rejected)
    }

    /// 同远端对象保留最新确认版本；按变化增减来源计数，避免每确认一项都全库重算。
    private func accept(_ association: LocalMediaAssociation) {
        forgetImmichUnlinked(association.remoteID)
        guard association.source != .exactCloudIdentity,
              !rejectedDisplayAssociationIDs.contains(association.remoteID) else { return }
        let hadDisplay = fullLibraryReconciler != nil ? knownDisplayRemoteIDs.contains(association.remoteID) : displayAssociations[association.remoteID] != nil
        displayAssociations.removeValue(forKey: association.remoteID)
        if hadDisplay, associations[association.remoteID] == nil {
            metadataMatches -= 1
        }
        let previous = associations[association.remoteID]
        guard previous != association else { return }
        if let previous {
            unindexChecksum(previous)
            if previous.source == .mobileMetadata {
                metadataMatches -= 1
            } else {
                checksumMatches -= 1
            }
        }
        associations[association.remoteID] = association
        checksumAssociationIDs[association.checksum, default: []].insert(association.remoteID)
        if association.source == .mobileMetadata {
            metadataMatches += 1
        } else {
            checksumMatches += 1
        }
        revision += 1
    }

    /// 派生来源计数与已确认远端对象一致；本机重复副本不伪造新增照片数。
    private func publishCounts() {
        checksumAssociationIDs = [:]
        for value in associations.values {
            checksumAssociationIDs[value.checksum, default: []].insert(value.remoteID)
        }
        let displayIDs = fullLibraryReconciler == nil ? Set(displayAssociations.keys) : knownDisplayRemoteIDs
        metadataMatches = associations.values.filter { $0.source == .mobileMetadata }.count + displayIDs.filter { associations[$0] == nil }.count
        checksumMatches = associations.values.filter { $0.source == .checksum }.count
    }

    /// 强proof不足只撤销强层；明确身份拒绝还撤销同ID展示层，不把它解释为Photos对象不存在。
    private func removeAssociation(_ id: UUID, invalidatingDisplay: Bool) async throws {
        let removed = associations.removeValue(forKey: id)
        let hadDisplay = fullLibraryReconciler != nil ? knownDisplayRemoteIDs.contains(id) : displayAssociations[id] != nil
        if invalidatingDisplay {
            displayAssociations.removeValue(forKey: id); knownDisplayRemoteIDs.remove(id)
            displayHotOrder.removeAll { $0 == id }
        }
        if let removed {
            unindexChecksum(removed)
            if removed.source == .mobileMetadata {
                metadataMatches -= 1
            } else {
                checksumMatches -= 1
            }
            if !invalidatingDisplay, hadDisplay {
                metadataMatches += 1
            }
        } else if invalidatingDisplay, hadDisplay {
            metadataMatches -= 1
        }
        revision += 1
        if invalidatingDisplay {
            rejectedDisplayAssociationIDs.insert(id)
            if let scope {
                let writePermit = permit
                guard try await mutateDisplayAssociation(id, operation: {
                    try await self.displayPersistence.remove(id, scope: scope, permit: writePermit)
                }) else { throw CancellationError() }
            }
        }
    }

    /// 同ID删除/新证明按主Actor发起顺序提交；旧删除不能晚到并抹掉随后确认的新关系。
    private func mutateDisplayAssociation(_ id: UUID, operation: @escaping @MainActor @Sendable () async throws -> Bool) async throws -> Bool {
        let previous = displayMutations[id]?.task, run = generation, mutationID = UUID()
        let pending = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            let saved = try await operation()
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            return saved
        }
        displayMutations[id] = (mutationID, pending)
        defer {
            if displayMutations[id]?.id == mutationID {
                displayMutations.removeValue(forKey: id)
            }
        }
        return try await pending.value
    }

    /// nil只来自fresh GET明确不可访问；编辑/离线或校验和不足不等于展示身份被拒绝。
    private func rejectsDisplayIdentity(_ fresh: LocalMediaRemoteAsset?, requestedID: UUID, ownerID: String, local: LocalPhotoIdentity) -> Bool {
        guard let fresh else { return true }
        return fresh.id != requestedID || UUID(uuidString: ownerID) != fresh.ownerId || fresh.isTrashed == true
            || fresh.type != (local.mediaKind == .video ? "VIDEO" : "IMAGE")
    }

    private func unindexChecksum(_ association: LocalMediaAssociation) {
        checksumAssociationIDs[association.checksum]?.remove(association.remoteID)
        if checksumAssociationIDs[association.checksum]?.isEmpty == true {
            checksumAssociationIDs.removeValue(forKey: association.checksum)
        }
    }

    /// 只复用同账号已核验关联的相同服务器SHA1；不读取/重算Photos原片，不从日期文件名猜身份。
    private func restoreDisplayFromKnownChecksum(_ remote: LocalMediaRemoteAsset, scope: MediaAccountScope,
                                                 validateContext: @MainActor () throws -> Void) async throws -> LocalMediaAssociation?
    {
        guard let checksum = remote.checksum, let ids = checksumAssociationIDs[checksum], !ids.isEmpty else {
            traceDisplayLookup("noStoredChecksumWitness"); return nil
        }
        guard ids.count <= 64 else { traceDisplayLookup("ambiguousChecksumWitness"); return nil }
        let witnesses = ids.compactMap { associations[$0] }.filter { $0.source != .exactCloudIdentity && $0.checksum == checksum }
        let localIDs = Array(Set(witnesses.map(\.localIdentity.localIdentifier))).sorted()
        let snapshots = try await metadata.snapshots(for: localIDs, validateContext: validateContext)
        try validateContext(); try validateSnapshots(snapshots, requested: localIDs)
        guard snapshots.count == 1, let snapshot = snapshots.first,
              let witness = witnesses.first(where: { $0.localIdentity.localIdentifier == snapshot.identity.localIdentifier }),
              let value = LocalMediaAssociation.verified(remote: remote, requestedID: remote.id, ownerID: scope.userID,
                                                         local: snapshot.identity, source: witness.source, expectedChecksum: witness.checksum,
                                                         prefersCurrentPhotos: true)
        else {
            traceDisplayLookup("ambiguousOrUnavailableChecksumWitness"); return nil
        }
        try await backupAssociationSaver?([value], scope)
        try validateContext()
        access = inventory.authorization; accept(value)
        traceDisplayLookup("resolvedFromStoredChecksumIdentity")
        return value
    }

    /// 每次取消/路由变化撤销原子写许可；同namespace已确认关联独立保留，新的任务拿新的代际。
    private func invalidateRun() {
        invalidateImmichUnlinkedDecisions()
        fullLibraryReconciler?.pause()
        for mutation in displayMutations.values {
            mutation.task.cancel()
        }
        displayMutations.removeAll()
        for lookup in sharedDisplayLookups.values {
            lookup.cancel()
        }
        sharedDisplayLookups.removeAll()
        missedDisplayLookups.removeAll()
        permit.invalidate(); permit = LocalMediaSavePermit()
        task?.cancel(); task = nil; changeTask?.cancel(); changeTask = nil
        recoveringCompletedAssociations = false
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
        invalidateImmichUnlinkedDecisions()
        if fullLibraryReconciler != nil {
            let currentAccess = inventory.authorization
            permission = currentAccess
            if displayAssociationsAccess != currentAccess {
                invalidateRun(); sourcePolicyReady = false
                knownDisplayRemoteIDs = []; displayAssociations = [:]; displayHotOrder = []
                displayAssociationsAccess = nil; access = nil; associations = [:]; publishCounts()
                _ = startFullLibraryFlow(using: manager, requestPermission: false)
            }
            // Ordinary Photos/iCloud notifications do not restart a whole-library stream.
            // The media reader and each worker batch recheck the current Photos observation.
            revision += 1
            return
        }
        if followsBackup {
            // 共享映射是持久事实。撤销在途组织/匹配许可，但不因无关新增或iCloud变化清空整库。
            // 展示reader仍逐项核对当前Photos授权、修改时间和对象观察，失效源不能命中本机缓存。
            invalidateRun(); revision += 1
            let previousAccess = access
            permission = inventory.authorization
            access = permission == .full || permission == .limited ? permission : nil
            if previousAccess != access {
                displayAssociations = [:]; displayAssociationsAccess = nil; publishCounts()
            }
            if access == nil {
                associations = [:]; displayAssociations = [:]; displayAssociationsAccess = nil; publishCounts()
            }
            let run = generation, owner = manager.generation
            changeTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                    guard inventory.authorization == .full || inventory.authorization == .limited else { changeTask = nil; return }
                    if associations.isEmpty {
                        let saved = try await backupAssociationLoader?(scope) ?? []
                        try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                        access = inventory.authorization
                        for value in saved {
                            accept(value)
                        }
                    }
                    if displayAssociations.isEmpty {
                        let displayAccess = inventory.authorization
                        let display = try await displayPersistence.load(scope: scope, access: displayAccess)
                        try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: displayAccess, requireOnline: false)
                        displayAssociations = Dictionary(uniqueKeysWithValues: display.filter { !rejectedDisplayAssociationIDs.contains($0.remoteID) }.map { ($0.remoteID, $0) })
                        displayAssociationsAccess = displayAccess
                        publishCounts(); revision += 1
                    }
                    changeTask = nil
                    statusMessage = "已保留离线浏览映射；每张照片由PhotoKit核对当前权限和版本，不依赖服务器重新匹配。"
                    _ = startCompletedAssociationRecovery(using: manager)
                } catch {
                    guard generation == run else { return }
                    changeTask = nil
                }
            }
            return
        }
        invalidateRun(); associations = [:]; displayAssociations = [:]; displayAssociationsAccess = nil; access = nil; revision += 1; publishCounts(); automaticGeneration = nil
        metadataFailures = 0
        permission = inventory.authorization
        statusMessage = "本机照片库或权限已变化，旧关联已失效；等待重新匹配。"
        let run = generation; let owner = manager.generation; let writePermit = permit
        changeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                let document = LocalMediaAssociationDocument(scope: scope, enabled: true, access: nil, associations: [], followsBackup: followsBackup)
                _ = try await persistence.save(document, scope: scope, permit: writePermit)
                try validate(manager, owner: owner, scope: scope, run: run, requireOnline: false)
                changeTask = nil
                guard !followsBackup, manager.client != nil, inventory.authorization == .full || inventory.authorization == .limited else { return }
                automaticGeneration = owner
                if let task = startScan(using: manager, requestPermission: false) {
                    await task.value
                }
            } catch {
                guard generation == run else { return }
                changeTask = nil; statusMessage = "照片库已变化，旧关联失效；等待下次可用刷新。"
            }
        }
    }

    /// 旧完成记录只补浏览映射：一次metadata流、64项Photos/资产批次、逐批落盘，不重排任务、不读原片、不写服务器。
    @discardableResult private func startCompletedAssociationRecovery(using manager: LibraryManagementController) -> Task<Void, Never>? {
        if fullLibraryReconciler != nil {
            return startFullLibraryFlow(using: manager, requestPermission: false)
        }
        guard !Task.isCancelled, completedRecoveryActive, enabled, followsBackup, !running, task == nil, self.manager === manager,
              let scope, scope == manager.backupScope, let client = manager.client,
              let loader = completedBackupLoader, let saver = backupAssociationSaver,
              completedRecoveryGeneration != manager.generation,
              inventory.authorization == .full || inventory.authorization == .limited else { return nil }
        let owner = manager.generation, run = generation, permission = inventory.authorization
        running = true; recoveringCompletedAssociations = true; access = permission
        let validateContext: @MainActor () throws -> Void = {
            try self.validate(manager, owner: owner, scope: scope, run: run, expectedAccess: permission)
        }
        let operation = Task {
            defer {
                if generation == run {
                    running = false; recoveringCompletedAssociations = false; task = nil
                }
            }
            do {
                let jobs = try await loader(scope)
                try validateContext()
                let saved = Set(associations.values.filter { $0.displayRevision != nil }.map(\.localIdentity))
                let pending = await Self.pendingCompletedJobs(jobs, saved: saved)
                try validateContext()
                total = pending.count; scanned = 0
                guard !pending.isEmpty else { completedRecoveryGeneration = owner; return }
                statusMessage = "正在补齐已完成项目的离线浏览关联；不会重新备份或下载原片。"
                let retry = PhotoSyncRetry(validate: validateContext, status: { [weak self] in self?.statusMessage = $0 })
                let records = try await retry.call { try await client.localMediaMetadataSnapshot() }
                try validateContext()
                let decoded = try await metadataCandidates(records, validateContext: validateContext)
                for start in stride(from: 0, to: pending.count, by: 64) {
                    try validateContext()
                    let batch = Array(pending[start ..< min(start + 64, pending.count)])
                    let ids = Array(Set(batch.map(\.source.localID))).sorted()
                    let snapshots = try await metadata.snapshots(for: ids, validateContext: validateContext)
                    try validateContext(); try validateSnapshots(snapshots, requested: ids)
                    let byLocal = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.localIdentifier, $0) })
                    var candidates: [UUID: (snapshot: LocalPhotoSnapshot, checksum: String?)] = [:]
                    for job in batch {
                        guard let snapshot = byLocal[job.source.localID], snapshot.identity == Self.displayIdentity(job.source) else { continue }
                        if job.stage == .completed, let id = job.primaryAssetID, let checksum = job.primaryChecksum {
                            candidates[id] = (snapshot, checksum)
                        } else if case let .resolved(cloud) = snapshot.cloudIdentity,
                                  case let .candidate(candidate) = try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: snapshot,
                                                                                               candidates: decoded.candidates[cloud] ?? [])
                        {
                            candidates[candidate.assetID] = (snapshot, nil)
                        }
                    }
                    if !candidates.isEmpty {
                        let requested = Array(candidates.keys)
                        let remote = try await retry.call { try await client.localMediaAssets(requested) }
                        try validateContext()
                        let current = try await metadata.snapshots(for: ids, validateContext: validateContext)
                        try validateContext(); try validateSnapshots(current, requested: ids)
                        let byCurrent = Dictionary(uniqueKeysWithValues: current.map { ($0.identity.localIdentifier, $0) })
                        let verified = remote.compactMap { remote -> LocalMediaAssociation? in
                            guard let candidate = candidates[remote.id],
                                  byCurrent[candidate.snapshot.identity.localIdentifier] == candidate.snapshot else { return nil }
                            return .verified(remote: remote, requestedID: remote.id, ownerID: scope.userID, local: candidate.snapshot.identity,
                                             source: candidate.checksum == nil ? .mobileMetadata : .checksum, expectedChecksum: candidate.checksum)
                        }
                        if !verified.isEmpty {
                            try await saver(verified, scope)
                            try validateContext()
                            for value in verified {
                                accept(value)
                            }
                        }
                    }
                    scanned = min(start + 64, pending.count)
                    statusMessage = "离线浏览关联已保存 \(metadataMatches + checksumMatches) 项，已检查 \(scanned) / \(total)；备份完成记录保持不变。"
                    // 后台任务让出CPU给滚动/打开图片；每批已落盘，中断后只检查缺失映射。
                    try await Task.sleep(for: .milliseconds(25))
                }
                try validateContext()
                completedRecoveryGeneration = owner
                statusMessage = "本轮关联检查完成，已保存 \(metadataMatches + checksumMatches) 项可离线浏览映射；未确认项目仍保留服务器显示，备份记录不变。"
            } catch {
                guard generation == run else { return }
                statusMessage = "离线浏览关联补齐已暂停；已保存部分可离线使用，备份完成记录保持不变。"
            }
        }
        task = operation; return operation
    }

    func pauseCompletedAssociationRecovery() {
        if fullLibraryReconciler != nil {
            suspendFullLibraryMatching(); return
        }
        completedRecoveryActive = false
        guard recoveringCompletedAssociations else { return }
        invalidateRun(); recoveringCompletedAssociations = false
        statusMessage = "离线浏览关联补齐已暂停；回到前台后从已保存进度继续。"
    }

    func resumeCompletedAssociationRecovery() {
        if fullLibraryReconciler != nil {
            fullLibraryActive = true; return
        }
        completedRecoveryActive = true
    }

    private nonisolated static func displayIdentity(_ source: PhotoBackupSource) -> LocalPhotoIdentity {
        .init(localIdentifier: source.localID, modificationDate: source.modifiedAt,
              mediaKind: source.kind == .video ? .video : source.kind == .livePhoto ? .livePhoto : .image)
    }

    @concurrent private static func pendingCompletedJobs(_ jobs: [PhotoBackupJob], saved: Set<LocalPhotoIdentity>) async -> [PhotoBackupJob] {
        jobs.filter { ($0.stage == .existing || $0.stage == .completed) && !saved.contains(displayIdentity($0.source)) }
    }

    /// 旧版备份事实不包含浏览关联时，只恢复屏幕需要的资产；不扫描或重排整份备份队列。
    func resolveDisplayAssociation(assetID: String, revision: Date, using manager: LibraryManagementController) async throws -> LocalMediaAssociation? {
        if requiresConfirmedPhotoSource {
            guard sourcePolicyReady, enabled, self.manager === manager, let scope,
                  managerGeneration == manager.generation, let id = UUID(uuidString: assetID),
                  displayAssociationsAccess == inventory.authorization
            else {
                throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
            }
            guard !rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
            if let saved = association(assetID: assetID, revision: revision) {
                return saved
            }
            let owner = manager.generation, run = generation, permission = inventory.authorization
            let lookupEpoch = displayIndexEpoch, negativeEpoch = fallbackDecisionEpoch
            // Query SQLite even if its commit has not reached the main-actor callback yet.
            let rows = try await displayPersistence.lookup(remoteIDs: [id], scope: scope, access: permission)
            try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: permission, requireOnline: false)
            guard sourcePolicyReady, displayIndexEpoch == lookupEpoch,
                  fallbackDecisionEpoch == negativeEpoch, !rejectedDisplayAssociationIDs.contains(id),
                  rows.count <= 1, rows.allSatisfy({ $0.remoteID == id })
            else {
                throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
            }
            if let saved = rows.first {
                cacheDisplayAssociation(saved); displayAssociationsAccess = permission; self.revision += 1
                return association(assetID: assetID, revision: revision) ?? saved
            }
            if hasPositivePhotoIdentity(id) {
                throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
            }
            let facts = try await displayPersistence.lookupSourceFacts(assetIDs: [id], scope: scope, access: permission)
            try validate(manager, owner: owner, scope: scope, run: run, expectedAccess: permission, requireOnline: false)
            guard sourcePolicyReady, displayIndexEpoch == lookupEpoch, fallbackDecisionEpoch == negativeEpoch,
                  !hasPositivePhotoIdentity(id), facts.count <= 1, facts.allSatisfy({ $0.assetID == id })
            else {
                throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
            }
            if let fact = facts.first, fact.displayRevision == revision,
               fact.access == permission, !declaredPhotoIdentityIDs.contains(id)
            {
                cacheImmichUnlinked(fact)
                if permitsImmichFallback(assetID: assetID, revision: revision) {
                    return nil
                }
            }
        }
        if let saved = association(assetID: assetID, revision: revision) {
            return saved
        }
        guard enabled, self.manager === manager, let scope, manager.backupScope == scope else { return nil }
        let key = "\(generation)|\(scope.cacheNamespace)|\(assetID.lowercased())|\(revision.timeIntervalSince1970)"
        if let pending = sharedDisplayLookups[key] {
            traceDisplayLookup("joinedInFlight")
            let value = try await pending.value
            try Task.checkCancellation()
            return value
        }
        guard sharedDisplayLookups.count < 64 else { traceDisplayLookup("queueCapacity"); return nil }
        let lookup = Task { [weak self] in
            try await self?.performDisplayAssociationLookup(assetID: assetID, revision: revision, using: manager)
        }
        sharedDisplayLookups[key] = lookup
        defer { sharedDisplayLookups.removeValue(forKey: key) }
        let value = try await lookup.value
        try Task.checkCancellation()
        return value
    }

    private func performDisplayAssociationLookup(assetID: String, revision: Date, using manager: LibraryManagementController) async throws -> LocalMediaAssociation? {
        if let saved = association(assetID: assetID, revision: revision) {
            return saved
        }
        guard enabled, self.manager === manager, let scope, scope == manager.backupScope,
              let id = UUID(uuidString: assetID), let client = manager.client,
              inventory.authorization == .full || inventory.authorization == .limited else { traceDisplayLookup("contextUnavailable"); return nil }
        guard !rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
        let run = generation, owner = manager.generation, permission = inventory.authorization, lookupEpoch = displayIndexEpoch
        let negativeEpoch = fallbackDecisionEpoch, negativePermit = fallbackWritePermit
        let key = "\(generation)|\(scope.cacheNamespace)|\(id)|\(revision.timeIntervalSinceReferenceDate)"
        if let missed = missedDisplayLookups[key], missed.duration(to: ContinuousClock.now) < .seconds(60) {
            traceDisplayLookup("negativeCache")
            return nil
        }
        guard pendingDisplayLookups.insert(key).inserted else { return nil }
        var ownsSlot = false
        defer {
            pendingDisplayLookups.remove(key)
            if ownsSlot {
                activeDisplayLookups -= 1
            }
        }
        let validateContext: @MainActor () throws -> Void = {
            try self.validate(manager, owner: owner, scope: scope, run: run, expectedAccess: permission)
            if self.fullLibraryReconciler != nil {
                guard self.sourcePolicyReady, self.displayIndexEpoch == lookupEpoch else {
                    throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while activeDisplayLookups >= 4 {
            try validateContext()
            guard ContinuousClock.now < deadline else { traceDisplayLookup("queueDeadline"); return nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        activeDisplayLookups += 1; ownsSlot = true
        do {
            try validateContext()
            traceDisplayLookup("evidenceRequest")
            let evidence = try await client.localPhotoDisplayEvidenceRecord(id)
            let remote = evidence.remote
            try validateContext()
            if let known = association(assetID: assetID, revision: revision) {
                return known
            }
            if requiresConfirmedPhotoSource {
                let positives = try await displayPersistence.lookup(remoteIDs: [id], scope: scope, access: permission)
                try validateContext()
                guard positives.count <= 1, positives.allSatisfy({ $0.remoteID == id }) else { throw LocalMediaMetadataError.invalidBatch }
                if let positive = positives.first {
                    cacheDisplayAssociation(positive); displayAssociationsAccess = permission; self.revision += 1
                    return positive
                }
                if evidence.hasPhotosIdentityDeclarations {
                    declaredPhotoIdentityIDs.insert(id); forgetImmichUnlinked(id)
                    _ = try await displayPersistence.removeSourceFacts(ids: [id], scope: scope, permit: negativePermit)
                    try validateContext()
                }
            }
            for category in evidence.metadataDiagnostics {
                traceDisplayLookup("rawMetadataKey." + category)
            }
            // Photos已获确认时，服务器显示时间戳不决定本机对象是否存在；缓存仍绑定Photos当前观察。
            if (remote.displayRevision ?? remote.updatedAt)?.timeIntervalSince1970 != revision.timeIntervalSince1970 {
                traceDisplayLookup("serverDisplayRevisionChanged")
            }
            if evidence.hasConflictingIdentitySources {
                traceDisplayLookup("conflictingCloudIdentitySources")
                throw LocalPhotoDisplayEvidencePending.conflictingCloudIdentitySources
            }
            if evidence.cloudIDs.isEmpty, evidence.metadataDiagnostics.contains("markerRejected") {
                traceDisplayLookup("rejectedIdentityMarker")
                throw LocalPhotoDisplayEvidencePending.rejectedIdentityMarker
            }
            if evidence.cloudIDs.isEmpty {
                traceDisplayLookup("missingCloudMetadata")
                if let restored = try await restoreDisplayFromKnownChecksum(remote, scope: scope, validateContext: validateContext) {
                    return restored
                }
                if requiresConfirmedPhotoSource, !evidence.hasPhotosIdentityDeclarations {
                    guard fallbackDecisionEpoch == negativeEpoch, !hasPositivePhotoIdentity(id),
                          remote.id == id, remote.isTrashed == false, ["IMAGE", "VIDEO"].contains(remote.type),
                          let freshRevision = remote.displayRevision ?? remote.updatedAt,
                          freshRevision == revision, freshRevision.timeIntervalSince1970.isFinite
                    else {
                        throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
                    }
                    let fact = LocalPhotoDisplaySourceFact(assetID: id, displayRevision: revision,
                                                           observedAt: Date(), access: permission)
                    guard try await displayPersistence.saveSourceFact(fact, scope: scope, permit: negativePermit) else {
                        throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed
                    }
                    try validateContext()
                    guard fallbackDecisionEpoch == negativeEpoch, !hasPositivePhotoIdentity(id),
                          !declaredPhotoIdentityIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.photoSourceNotConfirmed }
                    cacheImmichUnlinked(fact); traceDisplayLookup("immichUnlinkedConfirmed")
                    return nil
                }
                missedDisplayLookups[key] = ContinuousClock.now
                return nil
            }
            let mappings = try await LocalPhotoCloudResolver.localIDs(for: evidence.cloudIDs)
            try validateContext()
            guard !mappings.isEmpty else { traceDisplayLookup("cloudIDNotAccessibleInPhotos"); missedDisplayLookups[key] = ContinuousClock.now; return nil }
            let ids = Array(Set(mappings.values)).sorted()
            guard ids.count <= 64 else { throw LocalMediaMetadataError.invalidBatch }
            let snapshots = try await metadata.snapshots(for: ids, validateContext: validateContext)
            try validateContext(); try validateSnapshots(snapshots, requested: ids)
            if snapshots.isEmpty {
                traceDisplayLookup("photosSnapshotMissing")
            }
            var matches: [LocalMediaAssociation] = []
            for snapshot in snapshots {
                guard case let .resolved(cloud) = snapshot.cloudIdentity, mappings[cloud] == snapshot.identity.localIdentifier,
                      let source = evidence.displaySource(for: cloud),
                      let value = LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: scope.userID,
                                                                 local: snapshot.identity, source: source, prefersCurrentPhotos: true) else { continue }
                matches.append(value)
            }
            guard matches.count == 1, let value = matches.first else {
                traceDisplayLookup(matches.isEmpty ? "identityProofRejected" : "ambiguousPhotosIdentity")
                if matches.isEmpty, let snapshot = snapshots.first,
                   rejectsDisplayIdentity(remote, requestedID: id, ownerID: scope.userID, local: snapshot.identity)
                {
                    throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity
                }
                missedDisplayLookups[key] = ContinuousClock.now
                return nil
            }
            guard !rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
            if value.source == .exactCloudIdentity {
                let writePermit = permit
                do {
                    guard try await mutateDisplayAssociation(id, operation: {
                        guard !self.rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
                        return try await self.displayPersistence.merge(value, scope: scope, access: permission, permit: writePermit)
                    }) else {
                        throw LocalPhotoDisplayEvidencePending.displayAssociationPersistenceUnavailable
                    }
                } catch {
                    try validateContext()
                    if error is LocalPhotoDisplayEvidencePending {
                        throw error
                    }
                    traceDisplayLookup("markerPersistenceUnavailable")
                    throw LocalPhotoDisplayEvidencePending.displayAssociationPersistenceUnavailable
                }
                try validateContext()
                guard !rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
                if access == permission, let stronger = associations[value.remoteID] {
                    traceDisplayLookup("markerSupersededByStrongAssociation")
                    return stronger
                }
                if fullLibraryReconciler != nil {
                    cacheDisplayAssociation(value)
                } else if displayAssociations.updateValue(value, forKey: value.remoteID) == nil, associations[value.remoteID] == nil {
                    metadataMatches += 1
                }
                displayAssociationsAccess = permission
                self.revision += 1
            } else {
                try await backupAssociationSaver?([value], scope)
            }
            try validateContext()
            guard !rejectedDisplayAssociationIDs.contains(id) else { throw LocalPhotoDisplayEvidencePending.rejectedDisplayIdentity }
            traceDisplayLookup("resolved")
            if value.source == .exactCloudIdentity {
                traceDisplayLookup("markerUsed")
            }
            if value.source != .exactCloudIdentity {
                access = permission; accept(value)
            }
            return value
        } catch {
            traceDisplayLookup(error is CancellationError ? "cancelled" : "requestOrDecodeFailed")
            try validateContext()
            if error is LocalPhotoDisplayEvidencePending {
                throw error
            }
            if missedDisplayLookups.count >= 512 {
                missedDisplayLookups.removeAll()
            }
            missedDisplayLookups[key] = ContinuousClock.now
            return nil
        }
    }

    /// 同步队列接管匹配；取消旧的独立扫描，已验证关联与账号边界保留。
    func beginBackupMatching(using manager: LibraryManagementController) async {
        configure(using: manager)
        if fullLibraryReconciler != nil {
            _ = startFullLibraryFlow(using: manager, requestPermission: false)
            return
        }
        guard enabled, let scope, inventory.authorization == .full || inventory.authorization == .limited else { return }
        invalidateRun(); followsBackup = true; automaticGeneration = manager.generation
        completedRecoveryGeneration = nil
        access = inventory.authorization; permission = inventory.authorization
        let run = generation, owner = manager.generation, writePermit = permit
        let document = LocalMediaAssociationDocument(scope: scope, enabled: true, access: access, associations: Array(associations.values), followsBackup: true)
        do {
            _ = try await persistence.save(document, scope: scope, permit: writePermit)
            try validate(manager, owner: owner, scope: scope, run: run)
            statusMessage = "使用照片同步的匹配结果，无需单独扫描。"
        } catch {
            guard generation == run else { return }
            statusMessage = "本机浏览设置暂未保存；照片同步队列保留。"
        }
    }

    /// 只接收已与备份任务原子落盘的fresh关联；显示Reader仍逐次验证当前照片版本和权限。
    func acceptBackupMatches(_ values: [LocalMediaAssociation], using manager: LibraryManagementController) {
        guard enabled, followsBackup, self.manager === manager, managerGeneration == manager.generation,
              scope == manager.backupScope, access == inventory.authorization,
              inventory.authorization == .full || inventory.authorization == .limited else { return }
        for value in values {
            accept(value)
        }
        statusMessage = "使用照片同步的匹配结果，无需单独扫描。"
    }
}
