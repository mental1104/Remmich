import Foundation
import SQLite3
import Testing
@testable import Remmich

@Suite("Display reconciliation SQLite isolation")
@MainActor struct LocalPhotoDisplayReconciliationStoreTests {
    @Test func displayAliasEvidenceRequiresOneCurrentMatchedTupleAndScope() async throws {
        try await withReconciliationStore { store, scope, _ in
            let matchedID = UUID(), pendingID = UUID(), visibleID = UUID(), permit = LocalMediaSavePermit()
            let matched = displayWork("tuple-matched")
            let pending = displayWork("tuple-pending", result: .pending, reason: .unverified)
            let requested = [matched.localID, pending.localID, "tuple-visible-only"]
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(matchedID, "cloud-tuple-matched"),
                                                                          displayStage(pendingID, "cloud-tuple-pending"),
                                                                          displayStage(visibleID, "cloud-tuple-visible")])
            let matchedLink = displayLink(matchedID, matched.localID)
            #expect(try await store.mergeLink(displayLink(visibleID, "tuple-visible-only"), scope: scope, access: .full, permit: permit))
            #expect(try await store.commitBatch([matched, pending], links: [matchedLink],
                                                checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 3), scope: scope, permit: permit))
            let evidence = try await store.displayAliasEvidence(localIDs: requested, scope: scope, access: .full)
            #expect(evidence.count == 1)
            let tuple = try #require(evidence.first)
            #expect(tuple.association == matchedLink && tuple.work == matched)
            #expect(try await store.displayAliasEvidence(localIDs: requested, scope: scope, access: .limited).isEmpty)
            let otherAccount = displayTestScope(user: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            #expect(try await store.displayAliasEvidence(localIDs: requested, scope: otherAccount, access: .full).isEmpty)
            _ = try await acceptDisplaySnapshot(store, scope, [displayStage(matchedID, "changed-cloud"),
                                                               displayStage(pendingID, "cloud-tuple-pending"),
                                                               displayStage(visibleID, "cloud-tuple-visible")])
            #expect(try await store.displayAliasEvidence(localIDs: requested, scope: scope, access: .full).isEmpty)
        }
    }

    @Test func reusableIDsRecoverMixedInventoriesWithoutBypassingProofOrCounts() async throws {
        try await withReconciliationStore { store, scope, directory in
            let aID = UUID(), bID = UUID(), cID = UUID(), pendingID = UUID(), visibleID = UUID()
            let permit = LocalMediaSavePermit(), a = displayWork("reuse-a"), b = displayWork("reuse-b"), c = displayWork("reuse-c")
            let pending = displayWork("reuse-pending", result: .pending, reason: .unverified)
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(aID, "a"), displayStage(bID, "b"), displayStage(cID, "c"), displayStage(pendingID, "pending"), displayStage(visibleID, "visible")])
            #expect(try await store.mergeLink(displayLink(visibleID, "visible-only"), scope: scope, access: .full, permit: permit))
            let beforeCheckpoint = try await store.reusableLocalIDs(scope: scope, access: .full)
            #expect(beforeCheckpoint.isEmpty)
            let old = LocalPhotoDisplayReconciliationCheckpoint(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "old-reuse-inventory", access: .full, photosGeneration: UUID(), totalLocal: 5, processedLocal: 4, completed: false)
            #expect(try await store.commitBatch([a, b, c, pending], links: [displayLink(aID, a.localID), displayLink(bID, b.localID), displayLink(cID, c.localID)], checkpoint: old, scope: scope, permit: permit))
            let allProven = Set([a.localID, b.localID, c.localID])
            #expect(try await store.reusableLocalIDs(scope: scope, access: .full) == allProven)
            let newPartial = LocalPhotoDisplayReconciliationCheckpoint(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "new-reuse-inventory", access: .full, photosGeneration: UUID(), totalLocal: 8, processedLocal: 1, completed: false)
            #expect(try await store.commitBatch([a], links: [], checkpoint: newPartial, scope: scope, permit: permit))
            // Old and new counter generations are candidates, but only the rebased local item is already verified for skipping.
            #expect(try await store.reusableLocalIDs(scope: scope, access: .full) == allProven)
            #expect(try await store.verifiedLocalIDs(scope: scope, access: .full) == Set([a.localID]))
            let notMigratedCounts = try await store.progress(scope: scope)
            #expect(notMigratedCounts.matchedLocal == 1 && notMigratedCounts.processedLocal == 1)
            await store.close()
            #expect(try await store.reusableLocalIDs(scope: scope, access: .full) == allProven)
            let wrongAccess = try await store.reusableLocalIDs(scope: scope, access: .limited)
            let wrongAccount = try await store.reusableLocalIDs(scope: displayTestScope(user: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), access: .full)
            #expect(wrongAccess.isEmpty && wrongAccount.isEmpty)
            let changedC = displayWork(c.localID, result: .pending, reason: .sourceChanged)
            #expect(try await store.commitBatch([changedC], links: [], checkpoint: newPartial, scope: scope, permit: permit))
            #expect(try await store.reusableLocalIDs(scope: scope, access: .full) == Set([a.localID, b.localID]))
            await store.close()
            // A matched work row without an actual persisted alias must never become a skip candidate.
            let database = directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("sqlite")
            try aliasFixtureSQL(database, "DELETE FROM alias_links WHERE local_id='reuse-b'")
            #expect(try await store.reusableLocalIDs(scope: scope, access: .full) == Set([a.localID]))
            _ = try await acceptDisplaySnapshot(store, scope, [displayStage(aID, "changed-a"), displayStage(bID, "b"), displayStage(cID, "c"), displayStage(pendingID, "pending"), displayStage(visibleID, "visible")])
            let afterMetadataChange = try await store.reusableLocalIDs(scope: scope, access: .full)
            #expect(afterMetadataChange.isEmpty)
        }
    }

    @Test func verifiedIDsRequireCheckpointMatchedWorkAndCurrentPositiveProof() async throws {
        try await withReconciliationStore { store, scope, _ in
            let matchedID = UUID(), pendingID = UUID(), visibleID = UUID(), permit = LocalMediaSavePermit()
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(matchedID, "matched"), displayStage(pendingID, "pending"), displayStage(visibleID, "visible")])
            #expect(try await store.mergeLink(displayLink(visibleID, "visible-only"), scope: scope, access: .full, permit: permit))
            let missingCheckpointIDs = try await store.verifiedLocalIDs(scope: scope, access: .full)
            #expect(missingCheckpointIDs.isEmpty)
            let matched = displayWork("matched"), pending = displayWork("pending", result: .pending, reason: .unverified)
            let checkpoint = LocalPhotoDisplayReconciliationCheckpoint(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "verified-inventory", access: .full, photosGeneration: UUID(), totalLocal: 3, processedLocal: 2, completed: false)
            #expect(try await store.commitBatch([matched, pending], links: [displayLink(matchedID, matched.localID)], checkpoint: checkpoint, scope: scope, permit: permit))
            #expect(try await store.verifiedLocalIDs(scope: scope, access: .full) == Set([matched.localID]))
            let wrongAccessIDs = try await store.verifiedLocalIDs(scope: scope, access: .limited)
            #expect(wrongAccessIDs.isEmpty)
            let otherAccountIDs = try await store.verifiedLocalIDs(scope: displayTestScope(user: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), access: .full)
            #expect(otherAccountIDs.isEmpty)
            _ = try await acceptDisplaySnapshot(store, scope, [displayStage(matchedID, "changed"), displayStage(pendingID, "pending"), displayStage(visibleID, "visible")])
            let invalidatedIDs = try await store.verifiedLocalIDs(scope: scope, access: .full)
            #expect(invalidatedIDs.isEmpty)
        }
    }

    @Test func verifiedIDsExcludeOldCounterInventoryAfterInterruptedNewPass() async throws {
        try await withReconciliationStore { store, scope, _ in
            let ids = [UUID(), UUID(), UUID()], permit = LocalMediaSavePermit()
            let rows = [displayWork("a"), displayWork("b"), displayWork("c")]
            let snapshot = try await acceptDisplaySnapshot(store, scope, zip(ids, rows).map { displayStage($0.0, $0.1.localID) })
            let old = LocalPhotoDisplayReconciliationCheckpoint(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "old-inventory", access: .full, photosGeneration: UUID(), totalLocal: 3, processedLocal: 3, completed: true)
            #expect(try await store.commitBatch(rows, links: zip(ids, rows).map { displayLink($0.0, $0.1.localID) }, checkpoint: old, scope: scope, permit: permit))
            #expect(try await store.verifiedLocalIDs(scope: scope, access: .full) == Set(rows.map(\.localID)))
            // Only the first batch has moved into the new inventory's counters when the pass is interrupted.
            let partial = LocalPhotoDisplayReconciliationCheckpoint(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "new-inventory", access: .full, photosGeneration: UUID(), totalLocal: 4, processedLocal: 1, completed: false)
            #expect(try await store.commitBatch([rows[0]], links: [], checkpoint: partial, scope: scope, permit: permit))
            #expect(try await store.verifiedLocalIDs(scope: scope, access: .full) == Set([rows[0].localID]))
            let progress = try await store.progress(scope: scope)
            #expect(progress.matchedLocal == 1 && progress.processedLocal == 1 && progress.totalLocal == 4)
            await store.close()
            #expect(try await store.verifiedLocalIDs(scope: scope, access: .full) == Set([rows[0].localID]))
            #expect(try await store.aliasLinks(localIDs: rows.map(\.localID), scope: scope, access: .full).count == 3)
        }
    }

    @Test func deferredSourceFactStubsNeverGrantOrPersistNegativeCapability() async throws {
        try await withReconciliationStore { store, scope, directory in
            let id = UUID(), permit = LocalMediaSavePermit()
            let fact = LocalPhotoDisplaySourceFact(assetID: id, displayRevision: Date(timeIntervalSinceReferenceDate: 100), observedAt: Date(timeIntervalSinceReferenceDate: 200), access: .full)
            #expect(try await store.saveSourceFact(fact, scope: scope, permit: permit) == false)
            let deferredFacts = try await store.lookupSourceFacts(assetIDs: [id], scope: scope, access: .full)
            #expect(deferredFacts.isEmpty)
            #expect(try await store.removeSourceFacts(ids: [id], scope: scope, permit: permit))
            let revoked = LocalMediaSavePermit(); revoked.invalidate()
            #expect(try await store.removeSourceFacts(ids: [id], scope: scope, permit: revoked) == false)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("sqlite").path))
        }
    }

    @Test(arguments: [false, true]) func localAliasesKeepIndependentProofsAcrossBatchesAndColdRestore(_ acrossBatches: Bool) async throws {
        try await withReconciliationStore { store, scope, _ in
            let remote = UUID(), permit = LocalMediaSavePermit()
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(remote, "cloud-a"), aliasOriginStage(remote, "cloud-b")])
            let a = aliasWork("local-a", "cloud-a"), b = aliasWork("local-b", "cloud-b")
            if acrossBatches {
                #expect(try await store.commitBatch([a], links: [displayLink(remote, a.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 1, total: 2), scope: scope, permit: permit))
                #expect(try await store.commitBatch([b], links: [displayLink(remote, b.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            } else {
                #expect(try await store.commitBatch([a, b], links: [displayLink(remote, a.localID), displayLink(remote, b.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            }
            let initialChoice = try await store.links(remoteIDs: [remote], scope: scope, access: .full)
            #expect(initialChoice.count == 1 && initialChoice.first?.localIdentity.localIdentifier == a.localID)
            #expect(try await store.aliasLinks(localIDs: [a.localID, b.localID], scope: scope, access: .full).count == 2)
            #expect(try await store.distinctLocalCount(scope: scope, access: .full) == 2)
            let before = try await store.progress(scope: scope)
            #expect(before.matchedLocal == 2 && before.associationCount == 1 && before.phase == .completed)
            await store.close()
            // A cold skip submits every local result without inventing proofs from the one display choice.
            #expect(try await store.commitBatch([a, b], links: [], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            #expect(try await store.aliasLinks(localIDs: [a.localID, b.localID], scope: scope, access: .full).count == 2)
            #expect(try await store.links(remoteIDs: [remote], scope: scope, access: .full) == initialChoice)
        }
    }

    @Test func pendingLocalAliasWithdrawsOnlyItsOwnProofAndRechoosesDisplay() async throws {
        try await withReconciliationStore { store, scope, _ in
            let remote = UUID(), permit = LocalMediaSavePermit()
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(remote, "cloud-a"), aliasOriginStage(remote, "cloud-b")])
            let a = aliasWork("local-a", "cloud-a"), b = aliasWork("local-b", "cloud-b")
            #expect(try await store.commitBatch([a, b], links: [displayLink(remote, a.localID), displayLink(remote, b.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            let changed = LocalPhotoDisplayLocalWork(localID: a.localID, cloudID: a.cloudID, identityVersion: "changed-local-version", evidenceHash: a.evidenceHash, result: .pending, reason: .sourceChanged)
            #expect(try await store.commitBatch([changed], links: [], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            #expect(try await store.aliasLinks(localIDs: [a.localID], scope: scope, access: .full).isEmpty)
            #expect(try await store.aliasLinks(localIDs: [b.localID], scope: scope, access: .full) == [displayLink(remote, b.localID)])
            #expect(try await store.links(remoteIDs: [remote], scope: scope, access: .full) == [displayLink(remote, b.localID)])
            let progress = try await store.progress(scope: scope)
            #expect(progress.matchedLocal == 1 && progress.pendingLocal == 1 && progress.associationCount == 1 && progress.phase == .needsReview)
            #expect(try await store.distinctLocalCount(scope: scope, access: .full) == 1)
            await #expect(throws: LocalPhotoDisplayReconciliationError.invalidState) {
                _ = try await store.commitBatch([a], links: [], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit)
            }
        }
    }

    @Test func formatOneMigrationRestoresOnlyActualLocalProofsAndPreservesCheckpoint() async throws {
        try await withReconciliationStore { store, scope, directory in
            let remote = UUID(), permit = LocalMediaSavePermit()
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(remote, "cloud-a"), aliasOriginStage(remote, "cloud-b")])
            let a = aliasWork("local-a", "cloud-a"), b = aliasWork("local-b", "cloud-b")
            #expect(try await store.commitBatch([a, b], links: [displayLink(remote, a.localID), displayLink(remote, b.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            await store.close()
            let file = directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("sqlite")
            // Recreate the real v1 limitation: two matched work rows, only one remote-keyed display proof.
            try aliasFixtureSQL(file, "DROP TABLE alias_links; DELETE FROM meta WHERE key IN ('alias_rows_migrated','alias_migration_cursor','alias_work_repaired'); PRAGMA user_version=1;")
            let restored = try await store.aliasLinks(localIDs: [a.localID, b.localID], scope: scope, access: .full)
            #expect(restored == [displayLink(remote, a.localID)])
            let work = try await store.localWork(localIDs: [a.localID, b.localID], scope: scope)
            #expect(work.first(where: { $0.localID == b.localID })?.result == .pending)
            let progress = try await store.progress(scope: scope)
            #expect(progress.processedLocal == 2 && progress.totalLocal == 2 && progress.matchedLocal == 1 && progress.pendingLocal == 1)
            await store.close()
            #expect(try aliasFixtureVersion(file) == 2)
            // The missing alias still requires new verification; it is never reconstructed from counts.
            #expect(try await store.commitBatch([b], links: [displayLink(remote, b.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 2, total: 2), scope: scope, permit: permit))
            #expect(try await store.distinctLocalCount(scope: scope, access: .full) == 2)
            #expect(try await store.progress(scope: scope).matchedLocal == 2)
        }
    }

    @Test func acceptedServerChangeInvalidatesOnlyThatRemoteAliases() async throws {
        try await withReconciliationStore { store, scope, _ in
            let shared = UUID(), unrelated = UUID(), permit = LocalMediaSavePermit()
            let events = try [displayStage(shared, "cloud-a"), aliasOriginStage(shared, "cloud-b"), displayStage(unrelated, "cloud-c")]
            let snapshot = try await acceptDisplaySnapshot(store, scope, events)
            let a = aliasWork("local-a", "cloud-a"), b = aliasWork("local-b", "cloud-b"), c = aliasWork("local-c", "cloud-c")
            #expect(try await store.commitBatch([a, b, c], links: [displayLink(shared, a.localID), displayLink(shared, b.localID), displayLink(unrelated, c.localID)], checkpoint: aliasCheckpoint(snapshot, processed: 3, total: 3), scope: scope, permit: permit))
            _ = try await acceptDisplaySnapshot(store, scope, [displayStage(shared, "changed-cloud"), displayStage(unrelated, "cloud-c")])
            #expect(try await store.aliasLinks(localIDs: [a.localID, b.localID, c.localID], scope: scope, access: .full) == [displayLink(unrelated, c.localID)])
            #expect(try await store.localWork(localIDs: [a.localID, b.localID], scope: scope).isEmpty)
            #expect(try await store.links(remoteIDs: [shared], scope: scope, access: .full).isEmpty)
            #expect(try await store.links(remoteIDs: [unrelated], scope: scope, access: .full) == [displayLink(unrelated, c.localID)])
            #expect(try await store.progress(scope: scope).matchedLocal == 1)
        }
    }

    @Test func incompleteReplayDoesNotReplaceAcceptedEvidenceOrLinks() async throws {
        try await withReconciliationStore { store, scope, _ in
            let id = UUID(), permit = LocalMediaSavePermit()
            let first = try await acceptDisplaySnapshot(store, scope, [displayStage(id, "cloud-a")])
            let row = displayWork("local-a")
            #expect(try await store.commitBatch([row], links: [displayLink(id, "local-a")], checkpoint: displayCheckpoint(first, total: 1), scope: scope, permit: permit))
            let partial = try await store.beginMetadataReplay(scope: scope, permit: permit)
            #expect(try await store.stageMetadata([displayStage(id, "cloud-b")], snapshotID: partial, scope: scope, permit: permit))
            #expect(try await store.metadataSnapshot(scope: scope) == first)
            #expect(try await store.knownRemoteIDs(scope: scope, access: .full) == [id])
            #expect(try await store.progress(scope: scope).phase == .readingMetadata)
            let revoked = LocalMediaSavePermit(); revoked.invalidate()
            await #expect(throws: CancellationError.self) {
                _ = try await store.completeMetadataSnapshot(snapshotID: partial, receipt: displayReceipt(1), scope: scope, permit: revoked)
            }
            #expect(try await store.metadataSnapshot(scope: scope) == first)
        }
    }

    @Test func incompleteStagingCannotUseAnOtherwiseValidEOFReceipt() async throws {
        try await withReconciliationStore { store, scope, _ in
            let permit = LocalMediaSavePermit(), replay = try await store.beginMetadataReplay(scope: scope, permit: LocalMediaSavePermit())
            let event = displayStage(UUID(), "synthetic")
            #expect(try await store.stageMetadata([event], snapshotID: replay, scope: scope, permit: permit))
            #expect(try await store.stageMetadata([event], snapshotID: replay, scope: scope, permit: permit))
            await #expect(throws: LocalPhotoDisplayReconciliationError.invalidState) {
                _ = try await store.completeMetadataSnapshot(snapshotID: replay, receipt: displayReceipt(2), scope: scope, permit: permit)
            }
            #expect(try await store.metadataSnapshot(scope: scope) == nil)
            _ = try await store.completeMetadataSnapshot(snapshotID: replay, receipt: displayReceipt(1), scope: scope, permit: permit)
            #expect(try await store.metadataRows(cloudIDs: ["synthetic"], scope: scope).count == 1)
        }
    }

    @Test func candidateLookupIncludesLateConflictingKeysAndDeleteIsApplied() async throws {
        try await withReconciliationStore { store, scope, _ in
            let id = UUID(), other = UUID(), permit = LocalMediaSavePermit()
            let replay = try await store.beginMetadataReplay(scope: scope, permit: permit)
            #expect(try await store.stageMetadata([displayStage(id, "cloud-a")], snapshotID: replay, scope: scope, permit: permit))
            let official = Data(#"{"iCloudId":"cloud-b"}"#.utf8)
            #expect(try await store.stageMetadata([.upsert(assetID: id, key: "mobile-app", value: official, ack: "AssetMetadataV1|late"),
                                                   displayStage(other, "cloud-a"), .delete(assetID: other, key: "remmich-icloud-match", ack: "AssetMetadataDeleteV1|gone")], snapshotID: replay, scope: scope, permit: permit))
            _ = try await store.completeMetadataSnapshot(snapshotID: replay, receipt: displayReceipt(4), scope: scope, permit: permit)
            let rows = try await store.metadataRows(cloudIDs: ["cloud-a"], scope: scope)
            #expect(rows.count == 2 && Set(rows.map(\.key)) == ["mobile-app", "remmich-icloud-match"])
            #expect(rows.allSatisfy { $0.assetID == id })
            #expect(try await store.metadataRows(assetIDs: [other], scope: scope).isEmpty)
        }
    }

    @Test func replayIsIdempotentAndOnlyChangedAssetLosesWeakEvidence() async throws {
        try await withReconciliationStore { store, scope, _ in
            let a = UUID(), b = UUID(), unrelated = UUID(), permit = LocalMediaSavePermit()
            let first = try await acceptDisplaySnapshot(store, scope, [displayStage(a, "cloud-a"), displayStage(b, "cloud-b")])
            #expect(try await store.commitBatch([displayWork("local-a"), displayWork("local-b")], links: [displayLink(a, "local-a"), displayLink(b, "local-b")], checkpoint: displayCheckpoint(first, total: 2), scope: scope, permit: permit))
            let same = try await acceptDisplaySnapshot(store, scope, [displayStage(b, "cloud-b"), displayStage(a, "cloud-a")])
            #expect(same.evidenceVersion == first.evidenceVersion)
            #expect(try await store.knownRemoteIDs(scope: scope, access: .full) == [a, b])
            let expanded = try await acceptDisplaySnapshot(store, scope, [displayStage(unrelated, "unrelated"), displayStage(a, "cloud-a"), displayStage(b, "cloud-b")])
            #expect(expanded.evidenceVersion != first.evidenceVersion)
            #expect(try await store.knownRemoteIDs(scope: scope, access: .full) == [a, b])
            _ = try await acceptDisplaySnapshot(store, scope, [displayStage(a, "changed"), displayStage(b, "cloud-b")])
            #expect(try await store.knownRemoteIDs(scope: scope, access: .full) == [b])
            #expect(try await store.localWork(localIDs: ["local-a", "local-b"], scope: scope).map(\.localID) == ["local-b"])
            #expect(try await store.progress(scope: scope).phase == .needsReview)
        }
    }

    @Test func batchFailureRollsBackLinksWorkAndCheckpoint() async throws {
        try await withReconciliationStore { store, scope, _ in
            let id = UUID(), permit = LocalMediaSavePermit()
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(id, "cloud-a")])
            // The second matched result lacks both a verified link and a prior stable work record.
            await #expect(throws: LocalPhotoDisplayReconciliationError.invalidState) {
                _ = try await store.commitBatch([displayWork("local-a"), displayWork("local-b")], links: [displayLink(id, "local-a")], checkpoint: displayCheckpoint(snapshot, total: 2), scope: scope, permit: permit)
            }
            #expect(try await store.localWork(localIDs: ["local-a", "local-b"], scope: scope).isEmpty)
            #expect(try await store.knownRemoteIDs(scope: scope, access: .full).isEmpty)
            #expect(try await store.checkpoint(scope: scope) == nil)
            let revoked = LocalMediaSavePermit(); revoked.invalidate()
            #expect(try await store.commitBatch([displayWork("local-a")], links: [displayLink(id, "local-a")], checkpoint: displayCheckpoint(snapshot, total: 1), scope: scope, permit: revoked) == false)
            #expect(try await store.checkpoint(scope: scope) == nil)
        }
    }

    @Test func stableWorkSurvivesNewInventoryAndReviewIsNotCompletion() async throws {
        try await withReconciliationStore { store, scope, _ in
            let id = UUID(), permit = LocalMediaSavePermit(), row = displayWork("local-a")
            let snapshot = try await acceptDisplaySnapshot(store, scope, [displayStage(id, "cloud-a")])
            #expect(try await store.commitBatch([row], links: [displayLink(id, "local-a")], checkpoint: displayCheckpoint(snapshot, total: 1), scope: scope, permit: permit))
            #expect(try await store.progress(scope: scope).phase == .completed)
            let pending = displayWork("local-b", result: .pending, reason: .unverified)
            let next = displayCheckpoint(snapshot, total: 2, inventory: "next-inventory")
            #expect(try await store.commitBatch([row, pending], links: [], checkpoint: next, scope: scope, permit: permit))
            let progress = try await store.progress(scope: scope)
            #expect(progress.phase == .needsReview && progress.matchedLocal == 1 && progress.pendingLocal == 1 && progress.processedLocal == 2)
            let smaller = displayCheckpoint(snapshot, total: 1, inventory: "smaller-inventory")
            #expect(try await store.commitBatch([pending], links: [], checkpoint: smaller, scope: scope, permit: permit))
            let reduced = try await store.progress(scope: scope)
            #expect(reduced.matchedLocal == 0 && reduced.pendingLocal == 1 && reduced.totalLocal == 1)
            #expect(try await store.links(remoteIDs: [id], scope: scope, access: .full).count == 1)
        }
    }

    @Test func boundedQueriesAccountIsolationAndDistinctLocalCount() async throws {
        try await withReconciliationStore { store, scope, _ in
            let permit = LocalMediaSavePermit(), ids = (0 ..< 3).map { _ in UUID() }
            for id in ids {
                #expect(try await store.mergeLink(displayLink(id, "one-local"), scope: scope, access: .full, permit: permit))
            }
            #expect(try await store.distinctLocalCount(scope: scope, access: .full) == 1)
            #expect(try await store.links(remoteIDs: ids, scope: scope, access: .limited).isEmpty)
            let first = try await store.linksPage(after: nil, limit: 2, scope: scope, access: .full)
            let second = try await store.linksPage(after: #require(first.last).remoteID, limit: 2, scope: scope, access: .full)
            #expect(first.count == 2 && second.count == 1 && Set((first + second).map(\.remoteID)) == Set(ids))
            #expect(try await store.knownRemoteIDs(scope: displayTestScope(user: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), access: .full).isEmpty)
            await #expect(throws: LocalPhotoDisplayReconciliationError.invalidBatch) {
                _ = try await store.links(remoteIDs: (0 ..< 65).map { _ in UUID() }, scope: scope, access: .full)
            }
            await #expect(throws: LocalMediaMetadataError.invalidMetadata) {
                let strong = LocalMediaAssociation(remoteID: UUID(), remoteRevision: Date(timeIntervalSince1970: 1), localIdentity: displayLink(UUID(), "strong").localIdentity, checksum: Data(repeating: 1, count: 20).base64EncodedString(), source: .checksum)
                _ = try await store.mergeLink(strong, scope: scope, access: .full, permit: permit)
            }
        }
    }

    @Test func legacyJSONMigratesOnceAndRemainsByteForByte() async throws {
        try await withReconciliationStore { store, scope, directory in
            let id = UUID(), link = displayLink(id, "legacy-local")
            let file = directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
            let object: [String: Any] = ["formatVersion": 1, "namespace": scope.cacheNamespace, "access": "full", "entries": [["remoteID": id.uuidString, "remoteRevision": 100.0 - Date.timeIntervalBetween1970AndReferenceDate, "localID": "legacy-local", "modifiedAt": 50.0 - Date.timeIntervalBetween1970AndReferenceDate, "kind": "image", "checksum": link.checksum]]]
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try original.write(to: file)
            #expect(try await store.links(remoteIDs: [id], scope: scope, access: .full) == [link])
            #expect(try Data(contentsOf: file) == original)
            #expect(try await store.removeLink(id, scope: scope, permit: LocalMediaSavePermit()))
            await store.close()
            #expect(try await store.links(remoteIDs: [id], scope: scope, access: .full).isEmpty)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func rawProgressIsAnonymousMonotonicAndNotSnapshotCompletion() async throws {
        try await withReconciliationStore { store, scope, _ in
            let permit = LocalMediaSavePermit(), replay = try await store.beginMetadataReplay(scope: scope, permit: LocalMediaSavePermit())
            #expect(try await store.recordMetadataProgress(rawRowCount: 64, recognizedEventCount: 0, snapshotID: replay, scope: scope, permit: permit))
            let progress = try await store.progress(scope: scope)
            #expect(progress.rawMetadataRows == 64 && progress.recognizedMetadataEvents == 0 && progress.phase == .readingMetadata)
            #expect(try await store.metadataSnapshot(scope: scope) == nil)
            await #expect(throws: LocalPhotoDisplayReconciliationError.invalidState) {
                _ = try await store.recordMetadataProgress(rawRowCount: 63, recognizedEventCount: 0, snapshotID: replay, scope: scope, permit: permit)
            }
        }
    }
}

