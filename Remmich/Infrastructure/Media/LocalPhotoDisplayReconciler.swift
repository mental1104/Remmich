import CryptoKit
import Foundation
import Observation
import UIKit

/// The bulk matcher has no media, checksum, upload, or backup operations in its remote contract.
nonisolated protocol LocalPhotoDisplayReconciliationRemote: Sendable {
    func streamPhotoDisplayIdentities(onBatch: @Sendable ([LocalPhotoDisplayIdentityEvent]) async throws -> Void) async throws -> LocalPhotoDisplayStreamReceipt
    func streamPhotoDisplayIdentities(onBatch: @Sendable ([LocalPhotoDisplayIdentityEvent]) async throws -> Void,
                                      onProgress: @Sendable (Int, Int) async throws -> Void) async throws -> LocalPhotoDisplayStreamReceipt
    func localMediaAssets(_ ids: [UUID]) async throws -> [LocalMediaRemoteAsset]
}

extension LocalPhotoDisplayReconciliationRemote {
    func streamPhotoDisplayIdentities(onBatch: @Sendable ([LocalPhotoDisplayIdentityEvent]) async throws -> Void,
                                      onProgress: @Sendable (Int, Int) async throws -> Void) async throws -> LocalPhotoDisplayStreamReceipt
    {
        let receipt = try await streamPhotoDisplayIdentities(onBatch: onBatch)
        try await onProgress(receipt.rawRowCount, receipt.recognizedEventCount)
        return receipt
    }
}

extension LibraryMutationClient: LocalPhotoDisplayReconciliationRemote {}

nonisolated enum LocalPhotoDisplayReconcilerState: String, Sendable {
    case idle, preparingMetadata, matching, waiting, paused, completed, needsReview, blocked
}

@MainActor protocol LocalPhotoReconciliationIdleTiming: AnyObject, Sendable {
    var isIdleTimerDisabled: Bool { get set }
}

@MainActor private final class ApplicationPhotoReconciliationIdleTimer: LocalPhotoReconciliationIdleTiming {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

@MainActor private final class IdleTimerLease {
    private let timer: any LocalPhotoReconciliationIdleTiming
    private var original: Bool?
    init(timer: any LocalPhotoReconciliationIdleTiming) {
        self.timer = timer
    }

    func acquire() {
        guard original == nil else { return }
        original = timer.isIdleTimerDisabled
        timer.isIdleTimerDisabled = true
    }

    func release() {
        guard let original else { return }
        self.original = nil
        timer.isIdleTimerDisabled = original
    }
}

/// One owner, one native Photos batch at a time. Cancellation keeps the owner until it actually retires.
@MainActor @Observable final class LocalPhotoDisplayReconciler {
    nonisolated enum RunMode: Equatable, Sendable { case validateAll, resumePersistedIdentities }
    typealias ReverseCloudIDs = @Sendable (Set<String>) async throws -> [String: String]
    typealias RetryDelay = @Sendable (Int) async throws -> Void

    private(set) var running = false
    private(set) var state = LocalPhotoDisplayReconcilerState.idle
    private var statusMessage: String.LocalizationValue = "Waiting to reconcile Photos identities."
    private var lastErrorMessage: String.LocalizationValue?
    var status: String {
        L10n.text(statusMessage)
    }

    var lastError: String? {
        lastErrorMessage.map { L10n.text($0) }
    }

    @ObservationIgnored var onLinksCommitted: (@MainActor ([LocalMediaAssociation]) -> Void)?
    @ObservationIgnored var onSnapshotAccepted: (@MainActor () async -> Void)?
    private(set) var progress = LocalPhotoDisplayReconciliationProgress(
        phase: .idle, rawMetadataRows: 0, recognizedMetadataEvents: 0, totalLocal: 0,
        processedLocal: 0, matchedLocal: 0, unmatchedLocal: 0, pendingLocal: 0, associationCount: 0
    )

    @ObservationIgnored private let inventory: any LocalPhotoInventoryReading
    @ObservationIgnored private let metadata: any LocalPhotoMetadataReading
    @ObservationIgnored private let reverseCloudIDs: ReverseCloudIDs
    @ObservationIgnored private let store: any LocalPhotoDisplayReconciliationStoring
    @ObservationIgnored private let retryDelay: RetryDelay
    @ObservationIgnored private let diagnosticsURL: URL?
    @ObservationIgnored private let idleTimer: any LocalPhotoReconciliationIdleTiming
    @ObservationIgnored private var idleLease: IdleTimerLease?
    @ObservationIgnored private var todoTotal = 0
    @ObservationIgnored private var checkedThisRun = 0
    @ObservationIgnored private var lastDiagnosticsWrite: TimeInterval = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permit = LocalMediaSavePermit()
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var readerBatchUnstable = 0
    @ObservationIgnored private var itemSnapshotDrift = 0
    @ObservationIgnored private var cloudMappingDrift = 0
    @ObservationIgnored private var missingSnapshot = 0

