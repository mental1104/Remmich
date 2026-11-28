import Foundation

/// Durable display-only reconciliation state. None of these records is a backup receipt.
nonisolated enum LocalPhotoDisplayReconciliationError: Error, Equatable, Sendable {
    case invalidBatch, invalidState, invalidScope, incompleteSnapshot, limitExceeded, invalidDatabase
}

nonisolated struct LocalPhotoDisplayMetadataRow: Equatable, Sendable {
    let assetID: UUID
    let key: String
    let value: Data
}

nonisolated struct LocalPhotoDisplayMetadataSnapshot: Equatable, Sendable {
    let id: UUID
    /// Hash of the complete, sorted current metadata dictionary, independent of stream order.
    let evidenceVersion: String
    let receipt: LocalPhotoDisplayStreamReceipt
}

nonisolated struct LocalPhotoDisplayLocalWork: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable { case matched, unmatched, pending }
    enum Reason: String, Codable, Sendable {
        case matched, noCloudIdentity, noServerIdentity, conflictingMetadata, ambiguousCandidates
        case unavailableInPhotos, remoteRejected, unverified, failed, permissionNotReady, sourceChanged
    }

    let localID: String
    let cloudID: String?
    let identityVersion: String
    let evidenceHash: String
    let result: Result
    let reason: Reason
}

nonisolated struct LocalPhotoDisplayReconciliationCheckpoint: Codable, Equatable, Sendable {
    let snapshotID: UUID
    let evidenceVersion: String
    let inventoryFingerprint: String
    let access: LocalPhotoLibraryAccess
    let photosGeneration: UUID
    let totalLocal: Int
    let processedLocal: Int
    /// Inventory pass finished; pending/unmatched rows still require review.
    let completed: Bool
}

nonisolated struct LocalPhotoDisplayReconciliationProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case idle, readingMetadata, matching, completed, needsReview }
    let phase: Phase
    let rawMetadataRows: Int
    let recognizedMetadataEvents: Int
    let totalLocal: Int
    let processedLocal: Int
    let matchedLocal: Int
    let unmatchedLocal: Int
    let pendingLocal: Int
    let associationCount: Int
}

/// A fresh, complete metadata read declared no portable Photos identity keys for this Immich asset.
/// This is not a claim that the photo is absent from Photos/iCloud. The database namespace binds the account.
nonisolated struct LocalPhotoDisplaySourceFact: Codable, Equatable, Sendable {
    let assetID: UUID
    let displayRevision: Date
    let observedAt: Date
    let access: LocalPhotoLibraryAccess
}

/// The namespace SQLite is separate from backup journals and photo_sync_associations.
/// Every mutating batch is bounded to 64 input items and commits only under its live permit.
nonisolated protocol LocalPhotoDisplayReconciliationStoring: Sendable {
    func beginMetadataReplay(scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> UUID
    func stageMetadata(_ events: [LocalPhotoDisplayIdentityEvent], snapshotID: UUID, scope: MediaAccountScope,
                       permit: LocalMediaSavePermit) async throws -> Bool
    func recordMetadataProgress(rawRowCount: Int, recognizedEventCount: Int, snapshotID: UUID,
                                scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
    func completeMetadataSnapshot(snapshotID: UUID, receipt: LocalPhotoDisplayStreamReceipt,
                                  scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> LocalPhotoDisplayMetadataSnapshot
    func metadataSnapshot(scope: MediaAccountScope) async throws -> LocalPhotoDisplayMetadataSnapshot?
    /// Returns every recognized key for every asset having a requested cloud ID, including conflicting keys.
    func metadataRows(cloudIDs: Set<String>, scope: MediaAccountScope) async throws -> [LocalPhotoDisplayMetadataRow]
    func metadataRows(assetIDs: [UUID], scope: MediaAccountScope) async throws -> [LocalPhotoDisplayMetadataRow]
    func localWork(localIDs: [String], scope: MediaAccountScope) async throws -> [LocalPhotoDisplayLocalWork]
    func checkpoint(scope: MediaAccountScope) async throws -> LocalPhotoDisplayReconciliationCheckpoint?
    func commitBatch(_ rows: [LocalPhotoDisplayLocalWork], links: [LocalMediaAssociation],
                     checkpoint: LocalPhotoDisplayReconciliationCheckpoint, scope: MediaAccountScope,
                     permit: LocalMediaSavePermit) async throws -> Bool
    func lookupSourceFacts(assetIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalPhotoDisplaySourceFact]
    func saveSourceFact(_ fact: LocalPhotoDisplaySourceFact, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
    func removeSourceFacts(ids: [UUID], scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
    func progress(scope: MediaAccountScope) async throws -> LocalPhotoDisplayReconciliationProgress
    /// One verified relation per local Photos item; distinct local aliases may share a remote asset.
    /// IDs only: matched work in the current checkpoint inventory with valid account/access-bound alias proof.
    /// Candidates only: rebase their persisted work/counters before using verifiedLocalIDs to skip a current pass.
    func reusableLocalIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<String>
    func verifiedLocalIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<String>
    func aliasLinks(localIDs: [String], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func links(remoteIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func linksPage(after remoteID: UUID?, limit: Int, scope: MediaAccountScope,
                   access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    /// Identity keys only; never decodes the full media mapping payloads.
    func knownRemoteIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<UUID>
    func distinctLocalCount(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Int
}
