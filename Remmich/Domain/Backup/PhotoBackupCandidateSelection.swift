import Foundation

/// Selects original-backup work only. A deferred display identity is neither an existing backup nor a byte receipt.
nonisolated enum PhotoBackupCandidateSelection {
    /// The caller supplies one account/access-bound atomic evidence batch for at most 64 current native sources.
    /// Malformed or conflicting batches fail closed; missing/stale/incomplete evidence remains an original candidate.
    static func deferredSources(sources: [PhotoBackupSource], evidence: [PhotoBackupDisplayAliasEvidence]) throws -> Set<PhotoBackupSource> {
        try Task.checkCancellation()
        let ids = Set(sources.map(\.localID))
        guard sources.count <= 64, ids.count == sources.count, !ids.contains(""),
              evidence.count <= sources.count,
              Set(evidence.map(\.work.localID)).count == evidence.count,
              evidence.allSatisfy({ ids.contains($0.work.localID) && $0.work.localID == $0.association.localIdentity.localIdentifier })
        else { throw PhotoBackupContinuityError.incompleteResponse }
        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.work.localID, $0) })
        return Set(sources.filter { source in
            guard let hint = byID[source.localID], hint.work.result == .matched, hint.work.reason == .matched,
                  hint.association.source == .exactCloudIdentity,
                  hint.work.cloudID.map(LocalMediaMobileMetadata.isUsableCloudID) == true,
                  !hint.work.identityVersion.isEmpty,
                  let modified = source.modifiedAt, modified.timeIntervalSince1970.isFinite,
                  hint.association.localIdentity.modificationDate == modified else { return false }
            switch source.kind {
            case .photo, .rawJPEG: return hint.association.localIdentity.mediaKind == .image
            case .livePhoto: return hint.association.localIdentity.mediaKind == .livePhoto
            case .video: return hint.association.localIdentity.mediaKind == .video
            }
        })
    }
}