    init(inventory: any LocalPhotoInventoryReading = PhotoKitDisplayReconciliationInventory(),
         metadata: any LocalPhotoMetadataReading = PhotoKitLocalPhotoMetadataReader(),
         reverseCloudIDs: @escaping ReverseCloudIDs = { try await LocalPhotoCloudResolver.localIDs(for: $0) },
         store: any LocalPhotoDisplayReconciliationStoring = LocalPhotoDisplayReconciliationStore(),
         diagnosticsURL: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("remmich-photo-reconciliation-diagnostics.json"),
         idleTimer: any LocalPhotoReconciliationIdleTiming = ApplicationPhotoReconciliationIdleTimer(),
         retryDelay: @escaping RetryDelay = { attempt in try await Task.sleep(for: .seconds(min(30, 1 << min(max(attempt, 0), 5)))) })
    {
        self.inventory = inventory
        self.metadata = metadata
        self.reverseCloudIDs = reverseCloudIDs
        self.store = store
        self.diagnosticsURL = diagnosticsURL
        self.idleTimer = idleTimer
        self.retryDelay = retryDelay
    }

    /// validateContext must bind account, credential/route generation and enable consent, not the old Photos debounce epoch.
    @discardableResult
    func run(scope: MediaAccountScope, remote: any LocalPhotoDisplayReconciliationRemote,
             mode: RunMode = .validateAll,
             validateContext: @escaping @MainActor @Sendable () throws -> Void) -> Task<Void, Never>?
    {
        guard task == nil else { return nil }
        permit.invalidate()
        permit = LocalMediaSavePermit()
        let writePermit = permit, id = UUID()
        operationID = id; paused = false; running = true; lastErrorMessage = nil
        readerBatchUnstable = 0; itemSnapshotDrift = 0; cloudMappingDrift = 0; missingSnapshot = 0
        todoTotal = 0; checkedThisRun = 0
        let operation = Task { [weak self] in
            guard let self else { return }
            let screenLease = IdleTimerLease(timer: idleTimer)
            idleLease = screenLease
            defer {
                screenLease.release()
                if operationID == id {
                    running = false; task = nil; operationID = nil
                    idleLease = nil
                    writeDiagnostics(force: true)
                }
            }
            await withTaskCancellationHandler {
                do {
                    try check(validateContext)
                    screenLease.acquire()
                    progress = try await store.progress(scope: scope)
                    try check(validateContext)
                    writeDiagnostics(force: true)
                    let previousCheckpoint = try await store.checkpoint(scope: scope)
                    try check(validateContext)
                    let access = inventory.authorization
                    guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
                    let checkBatch: @MainActor @Sendable () throws -> Void = {
                        try self.check(validateContext)
                        guard self.inventory.authorization == access else { throw LocalMediaMetadataError.permission }
                    }
                    state = .preparingMetadata
                    statusMessage = "Counting authorized Photos images and videos."
                    let allIDs = try await inventory.localIdentifiers(validateContext: checkBatch)
                    try checkBatch()
                    guard allIDs.allSatisfy({ !$0.isEmpty }), Set(allIDs).count == allIDs.count else {
                        throw LocalPhotoDisplayReconciliationError.invalidBatch
                    }
                    let ids = allIDs.sorted(), fingerprint = Self.fingerprint(ids)
                    let photosGeneration = UUID()
                    let resumedProcessed = previousCheckpoint.flatMap {
                        $0.inventoryFingerprint == fingerprint && $0.access == access && $0.totalLocal == ids.count ? $0.processedLocal : nil
                    } ?? 0
                    progress = .init(phase: .readingMetadata, rawMetadataRows: progress.rawMetadataRows,
                                     recognizedMetadataEvents: progress.recognizedMetadataEvents, totalLocal: ids.count,
                                     processedLocal: progress.processedLocal, matchedLocal: progress.matchedLocal,
                                     unmatchedLocal: progress.unmatchedLocal, pendingLocal: progress.pendingLocal,
                                     associationCount: progress.associationCount)
                    statusMessage = "Preparing the complete server identity dictionary for \(ids.count) Photos items. No originals or uploads."
                    writeDiagnostics(force: true)
                    let snapshot = try await readSnapshot(scope: scope, remote: remote, permit: writePermit, validate: checkBatch)
                    try checkBatch()
                    await onSnapshotAccepted?()
                    try checkBatch()
                    let sameInventory = previousCheckpoint.map {
                        $0.inventoryFingerprint == fingerprint && $0.totalLocal == ids.count && $0.access == access
                    } ?? false
                    let currentIDs = Set(ids)
                    let verified: Set<String>
                    if mode == .resumePersistedIdentities, previousCheckpoint?.access == access {
                        // A changed inventory does not revoke an already proven logical Photos ID.
                        // Migrate its original matched row in bounded transactions; alias/evidence
                        // validity is checked again by commitBatch before the new inventory owns it.
                        let currentVerified: Set<String>
                        if sameInventory {
                            currentVerified = try await store.verifiedLocalIDs(scope: scope, access: access).intersection(currentIDs)
                            try checkBatch()
                        } else {
                            currentVerified = []
                        }
                        let reusable = try await store.reusableLocalIDs(scope: scope, access: access).intersection(currentIDs)
                        try checkBatch()
                        let rebasing = ids.filter { reusable.contains($0) && !currentVerified.contains($0) }
                        var migrated = 0
                        for start in stride(from: 0, to: rebasing.count, by: 64) {
                            try checkBatch()
                            let batch = Array(rebasing[start ..< min(start + 64, rebasing.count)])
                            let rows = try await store.localWork(localIDs: batch, scope: scope)
                            try checkBatch()
                            guard rows.count == batch.count, Set(rows.map(\.localID)) == Set(batch),
                                  rows.allSatisfy({ $0.result == .matched && $0.reason == .matched })
                            else {
                                throw LocalPhotoDisplayReconciliationError.invalidState
                            }
                            let checkpoint = LocalPhotoDisplayReconciliationCheckpoint(
                                snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion,
                                inventoryFingerprint: fingerprint, access: access, photosGeneration: photosGeneration,
                                totalLocal: ids.count,
                                processedLocal: min(ids.count, max(resumedProcessed, currentVerified.count + migrated + rows.count)),
                                completed: false
                            )
                            guard try await store.commitBatch(rows, links: [], checkpoint: checkpoint,
                                                              scope: scope, permit: writePermit) else { throw CancellationError() }
                            migrated += rows.count
                            try checkBatch()
                            progress = try await store.progress(scope: scope)
                            try checkBatch()
                            writeDiagnostics()
                            await Task.yield()
                        }
                        // Include rows migrated by earlier interrupted runs, regardless of their old
                        // inventory fingerprint. No rebase transaction counts as a native Photos read.
                        verified = try await store.verifiedLocalIDs(scope: scope, access: access).intersection(currentIDs)
                        try checkBatch()
                    } else {
                        verified = []
                    }
                    let todo = ids.filter { !verified.contains($0) }
                    todoTotal = todo.count
                    progress = try await store.progress(scope: scope)
                    try checkBatch()
                    state = .matching
                    statusMessage = "Checking current Photos identities in bounded batches."
                    writeDiagnostics(force: true)
                    for start in stride(from: 0, to: todo.count, by: 64) {
                        try checkBatch()
                        let batch = Array(todo[start ..< min(start + 64, todo.count)])
                        let previousAliases = try await store.aliasLinks(localIDs: batch, scope: scope, access: access)
                        try checkBatch()
                        let result = try await match(batch, snapshot: snapshot, access: access, scope: scope,
                                                     remote: remote, validate: checkBatch)
                        try checkBatch()
                        let checkpoint = LocalPhotoDisplayReconciliationCheckpoint(
                            snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion,
                            inventoryFingerprint: fingerprint, access: access, photosGeneration: photosGeneration,
                            totalLocal: ids.count, processedLocal: min(ids.count, max(resumedProcessed, verified.count + start + batch.count)), completed: start + batch.count == todo.count
                        )
                        guard try await store.commitBatch(result.rows, links: result.links, checkpoint: checkpoint,
                                                          scope: scope, permit: writePermit) else { throw CancellationError() }
                        checkedThisRun += batch.count
                        try checkBatch()
                        progress = try await store.progress(scope: scope)
                        try checkBatch()
                        let affectedRemoteIDs = Array(Set(previousAliases.map(\.remoteID)).union(result.links.map(\.remoteID)))
                        for offset in stride(from: 0, to: affectedRemoteIDs.count, by: 64) {
                            let remoteIDs = Array(affectedRemoteIDs[offset ..< min(offset + 64, affectedRemoteIDs.count)])
                            let selected = try await store.links(remoteIDs: remoteIDs, scope: scope, access: access)
                            try checkBatch()
                            guard selected.count <= 64, Set(selected.map(\.remoteID)).count == selected.count,
                                  Set(selected.map(\.remoteID)).isSubset(of: Set(remoteIDs)) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
                            onLinksCommitted?(selected)
                        }
                        statusMessage = "Processed \(progress.processedLocal) of \(ids.count) items. Unconfirmed items need review, not automatic upload."
                        writeDiagnostics()
                        await Task.yield()
                    }
                    if todo.isEmpty {
                        let checkpoint = LocalPhotoDisplayReconciliationCheckpoint(
                            snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion,
                            inventoryFingerprint: fingerprint, access: access, photosGeneration: photosGeneration,
                            totalLocal: ids.count, processedLocal: ids.count, completed: true
                        )
                        guard try await store.commitBatch([], links: [], checkpoint: checkpoint, scope: scope, permit: writePermit) else { throw CancellationError() }
                        progress = try await store.progress(scope: scope)
                    }
                    try checkBatch()
                    if !ids.isEmpty, progress.matchedLocal == ids.count, progress.pendingLocal == 0, progress.unmatchedLocal == 0 {
                        state = .completed
                        statusMessage = access == .limited ? "All authorized Photos items are matched. Photos outside limited access were not scanned." : "All Photos items in this pass have confirmed display identities."
                    } else {
                        state = .needsReview
                        statusMessage = "This pass finished with items needing review. Unknown identity is not server-only or upload permission."
                    }
                } catch {
                    writePermit.invalidate()
                    if paused || error is CancellationError || Task.isCancelled {
                        state = .paused; statusMessage = "Identity matching is paused. Saved progress is retained."
                    } else if Self.isRetryableRead(error) {
                        state = .waiting; lastErrorMessage = Self.publicFailure(error)
                        statusMessage = "Server reads are temporarily unavailable. Saved progress is retained; resume later."
                    } else {
                        state = .blocked; lastErrorMessage = Self.publicFailure(error)
                        statusMessage = "Identity matching is not ready. Saved progress is retained; no server reset or upload was started."
                    }
                }
            } onCancel: {
                Task { @MainActor in screenLease.release() }
            }
        }
        task = operation
        return operation
    }

