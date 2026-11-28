import Foundation

/// Display-only compatibility boundary; production bounded reads use the same namespace SQLite actor.
nonisolated protocol LocalPhotoDisplayAssociationPersisting: Sendable {
    func load(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func merge(_ value: LocalMediaAssociation, scope: MediaAccountScope, access: LocalPhotoLibraryAccess, permit: LocalMediaSavePermit) async throws -> Bool
    func remove(_ id: UUID, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
    func lookup(remoteIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func loadPage(after remoteID: UUID?, limit: Int, scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func knownRemoteIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<UUID>
    func lookupSourceFacts(assetIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalPhotoDisplaySourceFact]
    func saveSourceFact(_ fact: LocalPhotoDisplaySourceFact, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
    func removeSourceFacts(ids: [UUID], scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
}

/// Existing small in-memory fixtures can retain the legacy protocol implementation.
extension LocalPhotoDisplayAssociationPersisting {
    /// A legacy/mock store never grants an unpersisted negative-source capability.
    func lookupSourceFacts(assetIDs: [UUID], scope _: MediaAccountScope, access _: LocalPhotoLibraryAccess) async throws -> [LocalPhotoDisplaySourceFact] {
        guard assetIDs.count <= 64, Set(assetIDs).count == assetIDs.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        return []
    }

    func saveSourceFact(_: LocalPhotoDisplaySourceFact, scope _: MediaAccountScope, permit _: LocalMediaSavePermit) async throws -> Bool {
        false
    }

    func removeSourceFacts(ids: [UUID], scope _: MediaAccountScope, permit _: LocalMediaSavePermit) async throws -> Bool {
        guard ids.count <= 64, Set(ids).count == ids.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        return true
    }

    func lookup(remoteIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation] {
        guard remoteIDs.count <= 64, Set(remoteIDs).count == remoteIDs.count else { throw LocalMediaMetadataError.invalidBatch }
        let ids = Set(remoteIDs)
        return try await load(scope: scope, access: access).filter { ids.contains($0.remoteID) }
    }

    func loadPage(after remoteID: UUID?, limit: Int, scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation] {
        guard limit > 0, limit <= 64 else { throw LocalMediaMetadataError.invalidBatch }
        return try await Array(load(scope: scope, access: access).filter { $0.remoteID.uuidString > (remoteID?.uuidString ?? "") }.sorted { $0.remoteID.uuidString < $1.remoteID.uuidString }.prefix(limit))
    }

    func knownRemoteIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<UUID> {
        try await Set(load(scope: scope, access: access).map(\.remoteID))
    }
}

/// The old JSON is imported once, in idempotent batches, and retained unchanged for recovery.
actor LocalPhotoDisplayAssociationStore: LocalPhotoDisplayAssociationPersisting {
    nonisolated let reconciliationStore: LocalPhotoDisplayReconciliationStore

    init(directory: URL? = nil) {
        reconciliationStore = .init(directory: directory)
    }

    init(reconciliationStore: LocalPhotoDisplayReconciliationStore) {
        self.reconciliationStore = reconciliationStore
    }

    func lookupSourceFacts(assetIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalPhotoDisplaySourceFact] {
        try await reconciliationStore.lookupSourceFacts(assetIDs: assetIDs, scope: scope, access: access)
    }

    func saveSourceFact(_ fact: LocalPhotoDisplaySourceFact, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool {
        try await reconciliationStore.saveSourceFact(fact, scope: scope, permit: permit)
    }

    func removeSourceFacts(ids: [UUID], scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool {
        try await reconciliationStore.removeSourceFacts(ids: ids, scope: scope, permit: permit)
    }

    /// Compatibility only. Timeline callers use lookup/loadPage and never decode the full library.
    func load(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation] {
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        var values: [LocalMediaAssociation] = [], after: UUID?
        while true {
            try Task.checkCancellation()
            let batch = try await reconciliationStore.linksPage(after: after, limit: 64, scope: scope, access: access)
            values.append(contentsOf: batch)
            guard let last = batch.last, batch.count == 64 else { return values }
            after = last.remoteID
        }
    }

    func merge(_ value: LocalMediaAssociation, scope: MediaAccountScope, access: LocalPhotoLibraryAccess, permit: LocalMediaSavePermit) async throws -> Bool {
        try await reconciliationStore.mergeLink(value, scope: scope, access: access, permit: permit)
    }

    func remove(_ id: UUID, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool {
        try await reconciliationStore.removeLink(id, scope: scope, permit: permit)
    }

    func lookup(remoteIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation] {
        try await reconciliationStore.links(remoteIDs: remoteIDs, scope: scope, access: access)
    }

    func loadPage(after remoteID: UUID?, limit: Int, scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation] {
        try await reconciliationStore.linksPage(after: remoteID, limit: limit, scope: scope, access: access)
    }

    func knownRemoteIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> Set<UUID> {
        try await reconciliationStore.knownRemoteIDs(scope: scope, access: access)
    }
}