@MainActor private func withReconciliationStore(_ body: (LocalPhotoDisplayReconciliationStore, MediaAccountScope, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("display-reconciliation-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = LocalPhotoDisplayReconciliationStore(directory: directory)
    do { try await body(store, displayTestScope(), directory) }
    catch { await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
    await store.close(); try FileManager.default.removeItem(at: directory)
}

private nonisolated func displayTestScope(user: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") -> MediaAccountScope {
    MediaAccountScope(session: .init(apiURL: URL(string: "https://display-store.invalid/api")!, accessToken: "synthetic-token", userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
}

private nonisolated func displayStage(_ id: UUID, _ cloud: String) -> LocalPhotoDisplayIdentityEvent {
    .upsert(assetID: id, key: "remmich-icloud-match", value: Data(#"{"version":1,"method":"icloud-id","iCloudId":"\#(cloud)","byteVerified":false}"#.utf8), ack: "AssetMetadataV1|" + id.uuidString + "-" + cloud)
}

private nonisolated func displayReceipt(_ count: Int) -> LocalPhotoDisplayStreamReceipt {
    .init(completeAck: "SyncCompleteV1|" + UUID().uuidString, rawRowCount: count + 1, recognizedEventCount: count, ignoredMetadataEventCount: 0, batchCount: (count + 63) / 64)
}

private nonisolated func displayLink(_ id: UUID, _ local: String) -> LocalMediaAssociation {
    .init(remoteID: id, remoteRevision: Date(timeIntervalSince1970: 100), localIdentity: .init(localIdentifier: local, modificationDate: Date(timeIntervalSince1970: 50), mediaKind: .image), checksum: Data(repeating: 1, count: 20).base64EncodedString(), source: .exactCloudIdentity)
}

private nonisolated func displayWork(_ local: String, result: LocalPhotoDisplayLocalWork.Result = .matched, reason: LocalPhotoDisplayLocalWork.Reason = .matched) -> LocalPhotoDisplayLocalWork {
    .init(localID: local, cloudID: "cloud-" + local, identityVersion: "synthetic-version", evidenceHash: "synthetic-evidence", result: result, reason: reason)
}

private nonisolated func displayCheckpoint(_ snapshot: LocalPhotoDisplayMetadataSnapshot, total: Int, inventory: String = "inventory") -> LocalPhotoDisplayReconciliationCheckpoint {
    .init(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: inventory, access: .full, photosGeneration: UUID(), totalLocal: total, processedLocal: total, completed: true)
}

private func acceptDisplaySnapshot(_ store: LocalPhotoDisplayReconciliationStore, _ scope: MediaAccountScope, _ events: [LocalPhotoDisplayIdentityEvent]) async throws -> LocalPhotoDisplayMetadataSnapshot {
    let permit = LocalMediaSavePermit(), id = try await store.beginMetadataReplay(scope: scope, permit: LocalMediaSavePermit())
    for start in stride(from: 0, to: events.count, by: 64) {
        guard try await store.stageMetadata(Array(events[start ..< min(start + 64, events.count)]), snapshotID: id, scope: scope, permit: permit) else { throw CancellationError() }
    }
    return try await store.completeMetadataSnapshot(snapshotID: id, receipt: displayReceipt(events.count), scope: scope, permit: permit)
}

private nonisolated func aliasWork(_ local: String, _ cloud: String) -> LocalPhotoDisplayLocalWork {
    .init(localID: local, cloudID: cloud, identityVersion: "synthetic-alias-version", evidenceHash: "synthetic-alias-evidence", result: .matched, reason: .matched)
}

private nonisolated func aliasCheckpoint(_ snapshot: LocalPhotoDisplayMetadataSnapshot, processed: Int, total: Int) -> LocalPhotoDisplayReconciliationCheckpoint {
    .init(snapshotID: snapshot.id, evidenceVersion: snapshot.evidenceVersion, inventoryFingerprint: "alias-inventory", access: .full, photosGeneration: UUID(), totalLocal: total, processedLocal: processed, completed: processed == total)
}

private nonisolated func aliasOriginStage(_ remote: UUID, _ cloud: String) throws -> LocalPhotoDisplayIdentityEvent {
    let metadata = try LocalMediaMobileMetadata(cloudId: cloud, createdAt: nil, adjustmentTime: nil, latitude: nil, longitude: nil)
    let origin = try PhotoBackupOrigin(metadata: metadata, checksum: Data(repeating: 1, count: 20).base64EncodedString())
    return try .upsert(assetID: remote, key: PhotoBackupOrigin.metadataKey(for: cloud), value: JSONEncoder().encode(origin), ack: "AssetMetadataV1|origin-" + remote.uuidString + cloud)
}

private nonisolated func aliasFixtureSQL(_ file: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(database); throw LocalPhotoDisplayReconciliationError.invalidDatabase }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
}

private nonisolated func aliasFixtureVersion(_ file: URL) throws -> Int {
    var database: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(database); throw LocalPhotoDisplayReconciliationError.invalidDatabase }
    defer { sqlite3_close(database) }
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw LocalPhotoDisplayReconciliationError.invalidDatabase }
    return Int(sqlite3_column_int(statement, 0))
}