    /// Cold restoration reads only durable counters, including when the user has paused matching.
    func restoreSavedProgress(scope: MediaAccountScope) async throws {
        let saved = try await store.progress(scope: scope)
        try Task.checkCancellation()
        progress = saved
        writeDiagnostics(force: true)
    }

    func pause() {
        paused = true
        permit.invalidate()
        task?.cancel()
        idleLease?.release()
        state = .paused
        statusMessage = "Pausing identity matching while the current system metadata request retires. Saved progress is retained."
        writeDiagnostics(force: true)
    }

    /// Waits only for the current owner; a caller must validate its new lease before starting again.
    func waitForRetirement() async {
        let pending = task
        await pending?.value
    }

    private func check(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        guard !paused else { throw CancellationError() }
        try validate()
    }

    private func readSnapshot(scope: MediaAccountScope, remote: any LocalPhotoDisplayReconciliationRemote,
                              permit: LocalMediaSavePermit, validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> LocalPhotoDisplayMetadataSnapshot
    {
        try await readWithRetry(validate: validate) { [store] in
            let snapshotID = try await store.beginMetadataReplay(scope: scope, permit: permit)
            let receipt = try await remote.streamPhotoDisplayIdentities(onBatch: { events in
                guard events.count <= 64 else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
                guard try await store.stageMetadata(events, snapshotID: snapshotID, scope: scope, permit: permit) else { throw CancellationError() }
            }, onProgress: { [weak self] raw, recognized in
                guard try await store.recordMetadataProgress(rawRowCount: raw, recognizedEventCount: recognized,
                                                             snapshotID: snapshotID, scope: scope, permit: permit) else { throw CancellationError() }
                if let self {
                    await recordStreamProgress(raw: raw, recognized: recognized)
                }
            })
            try validate()
            return try await store.completeMetadataSnapshot(snapshotID: snapshotID, receipt: receipt, scope: scope, permit: permit)
        }
    }

    private func recordStreamProgress(raw: Int, recognized: Int) {
        progress = .init(phase: .readingMetadata, rawMetadataRows: raw, recognizedMetadataEvents: recognized,
                         totalLocal: progress.totalLocal, processedLocal: progress.processedLocal,
                         matchedLocal: progress.matchedLocal, unmatchedLocal: progress.unmatchedLocal,
                         pendingLocal: progress.pendingLocal, associationCount: progress.associationCount)
        writeDiagnostics()
    }

    /// Small anonymous DEBUG evidence only; injected paths keep synthetic tests out of app Documents.
    private func writeDiagnostics(force: Bool = false) {
        #if DEBUG
            guard let diagnosticsURL else { return }
            let now = Date().timeIntervalSince1970
            guard force || now - lastDiagnosticsWrite >= 1 else { return }
            var value: [String: Any] = [
                "version": 1, "recordedAt": now, "phase": progress.phase.rawValue, "state": state.rawValue,
                "running": running, "total": progress.totalLocal, "processed": progress.processedLocal,
                "matched": progress.matchedLocal, "unmatched": progress.unmatchedLocal, "pending": progress.pendingLocal,
                "rawMetadataRows": progress.rawMetadataRows, "associationCount": progress.associationCount,
                "todoTotal": todoTotal, "checkedThisRun": checkedThisRun,
                "sourceChangeEvents": ["readerBatchUnstable": readerBatchUnstable,
                                       "itemSnapshotDrift": itemSnapshotDrift, "cloudMappingDrift": cloudMappingDrift,
                                       "missingSnapshot": missingSnapshot],
            ]
            if let lastError {
                value["lastError"] = lastError
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                try data.write(to: diagnosticsURL, options: [.atomic])
                lastDiagnosticsWrite = now
            } catch {
                // Diagnostics never change matching, retry, account or source decisions.
            }
        #endif
    }

    private nonisolated struct Batch: Sendable {
        let rows: [LocalPhotoDisplayLocalWork]
        let links: [LocalMediaAssociation]
    }

    private final class SnapshotReadBudget {
        var remaining = 512
    }

    private nonisolated enum SnapshotReadFailure: Error { case budgetExhausted }

    private func match(_ ids: [String], snapshot: LocalPhotoDisplayMetadataSnapshot, access: LocalPhotoLibraryAccess,
                       scope: MediaAccountScope, remote: any LocalPhotoDisplayReconciliationRemote,
                       validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> Batch
    {
        try await recoverSourceChanges(ids, snapshot: snapshot, access: access, scope: scope, remote: remote,
                                       budget: SnapshotReadBudget(), itemRetries: 2, validate: validate)
    }

    /// Failed reader batches never supply snapshots. Retry once, then isolate changes without discarding stable siblings.
    private func recoverSourceChanges(_ ids: [String], snapshot: LocalPhotoDisplayMetadataSnapshot, access: LocalPhotoLibraryAccess,
                                      scope: MediaAccountScope, remote: any LocalPhotoDisplayReconciliationRemote,
                                      budget: SnapshotReadBudget, itemRetries: Int,
                                      validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> Batch
    {
        func pending(_ reason: LocalPhotoDisplayLocalWork.Reason) -> Batch {
            Batch(rows: ids.map { Self.work($0, snapshot: nil, evidence: snapshot.evidenceVersion, reason: reason) }, links: [])
        }
        var observed: Batch?
        for attempt in 0 ..< 2 {
            try validate()
            do {
                observed = try await matchOnce(ids, snapshot: snapshot, access: access, scope: scope, remote: remote,
                                               budget: budget, validate: validate)
                break
            } catch LocalMediaMetadataError.sourceChanged {
                readerBatchUnstable += 1
                try validate()
                if attempt == 0 {
                    await Task.yield(); try validate()
                }
            } catch SnapshotReadFailure.budgetExhausted {
                return pending(.failed)
            }
        }
        if let observed {
            let changed = observed.rows.filter { $0.reason == .sourceChanged }.map(\.localID)
            guard !changed.isEmpty, itemRetries > 0 else { return observed }
            var rows = Dictionary(uniqueKeysWithValues: observed.rows.map { ($0.localID, $0) })
            var links = Dictionary(uniqueKeysWithValues: observed.links.map { ($0.localIdentity.localIdentifier, $0) })
            for id in changed {
                await Task.yield(); try validate()
                let retried = try await recoverSourceChanges([id], snapshot: snapshot, access: access, scope: scope, remote: remote,
                                                             budget: budget, itemRetries: itemRetries - 1, validate: validate)
                for value in retried.rows {
                    rows[value.localID] = value
                }
                links.removeValue(forKey: id)
                for value in retried.links {
                    links[value.localIdentity.localIdentifier] = value
                }
            }
            return Batch(rows: ids.compactMap { rows[$0] }, links: Array(links.values))
        }
        guard ids.count > 1 else { return pending(.sourceChanged) }
        let middle = ids.count / 2
        let left = try await recoverSourceChanges(Array(ids[..<middle]), snapshot: snapshot, access: access, scope: scope, remote: remote,
                                                  budget: budget, itemRetries: itemRetries, validate: validate)
        let right = try await recoverSourceChanges(Array(ids[middle...]), snapshot: snapshot, access: access, scope: scope, remote: remote,
                                                   budget: budget, itemRetries: itemRetries, validate: validate)
        return Batch(rows: left.rows + right.rows, links: left.links + right.links)
    }

    private func checkedSnapshots(_ ids: [String], budget: SnapshotReadBudget,
                                  validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> [LocalPhotoSnapshot]
    {
        try validate()
        guard budget.remaining > 0 else { throw SnapshotReadFailure.budgetExhausted }
        budget.remaining -= 1
        let values = try await metadata.snapshots(for: ids, validateContext: validate)
        try validate()
        try Self.validateSnapshots(values, requested: ids)
        return values
    }

    private func matchOnce(_ ids: [String], snapshot: LocalPhotoDisplayMetadataSnapshot, access: LocalPhotoLibraryAccess,
                           scope: MediaAccountScope, remote: any LocalPhotoDisplayReconciliationRemote, budget: SnapshotReadBudget,
                           validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> Batch
    {
        let before = try await checkedSnapshots(ids, budget: budget, validate: validate)
        let byID = Dictionary(uniqueKeysWithValues: before.map { ($0.identity.localIdentifier, $0) })
        let clouds = Set(before.compactMap(Self.cloudID))
        let reverse = clouds.isEmpty ? [:] : try await reverseCloudIDs(clouds)
        try validate()
        guard Set(reverse.keys).isSubset(of: clouds), reverse.values.allSatisfy({ !$0.isEmpty }) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        let metadataRows: [LocalPhotoDisplayMetadataRow]
        do { metadataRows = clouds.isEmpty ? [] : try await store.metadataRows(cloudIDs: clouds, scope: scope) }
        catch LocalPhotoDisplayReconciliationError.limitExceeded {
            return Batch(rows: ids.map { Self.work($0, snapshot: byID[$0], evidence: snapshot.evidenceVersion, reason: .failed) }, links: [])
        }
        guard metadataRows.reduce(0, { $0 + $1.value.count }) <= 8_388_608 else {
            return Batch(rows: ids.map { Self.work($0, snapshot: byID[$0], evidence: snapshot.evidenceVersion, reason: .failed) }, links: [])
        }
        let evidence = Self.evidence(metadataRows)
        var evidenceHashes: [String: String] = [:]
        for cloud in clouds {
            let candidates = Set(evidence.filter { $0.value.cloudIDs.contains(cloud) }.keys)
            evidenceHashes[cloud] = Self.evidenceHash(metadataRows.filter { candidates.contains($0.assetID) })
        }
        let emptyEvidence = Self.evidenceHash([])
        func row(_ id: String, _ value: LocalPhotoSnapshot?, _ reason: LocalPhotoDisplayLocalWork.Reason) -> LocalPhotoDisplayLocalWork {
            let hash = value.flatMap(Self.cloudID).flatMap { evidenceHashes[$0] } ?? emptyEvidence
            return Self.work(id, snapshot: value, evidence: hash, reason: reason)
        }
        let oldRows = try await store.localWork(localIDs: ids, scope: scope)
        let old = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.localID, $0) })
        let candidateIDs = evidence.keys.sorted { $0.uuidString < $1.uuidString }
        let savedAliases = try await store.aliasLinks(localIDs: ids, scope: scope, access: access)
        try validate()
        let savedLocalIDs = savedAliases.map(\.localIdentity.localIdentifier)
        guard savedAliases.count <= 64, Set(savedLocalIDs).count == savedLocalIDs.count,
              Set(savedLocalIDs).isSubset(of: Set(ids)) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        let existingLinks = Dictionary(uniqueKeysWithValues: savedAliases.map { ($0.localIdentity.localIdentifier, $0) })
        var skipped = Set<String>()
        for value in before {
            let id = value.identity.localIdentifier
            guard let previous = old[id], previous.result == .matched,
                  let cloud = Self.cloudID(value), let currentEvidence = evidenceHashes[cloud],
                  previous.identityVersion == Self.identityVersion(value), previous.evidenceHash == currentEvidence,
                  let link = existingLinks[id], link.source == .exactCloudIdentity, link.localIdentity == value.identity,
                  reverse[cloud] == id,
                  evidence[link.remoteID]?.accepts(cloud, checksum: link.checksum) == true else { continue }
            skipped.insert(id)
        }
        let neededClouds = Set(before.filter { !skipped.contains($0.identity.localIdentifier) }.compactMap(Self.cloudID))
        let neededIDs = candidateIDs.filter { evidence[$0]?.cloudIDs.isDisjoint(with: neededClouds) == false }
        var remoteByID: [UUID: LocalMediaRemoteAsset] = [:]
        for start in stride(from: 0, to: neededIDs.count, by: 64) {
            let part = Array(neededIDs[start ..< min(start + 64, neededIDs.count)])
            let assets = try await readWithRetry(validate: validate) { try await remote.localMediaAssets(part) }
            try validate()
            guard Set(assets.map(\.id)).count == assets.count, Set(assets.map(\.id)).isSubset(of: Set(part)) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
            for asset in assets {
                remoteByID[asset.id] = asset
            }
        }
        let after = try await checkedSnapshots(ids, budget: budget, validate: validate)
        let current = Dictionary(uniqueKeysWithValues: after.map { ($0.identity.localIdentifier, $0) })
        var results: [LocalPhotoDisplayLocalWork] = [], links: [String: LocalMediaAssociation] = [:]
        for id in ids {
            guard let local = byID[id], let now = current[id], now == local else {
                if byID[id] == nil || current[id] == nil {
                    missingSnapshot += 1
                } else if let local = byID[id], let now = current[id], local.cloudIdentity != now.cloudIdentity {
                    cloudMappingDrift += 1
                } else {
                    itemSnapshotDrift += 1
                }
                results.append(row(id, current[id], .sourceChanged)); continue
            }
            guard let cloud = Self.cloudID(now) else {
                results.append(row(id, now, .noCloudIdentity)); continue
            }
            guard reverse[cloud] == id else {
                results.append(row(id, now, .unavailableInPhotos)); continue
            }
            if skipped.contains(id), let previous = old[id] {
                results.append(previous); continue
            }
            let candidates = evidence.filter { $0.value.cloudIDs.contains(cloud) }
            guard !candidates.isEmpty else {
                results.append(row(id, now, .noServerIdentity)); continue
            }
            guard candidates.allSatisfy({ candidate in
                guard let fresh = remoteByID[candidate.key] else { return true }
                return candidate.value.accepts(cloud, checksum: fresh.checksum)
            }) else {
                results.append(row(id, now, .conflictingMetadata)); continue
            }
            let verified = candidates.keys.compactMap { remoteID -> LocalMediaAssociation? in
                guard let fresh = remoteByID[remoteID] else { return nil }
                return LocalMediaAssociation.verified(remote: fresh, requestedID: remoteID, ownerID: scope.userID,
                                                      local: now.identity, source: .exactCloudIdentity, prefersCurrentPhotos: true)
            }
            guard verified.count == 1, let link = verified.first else {
                results.append(row(id, now, verified.isEmpty ? .remoteRejected : .ambiguousCandidates)); continue
            }
            links[id] = link
            results.append(row(id, now, .matched))
        }
        return Batch(rows: results, links: Array(links.values))
    }

    private nonisolated struct Evidence: Sendable {
        var official: LocalMediaMobileMetadata?
        var marker: LocalMediaDisplayCloudIdentity?
        var origins: [String: PhotoBackupOrigin] = [:]
        var hintedCloudIDs = Set<String>()
        var invalidOfficial = false
        var invalidMarker = false
        var rejectedOriginCloudIDs = Set<String>()
        var rejectedOriginKeys = Set<String>()
        var unattributedOriginFailure = false
        var cloudIDs: Set<String> {
            var values = hintedCloudIDs.union(origins.keys)
            if let official {
                values.insert(official.cloudId)
            }
            if let marker {
                values.insert(marker.cloudID)
            }
            return values
        }

        func accepts(_ cloud: String, checksum: String?) -> Bool {
            guard !invalidOfficial, !unattributedOriginFailure,
                  !rejectedOriginCloudIDs.contains(cloud),
                  !rejectedOriginKeys.contains(PhotoBackupOrigin.metadataKey(for: cloud)) else { return false }
            // A per-cloud origin is an independent alias only while it still names this exact server digest.
            if let origin = origins[cloud], origin.checksum != checksum {
                return false
            }
            let verifiedOrigins = Set(origins.compactMap { $0.value.checksum == checksum ? $0.key : nil })
            if let marker, marker.cloudID != official?.cloudId {
                var fullClouds = verifiedOrigins
                if let official {
                    fullClouds.insert(official.cloudId)
                }
                if fullClouds.contains(where: { $0 != marker.cloudID }), !verifiedOrigins.contains(marker.cloudID) {
                    // A light marker cannot explain a disagreement with another full identity by itself.
                    return false
                }
            }
            return official?.cloudId == cloud || (!invalidMarker && marker?.cloudID == cloud) || verifiedOrigins.contains(cloud)
        }
    }

    private nonisolated static func evidence(_ rows: [LocalPhotoDisplayMetadataRow]) -> [UUID: Evidence] {
        let decoder = JSONDecoder()
        var result: [UUID: Evidence] = [:]
        for row in rows {
            var value = result[row.assetID] ?? Evidence()
            let originKey = row.key.hasPrefix(PhotoBackupOrigin.keyPrefix)
            let hint = cloudHint(row.value, origin: originKey)
            if let hint {
                value.hintedCloudIDs.insert(hint)
            }
            do {
                if row.key == LocalMediaDisplayCloudIdentity.metadataKey {
                    value.marker = try decoder.decode(LocalMediaDisplayCloudIdentity.self, from: row.value)
                } else if row.key == "mobile-app" {
                    value.official = try decoder.decode(LocalMediaMobileMetadata.self, from: row.value)
                } else if originKey {
                    let origin = try decoder.decode(PhotoBackupOrigin.self, from: row.value)
                    try origin.validate()
                    guard row.key == PhotoBackupOrigin.metadataKey(for: origin.metadata.cloudId) else { throw LocalMediaMetadataError.invalidMetadata }
                    value.origins[origin.metadata.cloudId] = origin
                } else {
                    continue
                }
            } catch {
                if row.key == LocalMediaDisplayCloudIdentity.metadataKey {
                    value.invalidMarker = true
                } else if originKey {
                    value.rejectedOriginKeys.insert(row.key)
                    if let hint {
                        value.rejectedOriginCloudIDs.insert(hint)
                    } else {
                        value.unattributedOriginFailure = true
                    }
                } else {
                    value.invalidOfficial = true
                }
            }
            result[row.assetID] = value
        }
        return result
    }

    private nonisolated static func cloudHint(_ data: Data, origin: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (origin ? object["metadata"] as? [String: Any] : object)?["iCloudId"] as? String,
              LocalMediaMobileMetadata.isUsableCloudID(value), value.utf8.count <= 4096 else { return nil }
        return value
    }

    private func readWithRetry<T: Sendable>(validate: @escaping @MainActor @Sendable () throws -> Void,
                                            operation: @escaping @MainActor () async throws -> T) async throws -> T
    {
        let resumeState = state, resumeMessage = statusMessage
        var attempt = 0, retried = false
        while true {
            try validate()
            do {
                let value = try await operation()
                try validate()
                if retried {
                    state = resumeState; statusMessage = resumeMessage; lastErrorMessage = nil
                    writeDiagnostics()
                }
                return value
            } catch {
                try validate()
                guard Self.isRetryableRead(error) else { throw error }
                retried = true
                state = .waiting; lastErrorMessage = Self.publicFailure(error)
                statusMessage = "Server reads are temporarily unavailable. Retrying with a bounded delay; saved counts are retained."
                writeDiagnostics()
                try await retryDelay(attempt)
                try validate()
                attempt = min(attempt + 1, 5)
            }
        }
    }

    private nonisolated static func cloudID(_ snapshot: LocalPhotoSnapshot) -> String? {
        guard case let .resolved(value) = snapshot.cloudIdentity,
              LocalMediaMobileMetadata.isUsableCloudID(value), value.utf8.count <= 4096 else { return nil }
        return value
    }

    private nonisolated static func validateSnapshots(_ values: [LocalPhotoSnapshot], requested: [String]) throws {
        let ids = values.map(\.identity.localIdentifier)
        guard values.count <= 64, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(requested)) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
    }

    private nonisolated static func work(_ id: String, snapshot: LocalPhotoSnapshot?, evidence: String,
                                         reason: LocalPhotoDisplayLocalWork.Reason) -> LocalPhotoDisplayLocalWork
    {
        .init(localID: id, cloudID: snapshot.flatMap(cloudID), identityVersion: snapshot.map(identityVersion) ?? "unavailable",
              evidenceHash: evidence, result: reason == .matched ? .matched : reason == .noServerIdentity ? .unmatched : .pending,
              reason: reason)
    }

    private nonisolated static func identityVersion(_ snapshot: LocalPhotoSnapshot) -> String {
        let value: [String: Any] = ["localID": snapshot.identity.localIdentifier,
                                    "modified": snapshot.identity.modificationDate?.timeIntervalSinceReferenceDate.bitPattern.description ?? "unknown",
                                    "kind": String(describing: snapshot.identity.mediaKind), "cloudID": cloudID(snapshot) ?? "unknown",
                                    "adjustment": snapshot.adjustmentTime?.timeIntervalSinceReferenceDate.bitPattern.description ?? "none",
                                    "adjusted": snapshot.hasAdjustments, "width": snapshot.pixelWidth, "height": snapshot.pixelHeight,
                                    "duration": snapshot.duration.bitPattern.description, "subtypes": snapshot.mediaSubtypes]
        return SHA256.hash(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func fingerprint(_ ids: [String]) -> String {
        var digest = SHA256()
        for id in ids {
            digest.update(data: Data("\(id.utf8.count):\(id)".utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func evidenceHash(_ rows: [LocalPhotoDisplayMetadataRow]) -> String {
        var digest = SHA256()
        let records = rows.map { row -> (String, String, Data) in
            let value = (try? JSONSerialization.jsonObject(with: row.value)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? row.value
            return (row.assetID.uuidString.lowercased(), row.key, value)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 {
                return lhs.0 < rhs.0
            }
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            return lhs.2.lexicographicallyPrecedes(rhs.2)
        }
        for (id, key, value) in records {
            digest.update(data: Data("\(id.utf8.count):\(id)\(key.utf8.count):\(key)\(value.count):".utf8))
            digest.update(data: value)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func isRetryableRead(_ error: Error) -> Bool {
        if case let LibraryWriteError.http(code) = error {
            return (500 ... 599).contains(code)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    private nonisolated static func publicFailure(_ error: Error) -> String.LocalizationValue {
        if case let LibraryWriteError.http(code) = error {
            return "Server read failed (HTTP \(code))."
        }
        if case LocalPhotoDisplayIdentityStreamError.metadataCheckpointExists = error {
            return "This server metadata session already has a checkpoint. A complete identity dictionary is unavailable; no reset was performed."
        }
        if case LocalPhotoDisplayIdentityStreamError.resetRequired = error {
            return "The server requested a sync reset. Matching stopped without resetting server progress."
        }
        if case LocalPhotoDisplayIdentityStreamError.incomplete = error {
            return "The metadata stream did not complete. Previously accepted identities and saved progress are retained."
        }
        if error is LocalPhotoDisplayIdentityStreamError {
            return "The complete server identity dictionary protocol was not satisfied. No checkpoints were reset or acknowledged."
        }
        if error is LocalPhotoDisplayReconciliationError {
            return "The identity index is not ready or batch validation failed."
        }
        if case LocalMediaMetadataError.permission = error {
            return "Photos permission is not ready or has changed."
        }
        if error is URLError {
            return "The server connection is temporarily unavailable."
        }
        return "Metadata verification is incomplete. Unconfirmed items are retained for review."
    }
}
