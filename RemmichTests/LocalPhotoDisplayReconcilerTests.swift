import Foundation
import Synchronization
import Testing
@testable import Remmich

@Suite("Metadata-only full Photos reconciliation", .serialized)
@MainActor struct LocalPhotoDisplayReconcilerTests {
    @Test func completeDictionaryPrecedesPhotosAndEveryLocalItemHasAnHonestResult() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched", "missing-cloud", "missing-server"])
        defer { fixture.cleanup() }
        fixture.metadata.values["missing-cloud"] = reconciliationPhoto("missing-cloud", cloud: .unavailable)
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        fixture.remote.onBatch = { #expect(fixture.metadata.reads == 0) }
        var committed = 0
        fixture.worker.onLinksCommitted = { links in #expect(links.count <= 64); committed += links.count }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let rows = try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope)
        #expect(rows.count == 3)
        #expect(rows.first { $0.localID == "matched" }?.result == .matched)
        #expect(rows.first { $0.localID == "missing-cloud" }?.reason == .noCloudIdentity)
        #expect(rows.first { $0.localID == "missing-server" }?.reason == .noServerIdentity)
        #expect(fixture.worker.progress.processedLocal == 3 && fixture.worker.progress.matchedLocal == 1)
        #expect(fixture.worker.state == .needsReview && committed == 1)
        #expect(fixture.inventory.authorizationRequests == 0)
    }

    @Test func unrelatedMetadataChangeDoesNotReverifyStableMatchedLocalItem() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .completed && fixture.remote.assetReads == 1)
        let first = try #require(try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope).first)
        fixture.remote.events.append(reconciliationMarker(UUID(), cloud: "unrelated-cloud"))
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let second = try #require(try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope).first)
        #expect(first == second && fixture.remote.assetReads == 1)
        #expect(fixture.worker.progress.matchedLocal == 1 && fixture.worker.state == .completed)
        #expect(try await fixture.store.links(remoteIDs: [fixture.assetID], scope: fixture.scope, access: .full).count == 1)
    }

    @Test func resumedInventoryNeverDropsPersistedProcessedCountAtTheFirstBatch() async throws {
        let ids = (0 ..< 129).map { "local-\($0)" }
        let fixture = try ReconciliationFixture(ids: ids)
        defer { fixture.cleanup() }
        let pairs = ids.map { ($0, UUID()) }
        fixture.remote.events = pairs.map { reconciliationMarker($0.1, cloud: "cloud-" + $0.0) }
        fixture.remote.assets = pairs.map { reconciliationAsset($0.1) }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.progress.processedLocal == ids.count && fixture.worker.progress.matchedLocal == ids.count)
        let reverse = Dictionary(uniqueKeysWithValues: ids.map { ("cloud-" + $0, $0) })
        let resumed = LocalPhotoDisplayReconciler(inventory: fixture.inventory, metadata: fixture.metadata,
                                                  reverseCloudIDs: { clouds in reverse.filter { clouds.contains($0.key) } },
                                                  store: fixture.store, diagnosticsURL: fixture.directory.appendingPathComponent("resumed-diagnostics.json"), idleTimer: fixture.idleTimer,
                                                  retryDelay: { _ in try Task.checkCancellation() })
        var observed: [Int] = []
        fixture.metadata.onRead = { observed.append(resumed.progress.processedLocal) }
        fixture.remote.onBatch = {
            #expect(resumed.progress.processedLocal == ids.count)
            #expect(resumed.progress.matchedLocal == ids.count)
        }
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(observed.count == 6 && observed.allSatisfy { $0 == ids.count })
        #expect(resumed.progress.matchedLocal == ids.count && resumed.state == .completed)
    }

    @Test func resumeSkipsAll129VerifiedIdentitiesWithoutPhotosMetadataOrCloudReads() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        _ = fixture.matchAllIDs()
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let metadataReads = fixture.metadata.reads, assetReads = fixture.remote.assetReads
        let cloud = ReconciliationCloudProbe(ids: fixture.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        #expect(fixture.metadata.reads == metadataReads && cloud.reads == 0 && fixture.remote.assetReads == assetReads)
        #expect(resumed.progress.matchedLocal == 129 && resumed.progress.processedLocal == 129 && resumed.state == .completed)
        #expect(try await fixture.store.checkpoint(scope: fixture.scope)?.completed == true)
        #if DEBUG
            let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("resumed-diagnostics.json"))
            let diagnostic = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(diagnostic["todoTotal"] as? Int == 0 && diagnostic["checkedThisRun"] as? Int == 0)
        #endif
    }

    @Test func resumeRechecksOnlyTheOneUnfinishedLocalIdentity() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        _ = fixture.matchAllIDs()
        let failed = fixture.ids[0]
        fixture.metadata.values[failed] = reconciliationPhoto(failed, cloud: .unavailable)
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.progress.matchedLocal == 128 && fixture.worker.progress.pendingLocal == 1)
        fixture.metadata.values[failed] = reconciliationPhoto(failed)
        let requestCount = fixture.metadata.requests.count
        let cloud = ReconciliationCloudProbe(ids: fixture.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        #expect(Array(fixture.metadata.requests.dropFirst(requestCount)) == [[failed], [failed]])
        #expect(cloud.reads == 1 && resumed.progress.matchedLocal == 129 && resumed.state == .completed)
    }

    @Test func acceptedServerEvidenceChangeRechecksOnlyItsAffectedIdentity() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        let ids = fixture.matchAllIDs()
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let changed = fixture.ids[0], remoteID = try #require(ids[changed])
        let marker = reconciliationMarker(remoteID, cloud: "cloud-" + changed)
        guard case let .upsert(id, key, bytes, _) = marker else { Issue.record("Synthetic marker must be an upsert"); return }
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["evidenceRevision"] = 2
        fixture.remote.events = try fixture.remote.events.filter { $0.assetID != remoteID } + [
            .upsert(assetID: id, key: key, value: JSONSerialization.data(withJSONObject: object), ack: reconciliationAck()),
        ]
        let requestCount = fixture.metadata.requests.count, assetReads = fixture.remote.assetReads
        let cloud = ReconciliationCloudProbe(ids: fixture.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        #expect(Array(fixture.metadata.requests.dropFirst(requestCount)) == [[changed], [changed]])
        #expect(cloud.reads == 1 && fixture.remote.assetReads == assetReads + 1)
        #expect(resumed.progress.matchedLocal == 129 && resumed.state == .completed)
    }

    @Test(arguments: ["inventory", "access"])
    func inventoryDeltaReadsOnlyNewItemsButAccessChangesRevalidateAll(_ change: String) async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        if change == "inventory" {
            fixture.inventory.ids.append("new")
            fixture.metadata.values["new"] = reconciliationPhoto("new")
            let id = UUID()
            fixture.remote.events.append(reconciliationMarker(id, cloud: "cloud-new"))
            fixture.remote.assets.append(reconciliationAsset(id))
        } else {
            fixture.inventory.authorization = .limited
        }
        let requestCount = fixture.metadata.requests.count
        let cloud = ReconciliationCloudProbe(ids: fixture.inventory.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        let requests = Array(fixture.metadata.requests.dropFirst(requestCount))
        let expectedIDs = change == "inventory" ? Set(["new"]) : Set(fixture.inventory.ids)
        #expect(requests.count == 2 && requests.allSatisfy { Set($0) == expectedIDs })
        #expect(cloud.reads == 1 && resumed.progress.matchedLocal == fixture.inventory.ids.count)
    }

    @Test func addingThreePhotosRebases129ProofsAndOnlyReadsTheThreeNewItems() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        _ = fixture.matchAllIDs()
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let added = ["added-a", "added-b", "added-c"]
        addReconciliationPhotos(added, to: fixture)
        let requestCount = fixture.metadata.requests.count, assetReads = fixture.remote.assetReads
        let cloud = ReconciliationCloudProbe(ids: fixture.inventory.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        let requests = Array(fixture.metadata.requests.dropFirst(requestCount))
        #expect(requests.count == 2 && requests.allSatisfy { Set($0) == Set(added) })
        #expect(cloud.reads == 1 && fixture.remote.assetReads == assetReads + 1)
        #expect(resumed.progress.totalLocal == 132 && resumed.progress.processedLocal == 132)
        #expect(resumed.progress.matchedLocal == 132 && resumed.state == .completed)
        #expect(try await fixture.store.verifiedLocalIDs(scope: fixture.scope, access: .full) == Set(fixture.inventory.ids))
        #if DEBUG
            let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("resumed-diagnostics.json"))
            let diagnostic = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(diagnostic["todoTotal"] as? Int == 3 && diagnostic["checkedThisRun"] as? Int == 3)
        #endif
    }

    @Test func deletingPhotosDoesNotRereadThe126RemainingProvenIdentities() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        _ = fixture.matchAllIDs()
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        fixture.inventory.ids = Array(fixture.ids.dropLast(3))
        let requestCount = fixture.metadata.requests.count, assetReads = fixture.remote.assetReads
        let cloud = ReconciliationCloudProbe(ids: fixture.inventory.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        #expect(fixture.metadata.requests.count == requestCount && cloud.reads == 0 && fixture.remote.assetReads == assetReads)
        #expect(resumed.progress.totalLocal == 126 && resumed.progress.processedLocal == 126)
        #expect(resumed.progress.matchedLocal == 126 && resumed.state == .completed)
        #expect(try await fixture.store.verifiedLocalIDs(scope: fixture.scope, access: .full) == Set(fixture.inventory.ids))
    }

    @Test func interruptedRebaseRecoversMatchedRowsFromBothInventoryGenerations() async throws {
        let fixture = try ReconciliationFixture(ids: (0 ..< 129).map { "photo-\($0)" })
        defer { fixture.cleanup() }
        _ = fixture.matchAllIDs()
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let added = ["added-a", "added-b", "added-c"]
        addReconciliationPhotos(added, to: fixture)
        let requestCount = fixture.metadata.requests.count
        let firstCloud = ReconciliationCloudProbe(ids: fixture.inventory.ids)
        let interrupted = fixture.makeWorker(cloud: firstCloud)
        try await #require(interrupted.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {
            if interrupted.progress.phase == .matching, interrupted.progress.processedLocal == 64 {
                throw CancellationError()
            }
        })).value
        #expect(interrupted.state == .paused && fixture.metadata.requests.count == requestCount && firstCloud.reads == 0)
        #expect(try await fixture.store.verifiedLocalIDs(scope: fixture.scope, access: .full).count == 64)
        #expect(try await fixture.store.reusableLocalIDs(scope: fixture.scope, access: .full).count == 129)
        #expect(try await fixture.store.checkpoint(scope: fixture.scope)?.processedLocal == 64)
        let cloud = ReconciliationCloudProbe(ids: fixture.inventory.ids)
        let resumed = fixture.makeWorker(cloud: cloud)
        var processedDuringNativeReads: [Int] = []
        fixture.metadata.onRead = { processedDuringNativeReads.append(resumed.progress.processedLocal) }
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, mode: .resumePersistedIdentities, validateContext: {})).value
        let requests = Array(fixture.metadata.requests.dropFirst(requestCount))
        #expect(requests.count == 2 && requests.allSatisfy { Set($0) == Set(added) })
        #expect(processedDuringNativeReads.allSatisfy { $0 >= 129 })
        #expect(cloud.reads == 1 && resumed.progress.matchedLocal == 132 && resumed.progress.processedLocal == 132)
        #expect(resumed.state == .completed)
        #expect(try await fixture.store.verifiedLocalIDs(scope: fixture.scope, access: .full) == Set(fixture.inventory.ids))
    }

    @Test(arguments: [false, true], ["pause", "cancel"])
    func idleLeaseRestoresItsOriginalSettingBeforeNativeRequestRetires(_ originallyDisabled: Bool, _ stop: String) async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.idleTimer.isIdleTimerDisabled = originallyDisabled
        fixture.idleTimer.writes = []
        fixture.metadata.holdFirstRead = true
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        let proposed = fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})
        let operation = try #require(proposed)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.metadata.continuation == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let continuation = fixture.metadata.continuation else {
            fixture.worker.pause(); await operation.value
            Issue.record("The synthetic Photos request did not reach its gate"); return
        }
        #expect(fixture.idleTimer.isIdleTimerDisabled)
        if stop == "pause" {
            fixture.worker.pause()
        } else {
            operation.cancel()
        }
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while fixture.idleTimer.writes.count < 2, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.idleTimer.isIdleTimerDisabled == originallyDisabled && fixture.idleTimer.writes == [true, originallyDisabled])
        fixture.metadata.continuation = nil; continuation.resume()
        await operation.value
        #expect(fixture.idleTimer.isIdleTimerDisabled == originallyDisabled && fixture.idleTimer.writes.count == 2)
    }

    @Test(arguments: [false, true])
    func independentlyVerifiedAliasesShareOneRemoteAcrossBatchesAndColdResume(_ split: Bool) async throws {
        let first = "alias-000", second = "alias-999"
        let fillers = split ? (0 ..< 63).map { "alias-100-\($0)" } : []
        let fixture = try ReconciliationFixture(ids: [first] + fillers + [second])
        defer { fixture.cleanup() }
        fixture.remote.events = try [reconciliationOfficial(fixture.assetID, cloud: "cloud-" + first),
                                     reconciliationOrigin(fixture.assetID, cloud: "cloud-" + second),
                                     reconciliationMarker(fixture.assetID, cloud: "cloud-" + second)]
        var displayed: [LocalMediaAssociation] = []
        fixture.worker.onLinksCommitted = { links in
            #expect(Set(links.map(\.remoteID)).count == links.count)
            displayed.append(contentsOf: links)
        }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let aliases = try await fixture.store.aliasLinks(localIDs: [first, second], scope: fixture.scope, access: .full)
        #expect(aliases.count == 2 && Set(aliases.map(\.remoteID)) == [fixture.assetID])
        #expect(Set(aliases.map(\.localIdentity.localIdentifier)) == [first, second])
        #expect(fixture.worker.progress.matchedLocal == 2 && fixture.worker.progress.associationCount == 1)
        #expect(try await fixture.store.distinctLocalCount(scope: fixture.scope, access: .full) == 2)
        let selected = try await fixture.store.links(remoteIDs: [fixture.assetID], scope: fixture.scope, access: .full)
        #expect(selected.count == 1 && !displayed.isEmpty)
        #expect(displayed.allSatisfy { $0 == selected.first })
        let reads = fixture.remote.assetReads
        let reverse = Dictionary(uniqueKeysWithValues: fixture.ids.map { ("cloud-" + $0, $0) })
        let resumed = LocalPhotoDisplayReconciler(inventory: fixture.inventory, metadata: fixture.metadata,
                                                  reverseCloudIDs: { clouds in reverse.filter { clouds.contains($0.key) } },
                                                  store: fixture.store, diagnosticsURL: nil, idleTimer: fixture.idleTimer,
                                                  retryDelay: { _ in try Task.checkCancellation() })
        try await #require(resumed.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(resumed.progress.matchedLocal == 2 && resumed.progress.associationCount == 1)
        #expect(fixture.remote.assetReads == reads)
        #expect(resumed.state == (split ? .needsReview : .completed))
    }

    @Test func changingOneLocalAliasVersionDoesNotRemoveTheOtherProof() async throws {
        let first = "alias-a", second = "alias-b"
        let fixture = try ReconciliationFixture(ids: [first, second])
        defer { fixture.cleanup() }
        fixture.remote.events = try [reconciliationOfficial(fixture.assetID, cloud: "cloud-" + first),
                                     reconciliationOrigin(fixture.assetID, cloud: "cloud-" + second)]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let original = try #require(try await fixture.store.aliasLinks(localIDs: [first], scope: fixture.scope, access: .full).first)
        fixture.metadata.values[second] = reconciliationPhoto(second, modified: 99)
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let aliases = try await fixture.store.aliasLinks(localIDs: [first, second], scope: fixture.scope, access: .full)
        #expect(aliases.first { $0.localIdentity.localIdentifier == first } == original)
        #expect(aliases.first { $0.localIdentity.localIdentifier == second }?.localIdentity.modificationDate == Date(timeIntervalSince1970: 99))
        #expect(fixture.worker.progress.matchedLocal == 2 && fixture.worker.progress.associationCount == 1)
    }

    @Test(arguments: ["checksum", "malformed", "key", "unexplained-marker", "unknown-origin"])
    func unprovenAliasesStayPendingWithoutInventingLocalMatches(_ failure: String) async throws {
        let first = "alias-a", second = "alias-b"
        let fixture = try ReconciliationFixture(ids: [first, second])
        defer { fixture.cleanup() }
        var events = try [reconciliationOfficial(fixture.assetID, cloud: "cloud-" + first)]
        if failure == "unexplained-marker" {
            events.append(reconciliationMarker(fixture.assetID, cloud: "cloud-" + second))
        } else if failure == "unknown-origin" {
            events.append(.upsert(assetID: fixture.assetID, key: PhotoBackupOrigin.metadataKey(for: "unknown"),
                                  value: Data(#"{"unexpected":true}"#.utf8), ack: reconciliationAck()))
        } else {
            var origin = try reconciliationOrigin(fixture.assetID, cloud: "cloud-" + second,
                                                  checksum: failure == "checksum" ? Data(repeating: 2, count: 20).base64EncodedString() : nil)
            if case let .upsert(id, key, bytes, ack) = origin {
                var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                if failure == "malformed" {
                    object["byteVerified"] = false
                }
                origin = try .upsert(assetID: id, key: failure == "key" ? PhotoBackupOrigin.metadataKey(for: "wrong-cloud") : key,
                                     value: JSONSerialization.data(withJSONObject: object), ack: ack)
            }
            events.append(origin)
        }
        fixture.remote.events = events
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let rows = try await fixture.store.localWork(localIDs: [first, second], scope: fixture.scope)
        #expect(rows.first { $0.localID == second }?.result != .matched)
        if failure != "unknown-origin" {
            #expect(rows.first { $0.localID == second }?.result == .pending)
        }
        if failure == "unexplained-marker" || failure == "unknown-origin" {
            #expect(fixture.worker.progress.matchedLocal == 0)
            #expect(rows.first { $0.localID == first }?.result == .pending)
        } else {
            #expect(rows.first { $0.localID == first }?.result == .matched)
            #expect(fixture.worker.progress.matchedLocal == 1)
        }
        #expect(fixture.worker.state == .needsReview)
    }

    #if DEBUG
        @Test func debugDiagnosticsContainOnlyAnonymousAggregateEvidence() async throws {
            let fixture = try ReconciliationFixture(ids: ["matched"])
            defer { fixture.cleanup() }
            fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
            try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
            let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("diagnostics.json"))
            let value = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let allowed = Set(["version", "recordedAt", "phase", "state", "running", "total", "processed", "matched", "unmatched", "pending", "rawMetadataRows", "associationCount", "lastError", "sourceChangeEvents", "todoTotal", "checkedThisRun"])
            #expect(Set(value.keys).isSubset(of: allowed))
            #expect(value["state"] as? String == "completed" && value["running"] as? Bool == false)
            #expect(value["matched"] as? Int == 1 && value["processed"] as? Int == 1)
            #expect(value["todoTotal"] as? Int == 1 && value["checkedThisRun"] as? Int == 1)
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains("cloud-matched") && !text.contains(fixture.assetID.uuidString) && !text.contains("reconciliation.invalid"))
        }
    #endif

    @Test func lateConflictingKeyCannotPublishAnEarlyMarkerMatch() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        let value = Data(#"{"iCloudId":"other-cloud"}"#.utf8)
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched"),
                                 .upsert(assetID: fixture.assetID, key: "mobile-app", value: value, ack: reconciliationAck())]
        fixture.remote.onBatch = { #expect(fixture.metadata.reads == 0) }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let row = try #require(try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope).first)
        #expect(row.result == .pending && row.reason == .conflictingMetadata)
        #expect(fixture.worker.state == .needsReview)
        #expect(try await fixture.store.links(remoteIDs: [fixture.assetID], scope: fixture.scope, access: .full).isEmpty)
    }

    @Test func sustained5xxRetriesEventuallyRecoverWithoutClearingCompletedProgress() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        fixture.remote.failures = [500, 502, 503, 504, 507, 599, 500].map { LibraryWriteError.http($0) }
        fixture.remote.onBatch = {
            #expect(fixture.worker.progress.matchedLocal == 1 && fixture.worker.progress.processedLocal == 1)
        }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .completed && fixture.remote.streamReads == 9)
        #expect(fixture.worker.lastError == nil)
        #expect(fixture.worker.progress.matchedLocal == 1 && fixture.worker.progress.processedLocal == 1)
        #expect(try await fixture.store.links(remoteIDs: [fixture.assetID], scope: fixture.scope, access: .full).count == 1)
    }

    @Test func freshAssetReadsRetryOnlyTheCurrentBatchAfterSustained5xx() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        fixture.remote.assetFailures = [500, 502, 503, 504, 599].map { LibraryWriteError.http($0) }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .completed && fixture.remote.streamReads == 1)
        #expect(fixture.remote.assetReads == 6 && fixture.worker.progress.matchedLocal == 1)
    }

    @Test func pauseCancelsAnAutomaticRetryWaitWithoutStartingAnotherRead() async throws {
        let gate = ReconciliationRetryGate()
        let fixture = try ReconciliationFixture(ids: ["matched"], retryDelay: { _ in try await gate.wait() })
        defer { fixture.cleanup() }
        fixture.remote.failures = [LibraryWriteError.http(503)]
        let proposed = fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})
        let operation = try #require(proposed)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var entered = await gate.entered
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            entered = await gate.entered
        }
        guard entered else {
            fixture.worker.pause(); await operation.value
            Issue.record("The synthetic retry delay did not reach its cancellation gate.")
            return
        }
        #expect(fixture.worker.state == .waiting && fixture.worker.running)
        fixture.worker.pause()
        await operation.value
        #expect(fixture.worker.state == .paused && !fixture.worker.running)
        #expect(fixture.remote.streamReads == 1 && fixture.metadata.reads == 0)
    }

    @Test(arguments: [401, 403])
    func permissionsDoNotEnterTheAutomaticRetryLoop(_ status: Int) async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.failures = [LibraryWriteError.http(status)]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .blocked && fixture.remote.streamReads == 1)
        #expect(fixture.metadata.reads == 0)
    }

    @Test func metadataCheckpointErrorIsImmediatelyVisibleWithoutRetriesOrPhotos() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.failures = [LocalPhotoDisplayIdentityStreamError.metadataCheckpointExists]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .blocked && fixture.worker.lastError != nil)
        #expect(fixture.remote.streamReads == 1 && fixture.metadata.reads == 0)
    }

    @Test func changedPhotosVersionIsRecheckedBeforePublishingTheCurrentLink() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        fixture.remote.onAssets = {
            fixture.metadata.values["matched"] = reconciliationPhoto("matched", modified: 99)
        }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let row = try #require(try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope).first)
        #expect(row.result == .matched && fixture.worker.progress.matchedLocal == 1)
        let links = try await fixture.store.aliasLinks(localIDs: fixture.ids, scope: fixture.scope, access: .full)
        #expect(links.first?.localIdentity.modificationDate == Date(timeIntervalSince1970: 99))
        #expect(fixture.remote.assetReads == 2)
    }

    @Test func oneTransientReaderBatchChangeDoesNotPermanentlyMarkTheBatchPending() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.metadata.sourceChangedReads = 1
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.progress.matchedLocal == 1 && fixture.worker.progress.pendingLocal == 0)
        #expect(fixture.metadata.reads == 3 && fixture.remote.assetReads == 1)
    }

    @Test func onePersistentlyChangingPhotoDoesNotDemoteItsSixtyThreeStableSiblings() async throws {
        let ids = (0 ..< 64).map { "photo-\($0)" }
        let fixture = try ReconciliationFixture(ids: ids)
        defer { fixture.cleanup() }
        let pairs = ids.map { ($0, UUID()) }
        fixture.remote.events = pairs.map { reconciliationMarker($0.1, cloud: "cloud-" + $0.0) }
        fixture.remote.assets = pairs.map { reconciliationAsset($0.1) }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let original = try await fixture.store.aliasLinks(localIDs: ids, scope: fixture.scope, access: .full)
        let reads = fixture.remote.assetReads
        let metadataReads = fixture.metadata.reads
        let changing = ids[0]
        fixture.metadata.unstableIDs = [changing]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let rows = try await fixture.store.localWork(localIDs: ids, scope: fixture.scope)
        let current = try await fixture.store.aliasLinks(localIDs: ids, scope: fixture.scope, access: .full)
        #expect(fixture.worker.progress.matchedLocal == 63 && fixture.worker.progress.pendingLocal == 1)
        #expect(rows.first { $0.localID == changing }?.reason == .sourceChanged)
        #expect(rows.filter { $0.reason == .sourceChanged }.count == 1)
        #expect(current.count == 63)
        #expect(current.allSatisfy { original.contains($0) })
        #expect(fixture.remote.assetReads == reads)
        #expect(fixture.metadata.reads - metadataReads <= 512)
    }

    @Test func continuouslyDriftingSingleItemIsBoundedAndNeverPublishedAsMatched() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        fixture.remote.onAssets = {
            let modified = (fixture.metadata.values["matched"]?.identity.modificationDate?.timeIntervalSince1970 ?? 20) + 1
            fixture.metadata.values["matched"] = reconciliationPhoto("matched", modified: modified)
        }
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        let row = try #require(try await fixture.store.localWork(localIDs: fixture.ids, scope: fixture.scope).first)
        #expect(row.reason == .sourceChanged && fixture.worker.progress.matchedLocal == 0)
        #expect(fixture.remote.assetReads == 3 && fixture.metadata.reads == 6)
        #expect(try await fixture.store.aliasLinks(localIDs: fixture.ids, scope: fixture.scope, access: .full).isEmpty)
    }

    @Test func pauseDuringSourceChangeRecoveryCancelsBeforeAnotherAttempt() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.metadata.sourceChangedReads = 2
        fixture.metadata.onRead = {
            if fixture.metadata.reads == 2 {
                fixture.worker.pause()
            }
        }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .paused && fixture.metadata.reads == 2)
        #expect(fixture.remote.assetReads == 0 && fixture.worker.progress.matchedLocal == 0)
    }

    #if DEBUG
        @Test func stableMissingSnapshotsAreDiagnosedSeparatelyFromVersionChanges() async throws {
            let fixture = try ReconciliationFixture(ids: ["matched"])
            defer { fixture.cleanup() }
            fixture.metadata.values.removeValue(forKey: "matched")
            fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
            try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
            let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("diagnostics.json"))
            let value = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let events = try #require(value["sourceChangeEvents"] as? [String: Int])
            #expect(events["missingSnapshot"] == 3)
            #expect(events["readerBatchUnstable"] == 0 && events["itemSnapshotDrift"] == 0 && events["cloudMappingDrift"] == 0)
            #expect(fixture.worker.progress.pendingLocal == 1 && fixture.remote.assetReads == 0)
        }
    #endif

    @Test(arguments: ["owner", "type", "trash", "checksum", "version"])
    func freshRemoteRejectionCannotPublishDisplayIdentity(_ mode: String) async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        fixture.remote.assets = [.init(id: fixture.assetID, ownerId: mode == "owner" ? UUID() : reconciliationOwner,
                                       type: mode == "type" ? "VIDEO" : "IMAGE", isTrashed: mode == "trash",
                                       isOffline: false, isEdited: false,
                                       checksum: mode == "checksum" ? "invalid" : Data(repeating: 1, count: 20).base64EncodedString(),
                                       updatedAt: mode == "version" ? nil : Date(timeIntervalSince1970: 30))]
        try await #require(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})).value
        #expect(fixture.worker.state == .needsReview && fixture.worker.progress.matchedLocal == 0)
        #expect(try await fixture.store.links(remoteIDs: [fixture.assetID], scope: fixture.scope, access: .full).isEmpty)
    }

    @Test func pauseWaitsForNativeMetadataRetirementBeforeAnotherWorkerCanStart() async throws {
        let fixture = try ReconciliationFixture(ids: ["matched"])
        defer { fixture.cleanup() }
        fixture.metadata.holdFirstRead = true
        fixture.remote.events = [reconciliationMarker(fixture.assetID, cloud: "cloud-matched")]
        let proposed = fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {})
        let operation = try #require(proposed)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.metadata.continuation == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let continuation = fixture.metadata.continuation else {
            fixture.worker.pause(); await operation.value
            Issue.record("The synthetic native metadata read did not reach its gate.")
            return
        }
        fixture.worker.pause()
        #expect(fixture.worker.run(scope: fixture.scope, remote: fixture.remote, validateContext: {}) == nil)
        let retirement = Task { await fixture.worker.waitForRetirement() }
        fixture.metadata.continuation = nil
        continuation.resume()
        await retirement.value
        await operation.value
        #expect(!fixture.worker.running && fixture.worker.state == .paused)
        #expect(fixture.remote.assetReads == 0)
    }
}

