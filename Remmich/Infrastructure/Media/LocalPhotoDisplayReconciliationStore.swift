import CryptoKit
import Foundation
import SQLite3

/// Separate account database: display identities and reconciliation never touch backup state.
actor LocalPhotoDisplayReconciliationStore: LocalPhotoDisplayReconciliationStoring {
    private let directory: URL
    private var databases: [String: DisplayReconciliationDatabase] = [:]
    private let maximumQueryRows = 4096

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("LocalPhotoDisplayAssociations", isDirectory: true)
    }

    func beginMetadataReplay(scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> UUID {
        try Task.checkCancellation()
        let db = try database(scope, permit: permit), id = UUID()
        guard try permit.writeIfCurrent({
            try db.transaction {
                try db.execute("DELETE FROM snapshots WHERE completed=0")
                try db.execute("INSERT INTO snapshots(id,completed,event_count) VALUES(?,0,0)", [.text(id.uuidString)])
                try db.set("replay", id.uuidString)
            }
        }) else { throw CancellationError() }
        return id
    }

    func stageMetadata(_ events: [LocalPhotoDisplayIdentityEvent], snapshotID: UUID, scope: MediaAccountScope,
                       permit: LocalMediaSavePermit) throws -> Bool
    {
        try Task.checkCancellation()
        guard !events.isEmpty, events.count <= 64 else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        let prepared = try events.map(Self.prepareEvent)
        let db = try database(scope, permit: permit)
        return try permit.writeIfCurrent {
            try db.transaction {
                try self.requireReplay(snapshotID, db)
                for event in prepared {
                    try Task.checkCancellation()
                    let old = try db.text("SELECT digest FROM events WHERE snapshot_id=? AND ack=?", [.text(snapshotID.uuidString), .text(event.ack)])
                    if let old {
                        guard old == event.digest else { throw LocalPhotoDisplayReconciliationError.invalidState }
                        continue
                    }
                    try db.execute("INSERT INTO events(snapshot_id,ack,digest) VALUES(?,?,?)", [.text(snapshotID.uuidString), .text(event.ack), .text(event.digest)])
                    if let value = event.value {
                        try db.execute("INSERT INTO metadata_rows(snapshot_id,asset_id,key,value,cloud_id) VALUES(?,?,?,?,?) ON CONFLICT(snapshot_id,asset_id,key) DO UPDATE SET value=excluded.value,cloud_id=excluded.cloud_id",
                                       [.text(snapshotID.uuidString), .text(event.assetID.uuidString), .text(event.key), .blob(value), event.cloudID.map(DisplayDBValue.text) ?? .null])
                    } else {
                        try db.execute("DELETE FROM metadata_rows WHERE snapshot_id=? AND asset_id=? AND key=?", [.text(snapshotID.uuidString), .text(event.assetID.uuidString), .text(event.key)])
                    }
                    try db.execute("UPDATE snapshots SET event_count=event_count+1,last_ack=? WHERE id=?", [.text(event.ack), .text(snapshotID.uuidString)])
                }
                for id in Set(prepared.map(\.assetID)) {
                    try self.updateAssetEvidence(id, snapshotID, db)
                }
                // One asset can carry mobile-app, display marker, and multiple backup-origin keys.
                // 80k assets may exceed 200k events; the stream also retains its independent 512 MiB bound.
                guard try db.integer("SELECT event_count FROM snapshots WHERE id=?", [.text(snapshotID.uuidString)]) <= 1_000_000 else { throw LocalPhotoDisplayReconciliationError.limitExceeded }
                try Task.checkCancellation()
            }
        }
    }

    func recordMetadataProgress(rawRowCount: Int, recognizedEventCount: Int, snapshotID: UUID,
                                scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> Bool
    {
        guard rawRowCount >= 0, recognizedEventCount >= 0, recognizedEventCount <= rawRowCount else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        let db = try database(scope, permit: permit)
        return try permit.writeIfCurrent {
            try db.transaction {
                try self.requireReplay(snapshotID, db)
                guard try rawRowCount >= (db.integer("SELECT raw_count FROM snapshots WHERE id=?", [.text(snapshotID.uuidString)])),
                      try recognizedEventCount >= (db.integer("SELECT recognized_count FROM snapshots WHERE id=?", [.text(snapshotID.uuidString)])) else { throw LocalPhotoDisplayReconciliationError.invalidState }
                try Task.checkCancellation()
                try db.execute("UPDATE snapshots SET raw_count=?,recognized_count=? WHERE id=?", [.integer(rawRowCount), .integer(recognizedEventCount), .text(snapshotID.uuidString)])
            }
        }
    }

    func completeMetadataSnapshot(snapshotID: UUID, receipt: LocalPhotoDisplayStreamReceipt,
                                  scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> LocalPhotoDisplayMetadataSnapshot
    {
        try Task.checkCancellation()
        let db = try database(scope, permit: permit)
        try requireReplay(snapshotID, db)
        guard receipt.completeAck.hasPrefix("SyncCompleteV1|"),
              UUID(uuidString: String(receipt.completeAck.dropFirst("SyncCompleteV1|".count))) != nil,
              receipt.rawRowCount > 0, receipt.recognizedEventCount >= 0, receipt.ignoredMetadataEventCount >= 0,
              receipt.batchCount >= 0,
              receipt.rawRowCount == receipt.recognizedEventCount + receipt.ignoredMetadataEventCount + 1,
              try db.integer("SELECT event_count FROM snapshots WHERE id=?", [.text(snapshotID.uuidString)]) == receipt.recognizedEventCount
        else { throw LocalPhotoDisplayReconciliationError.invalidState }
        let version = try evidenceVersion(snapshotID, db)
        let encoded = try JSONEncoder().encode(receipt)
        guard try permit.writeIfCurrent({
            try db.transaction {
                try self.requireReplay(snapshotID, db)
                // Revoke only weak links whose complete accepted metadata evidence changed or disappeared.
                let invalidAliases = "evidence_hash IS NULL OR NOT EXISTS (SELECT 1 FROM metadata_assets a WHERE a.snapshot_id=? AND a.asset_id=alias_links.remote_id AND a.evidence_hash=alias_links.evidence_hash)"
                let invalidDisplay = invalidAliases.replacingOccurrences(of: "alias_links.", with: "display_links.")
                try db.execute("DELETE FROM local_work WHERE local_id IN (SELECT local_id FROM alias_links WHERE " + invalidAliases + ")", [.text(snapshotID.uuidString)])
                try db.execute("DELETE FROM alias_links WHERE " + invalidAliases, [.text(snapshotID.uuidString)])
                try db.execute("DELETE FROM display_links WHERE " + invalidDisplay, [.text(snapshotID.uuidString)])
                try db.execute("UPDATE snapshots SET completed=1,evidence_version=?,receipt=? WHERE id=?", [.text(version), .blob(encoded), .text(snapshotID.uuidString)])
                try db.set("active", snapshotID.uuidString)
                try db.execute("DELETE FROM meta WHERE key='replay'")
                try db.execute("DELETE FROM snapshots WHERE id<>?", [.text(snapshotID.uuidString)])
                try Task.checkCancellation()
            }
        }) else { throw CancellationError() }
        return .init(id: snapshotID, evidenceVersion: version, receipt: receipt)
    }

    func metadataSnapshot(scope: MediaAccountScope) throws -> LocalPhotoDisplayMetadataSnapshot? {
        try Task.checkCancellation()
        return try snapshot(database(scope))
    }

    func metadataRows(cloudIDs: Set<String>, scope: MediaAccountScope) throws -> [LocalPhotoDisplayMetadataRow] {
        try Self.validateIDs(Array(cloudIDs))
        guard !cloudIDs.isEmpty else { return [] }
        let db = try database(scope), current = try requireSnapshot(db)
        let values = [DisplayDBValue.text(current.id.uuidString), .text(current.id.uuidString)] + cloudIDs.sorted().map(DisplayDBValue.text)
        return try rows(db, "SELECT asset_id,key,value FROM metadata_rows WHERE snapshot_id=? AND asset_id IN (SELECT asset_id FROM metadata_rows WHERE snapshot_id=? AND cloud_id IN (" + Self.placeholders(cloudIDs.count) + ")) ORDER BY asset_id,key LIMIT 4097", values)
    }

    func metadataRows(assetIDs: [UUID], scope: MediaAccountScope) throws -> [LocalPhotoDisplayMetadataRow] {
        guard assetIDs.count <= 64, Set(assetIDs).count == assetIDs.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        guard !assetIDs.isEmpty else { return [] }
        let db = try database(scope), current = try requireSnapshot(db)
        return try rows(db, "SELECT asset_id,key,value FROM metadata_rows WHERE snapshot_id=? AND asset_id IN (" + Self.placeholders(assetIDs.count) + ") ORDER BY asset_id,key LIMIT 4097",
                        [.text(current.id.uuidString)] + assetIDs.map { .text($0.uuidString) })
    }

    func localWork(localIDs: [String], scope: MediaAccountScope) throws -> [LocalPhotoDisplayLocalWork] {
        try Self.validateIDs(localIDs)
        guard !localIDs.isEmpty else { return [] }
        return try database(scope).query("SELECT payload FROM local_work WHERE local_id IN (" + Self.placeholders(localIDs.count) + ") ORDER BY local_id", localIDs.map(DisplayDBValue.text)) {
            try JSONDecoder().decode(LocalPhotoDisplayLocalWork.self, from: $0.data(0))
        }
    }

    func displayAliasEvidence(localIDs: [String], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> [PhotoBackupDisplayAliasEvidence] {
        try Task.checkCancellation()
        try Self.validateIDs(localIDs)
        guard !localIDs.isEmpty, access == .full || access == .limited else { return [] }
        let sql = "SELECT alias_links.payload,w.payload,alias_links.local_id FROM alias_links JOIN local_work w ON w.local_id=alias_links.local_id WHERE w.result='matched' AND alias_links.access=? AND " + Self.currentAliasPredicate + " AND alias_links.local_id IN (" + Self.placeholders(localIDs.count) + ") ORDER BY alias_links.local_id"
        return try database(scope).query(sql, [.text(access.rawValue)] + localIDs.map(DisplayDBValue.text)) { row in
            let association = try JSONDecoder().decode(LocalMediaAssociation.self, from: row.data(0))
            let work = try JSONDecoder().decode(LocalPhotoDisplayLocalWork.self, from: row.data(1))
            try Self.validateLink(association)
            guard work.localID == row.string(2), association.localIdentity.localIdentifier == work.localID,
                  work.result == .matched, work.reason == .matched,
                  work.cloudID.map(LocalMediaMobileMetadata.isUsableCloudID) == true,
                  !work.identityVersion.isEmpty, !work.evidenceHash.isEmpty else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
            return .init(association: association, work: work)
        }
    }

    func checkpoint(scope: MediaAccountScope) throws -> LocalPhotoDisplayReconciliationCheckpoint? {
        let db = try database(scope)
        return try readCheckpoint(db)
    }

    func commitBatch(_ rows: [LocalPhotoDisplayLocalWork], links: [LocalMediaAssociation],
                     checkpoint: LocalPhotoDisplayReconciliationCheckpoint, scope: MediaAccountScope,
                     permit: LocalMediaSavePermit) throws -> Bool
    {
        try Task.checkCancellation()
        guard rows.count <= 64, links.count <= 64, Set(rows.map(\.localID)).count == rows.count,
              Set(links.map(\.localIdentity.localIdentifier)).count == links.count,
              checkpoint.access == .full || checkpoint.access == .limited,
              checkpoint.totalLocal >= 0, checkpoint.processedLocal >= 0,
              checkpoint.processedLocal <= checkpoint.totalLocal,
              !checkpoint.completed || checkpoint.processedLocal == checkpoint.totalLocal,
              !checkpoint.inventoryFingerprint.isEmpty else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        for row in rows {
            guard !row.localID.isEmpty, !row.identityVersion.isEmpty, !row.evidenceHash.isEmpty,
                  row.cloudID.map(LocalMediaMobileMetadata.isUsableCloudID) ?? true,
                  (row.result == .matched) == (row.reason == .matched) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        }
        let encodedLinks = try links.map { value -> (LocalMediaAssociation, Data) in
            try Self.validateLink(value)
            guard rows.contains(where: { $0.localID == value.localIdentity.localIdentifier && $0.result == .matched }) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
            return try (value, JSONEncoder().encode(value))
        }
        let encodedRows = try rows.map { try ($0, JSONEncoder().encode($0)) }
        let db = try database(scope, permit: permit)
        return try permit.writeIfCurrent {
            try db.transaction {
                let active = try self.requireSnapshot(db)
                guard active.id == checkpoint.snapshotID, active.evidenceVersion == checkpoint.evidenceVersion else { throw LocalPhotoDisplayReconciliationError.invalidState }
                if let old = try self.readCheckpoint(db), old.snapshotID == checkpoint.snapshotID,
                   old.inventoryFingerprint == checkpoint.inventoryFingerprint, old.photosGeneration == checkpoint.photosGeneration,
                   old.access == checkpoint.access
                {
                    guard checkpoint.processedLocal >= old.processedLocal else { throw LocalPhotoDisplayReconciliationError.invalidState }
                }
                var affectedRemotes = Set<UUID>()
                for (row, payload) in encodedRows {
                    try Task.checkCancellation()
                    let previousRemotes = try db.query("SELECT remote_id FROM alias_links WHERE local_id=? UNION SELECT remote_id FROM display_links WHERE local_id=?", [.text(row.localID), .text(row.localID)]) { $0.string(0) }
                    for id in previousRemotes {
                        guard let id = UUID(uuidString: id) else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
                        affectedRemotes.insert(id)
                    }
                    let proposed = encodedLinks.contains { $0.0.localIdentity.localIdentifier == row.localID }
                    if row.result == .matched, !proposed {
                        let old: [LocalPhotoDisplayLocalWork] = try db.query("SELECT payload FROM local_work WHERE local_id=?", [.text(row.localID)]) {
                            try JSONDecoder().decode(LocalPhotoDisplayLocalWork.self, from: $0.data(0))
                        }
                        guard old.first == row,
                              try db.integer("SELECT COUNT(*) FROM alias_links WHERE " + Self.currentAliasPredicate + " AND local_id=? AND access=?", [.text(row.localID), .text(checkpoint.access.rawValue)]) == 1 else { throw LocalPhotoDisplayReconciliationError.invalidState }
                    } else {
                        // A pending local item revokes its own proof, never another alias of the same remote asset.
                        try db.execute("DELETE FROM alias_links WHERE local_id=?", [.text(row.localID)])
                    }
                    try db.execute("INSERT INTO local_work(local_id,result,payload,inventory) VALUES(?,?,?,?) ON CONFLICT(local_id) DO UPDATE SET result=excluded.result,payload=excluded.payload,inventory=excluded.inventory", [.text(row.localID), .text(row.result.rawValue), .blob(payload), .text(checkpoint.inventoryFingerprint)])
                }
                for (value, payload) in encodedLinks {
                    guard let evidence = try db.text("SELECT evidence_hash FROM metadata_assets WHERE snapshot_id=? AND asset_id=?", [.text(active.id.uuidString), .text(value.remoteID.uuidString)]) else { throw LocalPhotoDisplayReconciliationError.invalidState }
                    try db.execute("INSERT INTO alias_links(local_id,remote_id,access,payload,evidence_hash,observed_snapshot) VALUES(?,?,?,?,?,?) ON CONFLICT(local_id) DO UPDATE SET remote_id=excluded.remote_id,access=excluded.access,payload=excluded.payload,evidence_hash=excluded.evidence_hash,observed_snapshot=excluded.observed_snapshot",
                                   [.text(value.localIdentity.localIdentifier), .text(value.remoteID.uuidString), .text(checkpoint.access.rawValue), .blob(payload), .text(evidence), .text(active.id.uuidString)])
                    affectedRemotes.insert(value.remoteID)
                }
                for remote in affectedRemotes.sorted(by: { $0.uuidString < $1.uuidString }) {
                    try self.rebuildDisplaySelection(remote, preferredAccess: checkpoint.access, db)
                }
                try db.execute("INSERT INTO checkpoints(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.blob(JSONEncoder().encode(checkpoint))])
                try Task.checkCancellation()
            }
        }
    }

    func progress(scope: MediaAccountScope) throws -> LocalPhotoDisplayReconciliationProgress {
        let db = try database(scope), current = try snapshot(db), checkpoint = try readCheckpoint(db)
        let replay = try db.text("SELECT value FROM meta WHERE key='replay'")
        let raw = try replay.map { try db.integer("SELECT MAX(event_count,raw_count) FROM snapshots WHERE id=?", [.text($0)]) } ?? 0
        let recognized = try replay.map { try db.integer("SELECT MAX(event_count,recognized_count) FROM snapshots WHERE id=?", [.text($0)]) } ?? 0
        let inventory = checkpoint?.inventoryFingerprint ?? ""
        let matched = try db.integer("SELECT COALESCE((SELECT count FROM work_counts WHERE result='matched' AND inventory=?),0)", [.text(inventory)])
        let unmatched = try db.integer("SELECT COALESCE((SELECT count FROM work_counts WHERE result='unmatched' AND inventory=?),0)", [.text(inventory)])
        let pending = try db.integer("SELECT COALESCE((SELECT count FROM work_counts WHERE result='pending' AND inventory=?),0)", [.text(inventory)])
        let phase: LocalPhotoDisplayReconciliationProgress.Phase = if replay != nil {
            .readingMetadata
        } else if checkpoint?.completed == true {
            unmatched == 0 && pending == 0 && matched == (checkpoint?.totalLocal ?? 0) ? .completed : .needsReview
        } else {
            current == nil ? .idle : .matching
        }
        return try .init(phase: phase, rawMetadataRows: replay == nil ? current?.receipt.rawRowCount ?? 0 : raw,
                         recognizedMetadataEvents: replay == nil ? current?.receipt.recognizedEventCount ?? 0 : recognized,
                         totalLocal: checkpoint?.totalLocal ?? 0, processedLocal: checkpoint?.processedLocal ?? 0,
                         matchedLocal: matched, unmatchedLocal: unmatched, pendingLocal: pending,
                         associationCount: db.integer("SELECT COUNT(*) FROM display_links"))
    }

    /// Immich-unlinked persistence is intentionally deferred. These stubs never grant a fallback capability.
    func lookupSourceFacts(assetIDs: [UUID], scope _: MediaAccountScope, access _: LocalPhotoLibraryAccess) throws -> [LocalPhotoDisplaySourceFact] {
        try Task.checkCancellation()
        guard assetIDs.count <= 64, Set(assetIDs).count == assetIDs.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        return []
    }

    func saveSourceFact(_: LocalPhotoDisplaySourceFact, scope _: MediaAccountScope, permit _: LocalMediaSavePermit) throws -> Bool {
        try Task.checkCancellation()
        return false
    }

    func removeSourceFacts(ids: [UUID], scope _: MediaAccountScope, permit: LocalMediaSavePermit) throws -> Bool {
        try Task.checkCancellation()
        guard ids.count <= 64, Set(ids).count == ids.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        return try permit.writeIfCurrent { try Task.checkCancellation() }
    }

    /// Cross-inventory candidates, not permission to skip current counter migration.
    func reusableLocalIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> Set<String> {
        try Task.checkCancellation()
        guard access == .full || access == .limited else { return [] }
        let db = try database(scope)
        guard let checkpoint = try readCheckpoint(db), checkpoint.access == access,
              !checkpoint.inventoryFingerprint.isEmpty else { return [] }
        let sql = "SELECT alias_links.local_id FROM alias_links JOIN local_work w ON w.local_id=alias_links.local_id WHERE w.result='matched' AND alias_links.access=? AND " + Self.currentAliasPredicate + " ORDER BY alias_links.local_id"
        return try Set(db.query(sql, [.text(access.rawValue)]) { $0.string(0) })
    }

    func verifiedLocalIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> Set<String> {
        try Task.checkCancellation()
        guard access == .full || access == .limited else { return [] }
        let db = try database(scope)
        guard let checkpoint = try readCheckpoint(db), checkpoint.access == access,
              !checkpoint.inventoryFingerprint.isEmpty else { return [] }
        // Work from an earlier inventory must still be processed and moved into the current counter generation.
        let sql = "SELECT alias_links.local_id FROM alias_links JOIN local_work w ON w.local_id=alias_links.local_id WHERE w.result='matched' AND w.inventory=? AND alias_links.access=? AND " + Self.currentAliasPredicate + " ORDER BY alias_links.local_id"
        return try Set(db.query(sql, [.text(checkpoint.inventoryFingerprint), .text(access.rawValue)]) { $0.string(0) })
    }

    func aliasLinks(localIDs: [String], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> [LocalMediaAssociation] {
        try Self.validateIDs(localIDs)
        guard !localIDs.isEmpty, access == .full || access == .limited else { return [] }
        return try database(scope).query("SELECT payload FROM alias_links WHERE " + Self.currentAliasPredicate + " AND access=? AND local_id IN (" + Self.placeholders(localIDs.count) + ") ORDER BY local_id", [.text(access.rawValue)] + localIDs.map(DisplayDBValue.text), map: Self.decodeLink)
    }

    func links(remoteIDs: [UUID], scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> [LocalMediaAssociation] {
        guard remoteIDs.count <= 64, Set(remoteIDs).count == remoteIDs.count else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        guard !remoteIDs.isEmpty, access == .full || access == .limited else { return [] }
        return try database(scope).query("SELECT payload FROM display_links WHERE " + Self.currentLinkPredicate + " AND access=? AND remote_id IN (" + Self.placeholders(remoteIDs.count) + ") ORDER BY remote_id", [.text(access.rawValue)] + remoteIDs.map { .text($0.uuidString) }, map: Self.decodeLink)
    }

    func linksPage(after remoteID: UUID?, limit: Int, scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> [LocalMediaAssociation] {
        guard limit > 0, limit <= 64 else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        guard access == .full || access == .limited else { return [] }
        return try database(scope).query("SELECT payload FROM display_links WHERE " + Self.currentLinkPredicate + " AND access=? AND remote_id>? ORDER BY remote_id LIMIT ?", [.text(access.rawValue), .text(remoteID?.uuidString ?? ""), .integer(limit)], map: Self.decodeLink)
    }

    func knownRemoteIDs(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> Set<UUID> {
        guard access == .full || access == .limited else { return [] }
        return try Set(database(scope).query("SELECT remote_id FROM display_links WHERE " + Self.currentLinkPredicate + " AND access=?", [.text(access.rawValue)]) {
            guard let id = UUID(uuidString: $0.string(0)) else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }; return id
        })
    }

    func distinctLocalCount(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> Int {
        guard access == .full || access == .limited else { return 0 }
        return try database(scope).integer("SELECT COUNT(DISTINCT local_id) FROM alias_links WHERE " + Self.currentAliasPredicate + " AND access=?", [.text(access.rawValue)])
    }

    /// Compatibility visible writes keep their remote display choice, but never substitute it for another local item's proof.
    func mergeLink(_ value: LocalMediaAssociation, scope: MediaAccountScope, access: LocalPhotoLibraryAccess, permit: LocalMediaSavePermit) throws -> Bool {
        try Self.validateLink(value)
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        let db = try database(scope, permit: permit), payload = try JSONEncoder().encode(value)
        try Task.checkCancellation()
        return try permit.writeIfCurrent {
            try db.transaction {
                let old = try db.query("SELECT payload FROM alias_links WHERE local_id=?", [.text(value.localIdentity.localIdentifier)], map: Self.decodeLink).first
                if old != value {
                    try db.execute("DELETE FROM local_work WHERE local_id=?", [.text(value.localIdentity.localIdentifier)])
                }
                let observed: DisplayDBValue = try self.snapshot(db).map { .text($0.id.uuidString) } ?? .null
                try db.execute("INSERT INTO alias_links(local_id,remote_id,access,payload,evidence_hash,observed_snapshot) VALUES(?,?,?,?,NULL,?) ON CONFLICT(local_id) DO UPDATE SET remote_id=excluded.remote_id,access=excluded.access,payload=excluded.payload,evidence_hash=NULL,observed_snapshot=excluded.observed_snapshot",
                               [.text(value.localIdentity.localIdentifier), .text(value.remoteID.uuidString), .text(access.rawValue), .blob(payload), observed])
                try db.execute("INSERT INTO display_links(remote_id,local_id,access,payload,evidence_hash,observed_snapshot) VALUES(?,?,?,?,NULL,?) ON CONFLICT(remote_id) DO UPDATE SET local_id=excluded.local_id,access=excluded.access,payload=excluded.payload,evidence_hash=NULL,observed_snapshot=excluded.observed_snapshot",
                               [.text(value.remoteID.uuidString), .text(value.localIdentity.localIdentifier), .text(access.rawValue), .blob(payload), observed])
                try Task.checkCancellation()
            }
        }
    }

    func removeLink(_ id: UUID, scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> Bool {
        let db = try database(scope, permit: permit)
        try Task.checkCancellation()
        return try permit.writeIfCurrent {
            try db.transaction {
                try db.execute("DELETE FROM local_work WHERE local_id IN (SELECT local_id FROM alias_links WHERE remote_id=?)", [.text(id.uuidString)])
                try db.execute("DELETE FROM alias_links WHERE remote_id=?", [.text(id.uuidString)])
                try db.execute("DELETE FROM display_links WHERE remote_id=?", [.text(id.uuidString)])
                try Task.checkCancellation()
            }
        }
    }

    private func rebuildDisplaySelection(_ remoteID: UUID, preferredAccess: LocalPhotoLibraryAccess, _ db: DisplayReconciliationDatabase) throws {
        let previous = try db.text("SELECT local_id FROM display_links WHERE remote_id=?", [.text(remoteID.uuidString)]) ?? ""
        let selected: [[DisplayDBValue]] = try db.query("SELECT local_id,access,payload,evidence_hash,observed_snapshot FROM alias_links WHERE " + Self.currentAliasPredicate + " AND remote_id=? ORDER BY CASE WHEN access=? THEN 0 ELSE 1 END,CASE WHEN local_id=? THEN 0 ELSE 1 END,local_id LIMIT 1",
                                                        [.text(remoteID.uuidString), .text(preferredAccess.rawValue), .text(previous)])
        {
            [.text(remoteID.uuidString), .text($0.string(0)), .text($0.string(1)), .blob($0.data(2)), $0.optionalString(3).map(DisplayDBValue.text) ?? .null, $0.optionalString(4).map(DisplayDBValue.text) ?? .null]
        }
        try db.execute("DELETE FROM display_links WHERE remote_id=?", [.text(remoteID.uuidString)])
        if let values = selected.first {
            try db.execute("INSERT INTO display_links(remote_id,local_id,access,payload,evidence_hash,observed_snapshot) VALUES(?,?,?,?,?,?)", values)
        }
    }

    private func rows(_ db: DisplayReconciliationDatabase, _ sql: String, _ values: [DisplayDBValue]) throws -> [LocalPhotoDisplayMetadataRow] {
        try Task.checkCancellation()
        let output = try db.query(sql, values) { row in
            guard let id = UUID(uuidString: row.string(0)) else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
            return LocalPhotoDisplayMetadataRow(assetID: id, key: row.string(1), value: row.data(2))
        }
        guard output.count <= maximumQueryRows else { throw LocalPhotoDisplayReconciliationError.limitExceeded }
        return output
    }

    private func requireReplay(_ id: UUID, _ db: DisplayReconciliationDatabase) throws {
        guard try db.text("SELECT value FROM meta WHERE key='replay'") == id.uuidString,
              try db.integer("SELECT COUNT(*) FROM snapshots WHERE id=? AND completed=0", [.text(id.uuidString)]) == 1 else { throw LocalPhotoDisplayReconciliationError.invalidState }
    }

    private func snapshot(_ db: DisplayReconciliationDatabase) throws -> LocalPhotoDisplayMetadataSnapshot? {
        try db.query("SELECT id,evidence_version,receipt FROM snapshots WHERE completed=1 AND id=(SELECT value FROM meta WHERE key='active')") { row in
            guard let id = UUID(uuidString: row.string(0)) else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
            return try LocalPhotoDisplayMetadataSnapshot(id: id, evidenceVersion: row.string(1), receipt: JSONDecoder().decode(LocalPhotoDisplayStreamReceipt.self, from: row.data(2)))
        }.first
    }

    private func requireSnapshot(_ db: DisplayReconciliationDatabase) throws -> LocalPhotoDisplayMetadataSnapshot {
        guard let value = try snapshot(db) else { throw LocalPhotoDisplayReconciliationError.incompleteSnapshot }; return value
    }

    private func readCheckpoint(_ db: DisplayReconciliationDatabase) throws -> LocalPhotoDisplayReconciliationCheckpoint? {
        try db.query("SELECT payload FROM checkpoints WHERE id=1") { try JSONDecoder().decode(LocalPhotoDisplayReconciliationCheckpoint.self, from: $0.data(0)) }.first
    }

    private func updateAssetEvidence(_ assetID: UUID, _ snapshotID: UUID, _ db: DisplayReconciliationDatabase) throws {
        let rows = try db.query("SELECT key,value FROM metadata_rows WHERE snapshot_id=? AND asset_id=? ORDER BY key LIMIT 257", [.text(snapshotID.uuidString), .text(assetID.uuidString)]) { ($0.string(0), $0.data(1)) }
        guard rows.count <= 256 else { throw LocalPhotoDisplayReconciliationError.limitExceeded }
        guard !rows.isEmpty else {
            try db.execute("DELETE FROM metadata_assets WHERE snapshot_id=? AND asset_id=?", [.text(snapshotID.uuidString), .text(assetID.uuidString)]); return
        }
        var digest = SHA256()
        for (key, value) in rows {
            Self.hashPart(Data(key.utf8), into: &digest); Self.hashPart(value, into: &digest)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try db.execute("INSERT INTO metadata_assets(snapshot_id,asset_id,evidence_hash) VALUES(?,?,?) ON CONFLICT(snapshot_id,asset_id) DO UPDATE SET evidence_hash=excluded.evidence_hash", [.text(snapshotID.uuidString), .text(assetID.uuidString), .text(hash)])
    }

    private func evidenceVersion(_ id: UUID, _ db: DisplayReconciliationDatabase) throws -> String {
        var digest = SHA256(), lastAsset = ""
        while true {
            try Task.checkCancellation()
            let batch = try db.query("SELECT asset_id,evidence_hash FROM metadata_assets WHERE snapshot_id=? AND asset_id>? ORDER BY asset_id LIMIT 64", [.text(id.uuidString), .text(lastAsset)]) { ($0.string(0), $0.string(1)) }
            guard !batch.isEmpty else { break }
            for (asset, hash) in batch {
                Self.hashPart(Data(asset.utf8), into: &digest); Self.hashPart(Data(hash.utf8), into: &digest)
            }
            lastAsset = batch[batch.count - 1].0
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func hashPart(_ part: Data, into digest: inout SHA256) {
        digest.update(data: Data(String(part.count).utf8)); digest.update(data: Data([0])); digest.update(data: part)
    }

    /// Fresh visible reads are valid until the next complete snapshot; durable worker links bind exact per-asset evidence.
    private nonisolated static let currentLinkPredicate = "(NOT EXISTS(SELECT 1 FROM meta WHERE key='active') OR (display_links.evidence_hash IS NULL AND display_links.observed_snapshot=(SELECT value FROM meta WHERE key='active')) OR EXISTS(SELECT 1 FROM metadata_assets a WHERE a.snapshot_id=(SELECT value FROM meta WHERE key='active') AND a.asset_id=display_links.remote_id AND a.evidence_hash=display_links.evidence_hash))"

    private nonisolated static let currentAliasPredicate = currentLinkPredicate.replacingOccurrences(of: "display_links.", with: "alias_links.")

    private nonisolated static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private nonisolated static func validateIDs(_ ids: [String]) throws {
        guard ids.count <= 64, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
    }

    private nonisolated static func validateLink(_ value: LocalMediaAssociation) throws {
        guard value.source == .exactCloudIdentity, !value.localIdentity.localIdentifier.isEmpty,
              let modified = value.localIdentity.modificationDate, modified.timeIntervalSince1970.isFinite,
              value.remoteRevision.timeIntervalSince1970.isFinite, value.displayRevision?.timeIntervalSince1970.isFinite ?? true,
              let digest = Data(base64Encoded: value.checksum), digest.count == 20, digest.base64EncodedString() == value.checksum
        else { throw LocalMediaMetadataError.invalidMetadata }
    }

    private nonisolated static func decodeLink(_ row: DisplayDBRow) throws -> LocalMediaAssociation {
        let value = try JSONDecoder().decode(LocalMediaAssociation.self, from: row.data(0)); try validateLink(value); return value
    }

    private nonisolated struct PreparedEvent {
        let assetID: UUID; let key: String; let ack: String; let value: Data?; let cloudID: String?; let digest: String
    }

    private nonisolated static func prepareEvent(_ event: LocalPhotoDisplayIdentityEvent) throws -> PreparedEvent {
        guard event.key == "mobile-app" || event.key == LocalMediaDisplayCloudIdentity.metadataKey || event.key.hasPrefix(PhotoBackupOrigin.keyPrefix),
              !event.ack.isEmpty, event.ack.utf8.count <= 512 else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
        var value: Data?, cloud: String?
        if case let .upsert(_, _, bytes, _) = event {
            guard bytes.count <= 262_144, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalPhotoDisplayReconciliationError.invalidBatch }
            value = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let candidate = event.key.hasPrefix(PhotoBackupOrigin.keyPrefix) ? (object["metadata"] as? [String: Any])?["iCloudId"] as? String : object["iCloudId"] as? String
            if let candidate, LocalMediaMobileMetadata.isUsableCloudID(candidate), candidate.utf8.count <= 4096 {
                cloud = candidate
            }
        }
        let identity = Data((event.assetID.uuidString + "|" + event.key + "|" + (value == nil ? "delete" : "upsert")).utf8) + (value ?? Data())
        return .init(assetID: event.assetID, key: event.key, ack: event.ack, value: value, cloudID: cloud,
                     digest: SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined())
    }

    func close() {
        databases.removeAll()
    }

    private func database(_ scope: MediaAccountScope, permit: LocalMediaSavePermit? = nil) throws -> DisplayReconciliationDatabase {
        try Task.checkCancellation()
        let namespace = scope.cacheNamespace
        guard namespace.count == 64, namespace.allSatisfy(\.isHexDigit) else { throw LocalPhotoDisplayReconciliationError.invalidScope }
        if let existing = databases[namespace] {
            try prepareAliasStorage(scope, existing, permit ?? LocalMediaSavePermit()); return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try DisplayReconciliationDatabase(url: directory.appendingPathComponent(namespace).appendingPathExtension("sqlite"))
        guard try db.text("SELECT value FROM meta WHERE key='namespace'").map({ $0 == namespace }) ?? true else { throw LocalPhotoDisplayReconciliationError.invalidScope }
        try db.set("namespace", namespace)
        databases[namespace] = db
        try prepareAliasStorage(scope, db, permit ?? LocalMediaSavePermit())
        return db
    }

    /// The v2 header makes old v1-only readers reject safely before touching alias state.
    /// A persisted cursor makes the row migration restartable; every write batch has at most 64 local inputs.
    private func prepareAliasStorage(_ scope: MediaAccountScope, _ db: DisplayReconciliationDatabase, _ permit: LocalMediaSavePermit) throws {
        if try db.text("SELECT value FROM meta WHERE key='alias_rows_migrated'") != "1" {
            var after = try db.text("SELECT value FROM meta WHERE key='alias_migration_cursor'") ?? ""
            while true {
                try Task.checkCancellation()
                let batch: [(String, [DisplayDBValue])] = try db.query("SELECT remote_id,local_id,access,payload,evidence_hash,observed_snapshot FROM display_links WHERE remote_id>? ORDER BY remote_id LIMIT 64", [.text(after)]) { row in
                    let value = try JSONDecoder().decode(LocalMediaAssociation.self, from: row.data(3))
                    try Self.validateLink(value)
                    guard value.remoteID.uuidString == row.string(0), value.localIdentity.localIdentifier == row.string(1),
                          row.string(2) == LocalPhotoLibraryAccess.full.rawValue || row.string(2) == LocalPhotoLibraryAccess.limited.rawValue else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
                    return (row.string(0), [.text(row.string(1)), .text(row.string(0)), .text(row.string(2)), .blob(row.data(3)), row.optionalString(4).map(DisplayDBValue.text) ?? .null, row.optionalString(5).map(DisplayDBValue.text) ?? .null])
                }
                guard let last = batch.last else { break }
                guard try permit.writeIfCurrent({
                    try db.transaction {
                        for (_, values) in batch {
                            try db.execute("INSERT INTO alias_links(local_id,remote_id,access,payload,evidence_hash,observed_snapshot) VALUES(?,?,?,?,?,?) ON CONFLICT(local_id) DO NOTHING", values)
                        }
                        try db.set("alias_migration_cursor", last.0)
                        try Task.checkCancellation()
                    }
                }) else { throw CancellationError() }
                after = last.0
            }
            guard try permit.writeIfCurrent({ try db.set("alias_rows_migrated", "1") }) else { throw CancellationError() }
        }
        try migrateLegacy(scope, db, permit)
        if try db.text("SELECT value FROM meta WHERE key='alias_work_repaired'") != "1" {
            while true {
                try Task.checkCancellation()
                let unproven: [LocalPhotoDisplayLocalWork] = try db.query("SELECT payload FROM local_work WHERE result='matched' AND NOT EXISTS(SELECT 1 FROM alias_links WHERE alias_links.local_id=local_work.local_id AND " + Self.currentAliasPredicate + ") ORDER BY local_id LIMIT 64") {
                    try JSONDecoder().decode(LocalPhotoDisplayLocalWork.self, from: $0.data(0))
                }
                guard !unproven.isEmpty else { break }
                guard try permit.writeIfCurrent({
                    try db.transaction {
                        for row in unproven {
                            let pending = LocalPhotoDisplayLocalWork(localID: row.localID, cloudID: row.cloudID, identityVersion: row.identityVersion, evidenceHash: row.evidenceHash, result: .pending, reason: .unverified)
                            try db.execute("UPDATE local_work SET result='pending',payload=? WHERE local_id=?", [.blob(JSONEncoder().encode(pending)), .text(row.localID)])
                        }
                        try Task.checkCancellation()
                    }
                }) else { throw CancellationError() }
            }
            guard try permit.writeIfCurrent({ try db.set("alias_work_repaired", "1") }) else { throw CancellationError() }
        }
    }

    private nonisolated struct LegacyEntry: Decodable {
        let remoteID: UUID; let remoteRevision: Date; let displayRevision: Date?; let localID: String
        let modifiedAt: Date; let kind: String; let checksum: String
        func association() throws -> LocalMediaAssociation {
            let kind: LocalPhotoIdentity.MediaKind
            switch self.kind { case "image": kind = .image; case "video": kind = .video; case "livePhoto": kind = .livePhoto; default: throw LocalMediaMetadataError.invalidMetadata }
            let value = LocalMediaAssociation(remoteID: remoteID, remoteRevision: remoteRevision,
                                              localIdentity: .init(localIdentifier: localID, modificationDate: modifiedAt, mediaKind: kind),
                                              checksum: checksum, source: .exactCloudIdentity, displayRevision: displayRevision)
            try LocalPhotoDisplayReconciliationStore.validateLink(value); return value
        }
    }

    private nonisolated struct LegacyDocument: Decodable {
        let formatVersion: Int; let namespace: String; let access: LocalPhotoLibraryAccess; let entries: [LegacyEntry]
    }

    private func migrateLegacy(_ scope: MediaAccountScope, _ db: DisplayReconciliationDatabase, _ permit: LocalMediaSavePermit) throws {
        guard try db.text("SELECT value FROM meta WHERE key='legacy_imported'") == nil else { return }
        let file = directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let document = try JSONDecoder().decode(LegacyDocument.self, from: Data(contentsOf: file))
        guard document.formatVersion == 1, document.namespace == scope.cacheNamespace,
              document.access == .full || document.access == .limited,
              Set(document.entries.map(\.remoteID)).count == document.entries.count else { throw LocalMediaMetadataError.invalidMetadata }
        // Validate all legacy rows before importing the first batch. Never overwrite a newer SQLite row.
        let values = try document.entries.map { try $0.association() }
        for start in stride(from: 0, to: values.count, by: 64) {
            try Task.checkCancellation()
            guard try permit.writeIfCurrent({
                try db.transaction {
                    for value in values[start ..< min(start + 64, values.count)] {
                        try db.execute("INSERT INTO display_links(remote_id,local_id,access,payload) VALUES(?,?,?,?) ON CONFLICT(remote_id) DO NOTHING",
                                       [.text(value.remoteID.uuidString), .text(value.localIdentity.localIdentifier), .text(document.access.rawValue), .blob(JSONEncoder().encode(value))])
                        try db.execute("INSERT INTO alias_links(local_id,remote_id,access,payload) VALUES(?,?,?,?) ON CONFLICT(local_id) DO NOTHING",
                                       [.text(value.localIdentity.localIdentifier), .text(value.remoteID.uuidString), .text(document.access.rawValue), .blob(JSONEncoder().encode(value))])
                    }
                    try Task.checkCancellation()
                }
            }) else { throw CancellationError() }
        }
        guard try permit.writeIfCurrent({ try db.set("legacy_imported", "1") }) else { throw CancellationError() }
        // The original JSON is deliberately retained, including after a successful import.
    }
}

private nonisolated enum DisplayDBValue { case text(String), integer(Int), blob(Data), null }
private nonisolated struct DisplayDBRow {
    let statement: OpaquePointer
    func string(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func optionalString(_ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(column)
    }

    func data(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

private final nonisolated class DisplayReconciliationDatabase {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(handle); throw LocalPhotoDisplayReconciliationError.invalidDatabase }
        sqlite3_busy_timeout(handle, 1000)
        do {
            let version = try integer("PRAGMA user_version"), application = try integer("PRAGMA application_id")
            let tableCount = try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")
            guard (version == 0 && application == 0 && tableCount == 0)
                || ((version == 1 || version == 2) && application == 0x5244_5044) else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=NORMAL"); try execute("PRAGMA foreign_keys=ON")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY,completed INTEGER NOT NULL,event_count INTEGER NOT NULL,raw_count INTEGER NOT NULL DEFAULT 0,recognized_count INTEGER NOT NULL DEFAULT 0,last_ack TEXT,evidence_version TEXT,receipt BLOB)")
                try execute("CREATE TABLE IF NOT EXISTS metadata_rows(snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,asset_id TEXT NOT NULL,key TEXT NOT NULL,value BLOB NOT NULL,cloud_id TEXT,PRIMARY KEY(snapshot_id,asset_id,key))")
                try execute("CREATE TABLE IF NOT EXISTS metadata_assets(snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,asset_id TEXT NOT NULL,evidence_hash TEXT NOT NULL,PRIMARY KEY(snapshot_id,asset_id))")
                try execute("CREATE INDEX IF NOT EXISTS metadata_cloud ON metadata_rows(snapshot_id,cloud_id,asset_id)")
                try execute("CREATE TABLE IF NOT EXISTS events(snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,ack TEXT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(snapshot_id,ack))")
                try execute("CREATE TABLE IF NOT EXISTS display_links(remote_id TEXT PRIMARY KEY,local_id TEXT NOT NULL,access TEXT NOT NULL,payload BLOB NOT NULL,evidence_hash TEXT,observed_snapshot TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS display_local ON display_links(local_id,access)")
                try execute("CREATE TABLE IF NOT EXISTS alias_links(local_id TEXT PRIMARY KEY,remote_id TEXT NOT NULL,access TEXT NOT NULL,payload BLOB NOT NULL,evidence_hash TEXT,observed_snapshot TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS alias_remote ON alias_links(remote_id,access,local_id)")
                try execute("CREATE TABLE IF NOT EXISTS local_work(local_id TEXT PRIMARY KEY,result TEXT NOT NULL,payload BLOB NOT NULL,inventory TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS work_counts(inventory TEXT NOT NULL,result TEXT NOT NULL,count INTEGER NOT NULL CHECK(count>=0),PRIMARY KEY(inventory,result))")
                try execute("CREATE TRIGGER IF NOT EXISTS work_count_insert AFTER INSERT ON local_work BEGIN INSERT INTO work_counts(inventory,result,count) VALUES(new.inventory,new.result,1) ON CONFLICT(inventory,result) DO UPDATE SET count=count+1; END")
                try execute("CREATE TRIGGER IF NOT EXISTS work_count_delete AFTER DELETE ON local_work BEGIN UPDATE work_counts SET count=count-1 WHERE inventory=old.inventory AND result=old.result; END")
                try execute("CREATE TRIGGER IF NOT EXISTS work_count_update AFTER UPDATE OF inventory,result ON local_work WHEN old.inventory<>new.inventory OR old.result<>new.result BEGIN UPDATE work_counts SET count=count-1 WHERE inventory=old.inventory AND result=old.result; INSERT INTO work_counts(inventory,result,count) VALUES(new.inventory,new.result,1) ON CONFLICT(inventory,result) DO UPDATE SET count=count+1; END")
                try execute("CREATE TABLE IF NOT EXISTS checkpoints(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)")
                try execute("PRAGMA application_id=1380208708"); try execute("PRAGMA user_version=2")
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }

    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [DisplayDBValue] = []) throws {
        let _: [Int] = try query(sql, values) { _ in 0 }
    }

    func integer(_ sql: String, _ values: [DisplayDBValue] = []) throws -> Int {
        try query(sql, values) { Int(sqlite3_column_int64($0.statement, 0)) }.first ?? 0
    }

    func text(_ sql: String, _ values: [DisplayDBValue] = []) throws -> String? {
        try query(sql, values) { $0.string(0) }.first
    }

    func set(_ key: String, _ value: String) throws {
        try execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    func query<T>(_ sql: String, _ values: [DisplayDBValue] = [], map: (DisplayDBRow) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case let .text(value): code = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .integer(value): code = sqlite3_bind_int64(statement, index, Int64(value))
            case let .blob(value): code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try result.append(map(.init(statement: statement)))
            case SQLITE_DONE: return result
            default: throw LocalPhotoDisplayReconciliationError.invalidDatabase
            }
        }
    }
}