@MainActor private final class ReconciliationFixture {
    let directory: URL
    let scope: MediaAccountScope
    let assetID = UUID()
    let ids: [String]
    let inventory: ReconciliationInventory
    let metadata: ReconciliationMetadata
    let remote: ReconciliationRemote
    let store: LocalPhotoDisplayReconciliationStore
    let idleTimer = ReconciliationIdleTimer()
    let worker: LocalPhotoDisplayReconciler

    init(ids: [String], retryDelay: @escaping LocalPhotoDisplayReconciler.RetryDelay = { _ in try Task.checkCancellation() }) throws {
        self.ids = ids
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("display-worker-" + UUID().uuidString, isDirectory: true)
        scope = MediaAccountScope(session: .init(apiURL: URL(string: "https://reconciliation.invalid/api")!, accessToken: "synthetic-no-network",
                                                 userID: reconciliationOwner.uuidString, userEmail: "synthetic@example.invalid", name: "Synthetic",
                                                 isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
        inventory = ReconciliationInventory(ids: ids)
        metadata = ReconciliationMetadata(values: Dictionary(uniqueKeysWithValues: ids.map { ($0, reconciliationPhoto($0)) }))
        remote = ReconciliationRemote(assets: [reconciliationAsset(assetID)])
        store = LocalPhotoDisplayReconciliationStore(directory: directory)
        let reverse = Dictionary(uniqueKeysWithValues: ids.map { ("cloud-" + $0, $0) })
        worker = LocalPhotoDisplayReconciler(inventory: inventory, metadata: metadata,
                                             reverseCloudIDs: { clouds in reverse.filter { clouds.contains($0.key) } },
                                             store: store, diagnosticsURL: directory.appendingPathComponent("diagnostics.json"),
                                             idleTimer: idleTimer, retryDelay: retryDelay)
    }

    func matchAllIDs() -> [String: UUID] {
        let pairs = ids.map { ($0, UUID()) }
        remote.events = pairs.map { reconciliationMarker($0.1, cloud: "cloud-" + $0.0) }
        remote.assets = pairs.map { reconciliationAsset($0.1) }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    func makeWorker(cloud: ReconciliationCloudProbe) -> LocalPhotoDisplayReconciler {
        LocalPhotoDisplayReconciler(inventory: inventory, metadata: metadata, reverseCloudIDs: { cloud.resolve($0) },
                                    store: store, diagnosticsURL: directory.appendingPathComponent("resumed-diagnostics.json"), idleTimer: idleTimer,
                                    retryDelay: { _ in try Task.checkCancellation() })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func addReconciliationPhotos(_ localIDs: [String], to fixture: ReconciliationFixture) {
    fixture.inventory.ids.append(contentsOf: localIDs)
    for localID in localIDs {
        fixture.metadata.values[localID] = reconciliationPhoto(localID)
        let remoteID = UUID()
        fixture.remote.events.append(reconciliationMarker(remoteID, cloud: "cloud-" + localID))
        fixture.remote.assets.append(reconciliationAsset(remoteID))
    }
}

@MainActor private final class ReconciliationIdleTimer: LocalPhotoReconciliationIdleTiming {
    var writes: [Bool] = []
    var isIdleTimerDisabled = false {
        didSet { writes.append(isIdleTimerDisabled) }
    }
}

private final nonisolated class ReconciliationCloudProbe: Sendable {
    private let count = Mutex(0)
    private let mapping: [String: String]
    init(ids: [String]) {
        mapping = Dictionary(uniqueKeysWithValues: ids.map { ("cloud-" + $0, $0) })
    }

    var reads: Int {
        count.withLock { $0 }
    }

    func resolve(_ ids: Set<String>) -> [String: String] {
        count.withLock { $0 += 1 }
        return mapping.filter { ids.contains($0.key) }
    }
}

@MainActor private final class ReconciliationInventory: LocalPhotoInventoryReading {
    var ids: [String]
    var authorization = LocalPhotoLibraryAccess.full
    private(set) var authorizationRequests = 0
    init(ids: [String]) {
        self.ids = ids
    }

    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorizationRequests += 1; return authorization
    }

    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return ids
    }
}

@MainActor private final class ReconciliationMetadata: LocalPhotoMetadataReading {
    var values: [String: LocalPhotoSnapshot]
    private(set) var reads = 0
    private(set) var requests: [[String]] = []
    var holdFirstRead = false
    var sourceChangedReads = 0
    var unstableIDs = Set<String>()
    var continuation: CheckedContinuation<Void, Never>?
    var onRead: (@MainActor () -> Void)?
    init(values: [String: LocalPhotoSnapshot]) {
        self.values = values
    }

    func snapshots(for ids: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext(); reads += 1
        requests.append(ids)
        onRead?()
        #expect(ids.count <= 64)
        try validateContext()
        if sourceChangedReads > 0 {
            sourceChangedReads -= 1
            throw LocalMediaMetadataError.sourceChanged
        }
        if !unstableIDs.isDisjoint(with: ids) {
            throw LocalMediaMetadataError.sourceChanged
        }
        if holdFirstRead, reads == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        try validateContext()
        return ids.compactMap { values[$0] }
    }
}

private final nonisolated class ReconciliationRemote: LocalPhotoDisplayReconciliationRemote {
    private nonisolated struct State: Sendable {
        var events: [LocalPhotoDisplayIdentityEvent] = []
        var failures: [any Error] = []
        var assetFailures: [any Error] = []
        var assets: [LocalMediaRemoteAsset]
        var streamReads = 0
        var assetReads = 0
        var onBatch: (@MainActor @Sendable () -> Void)?
        var onAssets: (@MainActor @Sendable () -> Void)?
    }

    private let state: Mutex<State>
    var events: [LocalPhotoDisplayIdentityEvent] {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    var failures: [any Error] {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }

    var assetFailures: [any Error] {
        get { state.withLock { $0.assetFailures } }
        set { state.withLock { $0.assetFailures = newValue } }
    }

    var assets: [LocalMediaRemoteAsset] {
        get { state.withLock { $0.assets } }
        set { state.withLock { $0.assets = newValue } }
    }

    var streamReads: Int {
        state.withLock { $0.streamReads }
    }

    var assetReads: Int {
        state.withLock { $0.assetReads }
    }

    var onBatch: (@MainActor @Sendable () -> Void)? {
        get { state.withLock { $0.onBatch } }
        set { state.withLock { $0.onBatch = newValue } }
    }

    var onAssets: (@MainActor @Sendable () -> Void)? {
        get { state.withLock { $0.onAssets } }
        set { state.withLock { $0.onAssets = newValue } }
    }

    init(assets: [LocalMediaRemoteAsset]) {
        state = Mutex(State(assets: assets))
    }

    func streamPhotoDisplayIdentities(onBatch sink: @Sendable ([LocalPhotoDisplayIdentityEvent]) async throws -> Void) async throws -> LocalPhotoDisplayStreamReceipt {
        let (events, failure, callback) = state.withLock { state in
            state.streamReads += 1
            let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
            return (state.events, failure, state.onBatch)
        }
        if let failure {
            throw failure
        }
        for event in events {
            try await sink([event])
            await callback?()
        }
        return .init(completeAck: "SyncCompleteV1|" + UUID().uuidString, rawRowCount: events.count + 1,
                     recognizedEventCount: events.count, ignoredMetadataEventCount: 0, batchCount: events.count)
    }

    func localMediaAssets(_ ids: [UUID]) async throws -> [LocalMediaRemoteAsset] {
        #expect(ids.count <= 64)
        let (failure, callback) = state.withLock { state in
            state.assetReads += 1
            let failure = state.assetFailures.isEmpty ? nil : state.assetFailures.removeFirst()
            return (failure, state.onAssets)
        }
        if let failure {
            throw failure
        }
        await callback?()
        return state.withLock { $0.assets.filter { ids.contains($0.id) } }
    }
}

private actor ReconciliationRetryGate {
    private(set) var entered = false
    func wait() async throws {
        entered = true
        try await Task.sleep(for: .seconds(30))
    }
}

private nonisolated let reconciliationOwner = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!

private nonisolated func reconciliationAck() -> String {
    "AssetMetadataV1|" + UUID().uuidString
}

private nonisolated func reconciliationMarker(_ id: UUID, cloud: String) -> LocalPhotoDisplayIdentityEvent {
    let value = try! JSONSerialization.data(withJSONObject: ["version": 1, "method": "icloud-id", "iCloudId": cloud, "byteVerified": false], options: [.sortedKeys])
    return .upsert(assetID: id, key: LocalMediaDisplayCloudIdentity.metadataKey, value: value, ack: reconciliationAck())
}

private nonisolated func reconciliationOfficial(_ id: UUID, cloud: String) throws -> LocalPhotoDisplayIdentityEvent {
    let metadata = try LocalMediaMobileMetadata(cloudId: cloud, createdAt: Date(timeIntervalSince1970: 10),
                                                adjustmentTime: nil, latitude: nil, longitude: nil)
    return try .upsert(assetID: id, key: "mobile-app", value: JSONEncoder().encode(metadata), ack: reconciliationAck())
}

private nonisolated func reconciliationOrigin(_ id: UUID, cloud: String, checksum: String? = nil) throws -> LocalPhotoDisplayIdentityEvent {
    let metadata = try LocalMediaMobileMetadata(cloudId: cloud, createdAt: Date(timeIntervalSince1970: 10),
                                                adjustmentTime: nil, latitude: nil, longitude: nil)
    let origin = try PhotoBackupOrigin(metadata: metadata, checksum: checksum ?? Data(repeating: 1, count: 20).base64EncodedString())
    return try .upsert(assetID: id, key: PhotoBackupOrigin.metadataKey(for: cloud), value: JSONEncoder().encode(origin), ack: reconciliationAck())
}

private nonisolated func reconciliationPhoto(_ id: String, modified: TimeInterval = 20,
                                             cloud: LocalPhotoCloudIdentity? = nil) -> LocalPhotoSnapshot
{
    .init(identity: .init(localIdentifier: id, modificationDate: Date(timeIntervalSince1970: modified), mediaKind: .image),
          creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false,
          latitude: nil, longitude: nil, pixelWidth: 64, pixelHeight: 48, duration: 0, mediaSubtypes: 0,
          resources: [], cloudIdentity: cloud ?? .resolved("cloud-" + id))
}

private nonisolated func reconciliationAsset(_ id: UUID) -> LocalMediaRemoteAsset {
    .init(id: id, ownerId: reconciliationOwner, type: "IMAGE", isTrashed: false, isOffline: false, isEdited: false,
          checksum: Data(repeating: 1, count: 20).base64EncodedString(), updatedAt: Date(timeIntervalSince1970: 30))
}
