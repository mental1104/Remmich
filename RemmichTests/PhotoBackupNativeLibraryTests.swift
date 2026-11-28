import Foundation
import Photos
import Synchronization
import Testing
@testable import Remmich

@Suite("Native full-library backup source")
@MainActor struct PhotoBackupNativeLibraryTests {
    @Test func nativeForegroundConsentIsExplicitAndSurvivesScansWithoutChangingHistory() throws {
        var legacy = try nativeHistory(namespace: "synthetic")
        try legacy.setForegroundAutomaticEnabled(true)
        try legacy.setBackgroundAutomaticEnabled(true)
        try legacy.setForegroundNetworkRecoveryEnabled(true)
        #expect(throws: PhotoBackupStateError.invalidTransition) { try legacy.setNativeForegroundBackupEnabled(true) }
        let history = try nativeCanonicalJobs(legacy.jobs)
        let scan = try PhotoBackupLibraryScan.plan(legacy.jobs.map { .init(source: $0.source, capturedAt: .distantPast) })
        try legacy.applyLibraryScan(scan, allowCloud: true)
        #expect(legacy.version == 4 && legacy.nativeForegroundBackupEnabled == nil)
        #expect(legacy.foregroundAutomaticEnabled == false && legacy.backgroundAutomaticEnabled == false && legacy.foregroundNetworkRecoveryEnabled == false)
        #expect(throws: PhotoBackupStateError.invalidTransition) { try legacy.applyNativeAutomaticLibraryScan(scan) }
        try legacy.setNativeForegroundBackupEnabled(true)
        #expect(legacy.version == 5 && legacy.nativeForegroundBackupEnabled == true && legacy.allowCloud)
        #expect(try nativeCanonicalJobs(legacy.jobs) == history)
        let restored = try PhotoBackupJournal(header: JSONDecoder().decode(PhotoBackupJournal.Header.self, from: JSONEncoder().encode(legacy.header)), jobs: legacy.jobs)
        #expect(restored.nativeForegroundBackupEnabled == true)
        try legacy.applyLibraryScan(scan, allowCloud: true)
        #expect(legacy.version == 5 && legacy.nativeForegroundBackupEnabled == true)
        try legacy.setNativeForegroundBackupEnabled(false)
        try legacy.applyLibraryScan(scan, allowCloud: true)
        #expect(legacy.version == 5 && legacy.nativeForegroundBackupEnabled == false && legacy.allowCloud)
        #expect(try nativeCanonicalJobs(legacy.jobs) == history)
        #expect(throws: PhotoBackupStateError.invalidTransition) { try legacy.applyNativeAutomaticLibraryScan(scan) }
    }

    @Test func nativeVersionFiveRequiresItsOwnConsentFieldAndRejectsOlderTrueFlags() throws {
        for version in 1 ... 4 {
            let invalid = PhotoBackupJournal.Header(version: version, namespace: "synthetic", selectedAlbumIDs: ["legacy"], allowCloud: false,
                                                    excludedAlbumIDs: version == 1 ? nil : [], rawJPEGVersion: version >= 3 ? 1 : nil,
                                                    scanSource: version == 4 ? .nativeLibrary : nil, nativeForegroundBackupEnabled: true)
            #expect(throws: PhotoBackupStateError.invalidJournal) { try invalid.validate(namespace: "synthetic") }
        }
        let missing = PhotoBackupJournal.Header(version: 5, namespace: "synthetic", selectedAlbumIDs: [], allowCloud: false,
                                                excludedAlbumIDs: [], rawJPEGVersion: 1, scanSource: .nativeLibrary)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try missing.validate(namespace: "synthetic") }
        let legacyAuto = PhotoBackupJournal.Header(version: 5, namespace: "synthetic", selectedAlbumIDs: ["legacy"], allowCloud: false,
                                                   excludedAlbumIDs: [], rawJPEGVersion: 1, foregroundAutomaticEnabled: true,
                                                   scanSource: .nativeLibrary, nativeForegroundBackupEnabled: true)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try legacyAuto.validate(namespace: "synthetic") }
    }

    @Test func nativeAutomaticDeltaNeverRevivesTerminalOrUnknownHistory() throws {
        var journal = try nativeHistory(namespace: "synthetic")
        let safe = nativeScanned("safe-paused", at: 10), removed = nativeScanned("removed-queued", at: 11)
        let original = try PhotoBackupLibraryScan.plan(journal.jobs.map { .init(source: $0.source, capturedAt: .distantPast) } + [safe, removed])
        try journal.applyLibraryScan(original, allowCloud: false)
        let safeID = try #require(journal.jobs.first { $0.source == safe.source }?.id)
        try journal.update(safeID) { $0.pause() }
        try journal.setNativeForegroundBackupEnabled(true)
        let historical = try nativeCanonicalJobs(Array(journal.jobs.prefix(5)))
        let new = nativeScanned("new-photo", at: 20), deferred = nativeScanned("known-display", at: 21)
        let blockedNewVersion = nativeScanned("failed", at: 30)
        let current = try PhotoBackupLibraryScan.plan(original.sources.filter { $0 != removed.source }.map { .init(source: $0, capturedAt: .distantPast) }
            .filter { $0.source.localID != "failed" } + [blockedNewVersion, new, deferred])
        #expect(try journal.applyNativeAutomaticLibraryScan(current, deferredSources: [deferred.source]) == 1)
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(5))) == historical)
        #expect(journal.jobs.first { $0.source == safe.source }?.stage == .queued)
        #expect(journal.jobs.first { $0.source == removed.source }?.stage == .paused)
        #expect(!journal.jobs.contains { $0.source == deferred.source || $0.source == blockedNewVersion.source })
        #expect(journal.jobs.last?.source == new.source && journal.jobs.last?.attempts == 0)
        let once = try nativeCanonicalJobs(journal.jobs)
        #expect(try journal.applyNativeAutomaticLibraryScan(current, deferredSources: [deferred.source]) == 0)
        #expect(try nativeCanonicalJobs(journal.jobs) == once)
        let afterDeletion = try PhotoBackupLibraryScan.plan(current.sources.filter { $0 != new.source && $0 != safe.source }.map { .init(source: $0, capturedAt: .distantPast) })
        #expect(try journal.applyNativeAutomaticLibraryScan(afterDeletion, deferredSources: [deferred.source]) == 0)
        #expect(journal.jobs.first { $0.source == new.source }?.stage == .paused)
        #expect(journal.jobs.first { $0.source == safe.source }?.stage == .paused)
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(5))) == historical)
        #expect(journal.nativeForegroundBackupEnabled == true && !journal.allowCloud)
    }

    @Test func controllerScanQueuesOnlyUnknownOrChangedVersionsWithoutNetworkOrOriginalReads() async throws {
        try await withNativeBackupFixture { fixture in
            let stable = nativeScanned("stable", at: 10), changed = nativeScanned("changed", at: 20)
            let new = nativeScanned("new", at: 30)
            fixture.driver.assets = [stable, changed, new]
            fixture.driver.evidence = ["stable": nativeCandidateEvidence(stable.source),
                                       "changed": nativeCandidateEvidence(nativeScanned("changed", at: 10).source)]
            fixture.controller.allowCloud = true
            try await (#require(fixture.controller.scan(using: fixture.manager))).value
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.allowCloud && saved.scanSource == .nativeLibrary)
            #expect(Set(saved.jobs.map(\.source)) == Set([changed.source, new.source]))
            #expect(saved.jobs.allSatisfy { $0.stage == .queued && $0.attempts == 0 })
            #expect(fixture.controller.scannedNativeCount == 3 && fixture.controller.deferredNativeCount == 1)
            #expect(fixture.driver.evidenceCalls == 1 && fixture.exporter.calls == 0)
            #expect(NativeBackupNoNetworkProtocol.requests(host: fixture.endpoint.host!) == 0)
        }
    }

    @Test func candidateEvidenceCannotPublishAfterPhotosPermissionChanges() async throws {
        try await withNativeBackupFixture { fixture in
            let stable = nativeScanned("stable", at: 10)
            fixture.driver.assets = [stable]
            fixture.driver.evidence = ["stable": nativeCandidateEvidence(stable.source)]
            fixture.driver.beforeEvidenceReturn = { fixture.driver.authorization = .denied }
            try await (#require(fixture.controller.scan(using: fixture.manager))).value
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.scanSource == nil && saved.jobs.isEmpty)
            #expect(fixture.exporter.calls == 0 && NativeBackupNoNetworkProtocol.requests(host: fixture.endpoint.host!) == 0)
        }
    }

    @Test func deferringEightyThousandNewSourcesDoesNotCreateJobsOrChangeHistory() throws {
        var journal = try nativeHistory(namespace: "synthetic")
        let history = try nativeCanonicalJobs(journal.jobs), count = journal.jobs.count
        let deferred = (0 ..< 80000).map { nativeScanned("deferred-\($0)", at: TimeInterval($0 + 100)) }
        let candidate = nativeScanned("original-candidate", at: 99)
        let scan = try PhotoBackupLibraryScan.plan(deferred + [candidate])
        let deferredSources = Set(deferred.map(\.source)).union(journal.jobs.map(\.source))
        #expect(try journal.applyLibraryScan(scan, allowCloud: true, deferredSources: deferredSources) == 1)
        #expect(journal.jobs.count == count + 1 && journal.jobs.last?.source == candidate.source)
        #expect(journal.jobs.last?.stage == .queued && journal.jobs.last?.attempts == 0)
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(count))) == history)
        #expect(journal.scanSource == .nativeLibrary && journal.allowCloud)
    }

    @Test func candidateLimitedResumePreservesHistoryAndPausesOtherQueuedWork() throws {
        var journal = try nativeHistory(namespace: "synthetic")
        let history = try nativeCanonicalJobs(journal.jobs), count = journal.jobs.count
        let candidate = nativeScanned("candidate", at: 10), excluded = nativeScanned("excluded", at: 11)
        let scan = try PhotoBackupLibraryScan.plan(journal.jobs.map { .init(source: $0.source, capturedAt: .distantPast) } + [candidate, excluded])
        try journal.applyLibraryScan(scan, allowCloud: true)
        try journal.resumeLibraryForVerification(scan, unattemptedOnly: true,
                                                 candidateLocalIDs: [candidate.source.localID, "failed", "paused-live", "not-in-library"])
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(count))) == history)
        #expect(journal.jobs.filter { $0.stage == .queued }.map(\.source) == [candidate.source])
        let paused = try #require(journal.jobs.first { $0.source == excluded.source })
        #expect(paused.stage == .paused && paused.attempts == 0 && paused.primaryAssetID == nil && paused.failure == nil)
        let before = try nativeCanonicalJobs(journal.jobs)
        #expect(throws: PhotoBackupStateError.invalidTransition) {
            try journal.resumeLibraryForVerification(scan, only: paused.id, candidateLocalIDs: [candidate.source.localID])
        }
        #expect(try nativeCanonicalJobs(journal.jobs) == before)
        try journal.resumeLibraryForVerification(scan, candidateLocalIDs: [])
        #expect(!journal.jobs.contains { $0.stage == .queued })
    }

    @Test func matchingCompoundIdentityOnlyDefersSchedulingWithoutClaimingOriginalCompletion() throws {
        let pair = try PhotoBackupRawJPEGSource(originals: [
            .init(kind: .photo, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 100, pixelHeight: 100),
            .init(kind: .alternatePhoto, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 100, pixelHeight: 100),
        ], hasAdjustments: false, adjustmentTime: nil)
        let sources = [nativeScanned("photo", at: 10).source, nativeScanned("video", at: 10, kind: .video).source,
                       nativeScanned("live", at: 10, kind: .livePhoto).source,
                       PhotoBackupSource(localID: "raw", modifiedAt: Date(timeIntervalSince1970: 10), kind: .rawJPEG, rawJPEG: pair)]
        let hints = sources.map { nativeCandidateEvidence($0) }
        let deferred = try PhotoBackupCandidateSelection.deferredSources(sources: sources, evidence: hints)
        #expect(deferred == Set(sources))
        let scan = try PhotoBackupLibraryScan.plan(sources.map { .init(source: $0, capturedAt: .distantPast) })
        var journal = PhotoBackupJournal(namespace: "synthetic")
        #expect(try journal.applyLibraryScan(scan, allowCloud: true, deferredSources: deferred) == 0)
        #expect(journal.jobs.isEmpty)
        // Live Photo and ordinary image observations are deliberately distinct, even though both remote types are IMAGE.
        #expect(try PhotoBackupCandidateSelection.deferredSources(sources: [sources[2]],
                                                                  evidence: [nativeCandidateEvidence(sources[2], media: .image)]).isEmpty)
    }

    @Test(arguments: ["changed-version", "no-date", "wrong-type", "pending", "unmatched", "no-cloud", "no-version", "strong-only"])
    func staleOrIncompleteDisplayEvidenceRemainsAnOriginalCandidate(_ fault: String) throws {
        let source = PhotoBackupSource(localID: "candidate", modifiedAt: fault == "no-date" ? nil : Date(timeIntervalSince1970: 20), kind: .photo)
        let observed = fault == "changed-version" ? nativeScanned("candidate", at: 10).source : source
        let hint = nativeCandidateEvidence(observed, media: fault == "wrong-type" ? .video : nil,
                                           cloudID: fault == "no-cloud" ? nil : "synthetic-cloud",
                                           identityVersion: fault == "no-version" ? "" : "synthetic-version",
                                           result: fault == "pending" ? .pending : fault == "unmatched" ? .unmatched : .matched,
                                           reason: fault == "pending" ? .sourceChanged : fault == "unmatched" ? .noServerIdentity : .matched,
                                           proof: fault == "strong-only" ? .checksum : .exactCloudIdentity)
        let deferred = try PhotoBackupCandidateSelection.deferredSources(sources: [source], evidence: [hint])
        #expect(deferred.isEmpty)
        var journal = PhotoBackupJournal(namespace: "synthetic")
        let scan = try PhotoBackupLibraryScan.plan([.init(source: source, capturedAt: .distantPast)])
        #expect(try journal.applyLibraryScan(scan, allowCloud: true, deferredSources: deferred) == 1)
        #expect(journal.jobs.first?.source == source && journal.jobs.first?.stage == .queued)
    }

    @Test func malformedOrConflictingCandidateHintBatchesFailClosed() throws {
        let source = nativeScanned("candidate", at: 10).source
        let hint = nativeCandidateEvidence(source)
        #expect(throws: PhotoBackupContinuityError.incompleteResponse) {
            _ = try PhotoBackupCandidateSelection.deferredSources(sources: [source, source], evidence: [])
        }
        #expect(throws: PhotoBackupContinuityError.incompleteResponse) {
            _ = try PhotoBackupCandidateSelection.deferredSources(sources: [source], evidence: [nativeCandidateEvidence(nativeScanned("foreign", at: 10).source)])
        }
        let conflicting = nativeCandidateEvidence(source)
        #expect(hint.association.remoteID != conflicting.association.remoteID)
        #expect(throws: PhotoBackupContinuityError.incompleteResponse) {
            _ = try PhotoBackupCandidateSelection.deferredSources(sources: [source], evidence: [hint, conflicting])
        }
        let wrongLocal = PhotoBackupDisplayAliasEvidence(association: nativeCandidateEvidence(nativeScanned("foreign", at: 10).source).association, work: hint.work)
        #expect(throws: PhotoBackupContinuityError.incompleteResponse) {
            _ = try PhotoBackupCandidateSelection.deferredSources(sources: [source], evidence: [wrongLocal])
        }
        #expect(throws: PhotoBackupContinuityError.incompleteResponse) {
            _ = try PhotoBackupCandidateSelection.deferredSources(sources: (0 ..< 65).map { nativeScanned("source-\($0)", at: 10).source }, evidence: [])
        }
    }

    @Test func conflictingNativeSnapshotCannotBecomeAPlan() throws {
        let journal = try nativeHistory(namespace: "synthetic")
        let history = try nativeCanonicalJobs(journal.jobs)
        let oldCompleted = try #require(journal.jobs.first)
        let changed = PhotoBackupScannedAsset(source: .init(localID: oldCompleted.source.localID, modifiedAt: Date(timeIntervalSince1970: 999), kind: .photo), capturedAt: Date(timeIntervalSince1970: 3))
        #expect(throws: PhotoBackupAlbumSelectionError.changedSource) {
            _ = try PhotoBackupLibraryScan.plan([nativeScanned("outside-recent", at: 1), .init(source: oldCompleted.source, capturedAt: Date(timeIntervalSince1970: 2)), changed])
        }
        #expect(try nativeCanonicalJobs(journal.jobs) == history)
    }

    @Test func completeScanAppendsNewVersionsButPreservesUnseenPausedAndFailedHistory() throws {
        var journal = try nativeHistory(namespace: "synthetic")
        let history = try nativeCanonicalJobs(journal.jobs), originalIDs = journal.jobs.map(\.id)
        let same = journal.jobs[0].source
        let scan = try PhotoBackupLibraryScan.plan([.init(source: same, capturedAt: .distantPast), nativeScanned("outside-recent", at: 2)])
        #expect(try journal.applyLibraryScan(scan, allowCloud: true) == 1)
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(originalIDs.count))) == history)
        #expect(journal.jobs.prefix(originalIDs.count).map(\.id) == originalIDs)
        #expect(journal.jobs.last?.source.localID == "outside-recent" && journal.jobs.last?.stage == .queued)
        #expect(journal.version == 4 && journal.scanSource == .nativeLibrary && journal.selectedAlbumIDs == ["old-recent-projects"])
        #expect(journal.foregroundAutomaticEnabled == false && journal.backgroundAutomaticEnabled == false)
        #expect(try journal.applyLibraryScan(scan, allowCloud: true) == 0)
        #expect(try nativeCanonicalJobs(Array(journal.jobs.prefix(originalIDs.count))) == history)
        let newVersion = try PhotoBackupLibraryScan.plan([.init(source: .init(localID: same.localID, modifiedAt: Date(timeIntervalSince1970: 99), kind: same.kind), capturedAt: .distantPast)])
        #expect(try journal.applyLibraryScan(newVersion, allowCloud: false) == 1)
        #expect(journal.jobs[0].stage == .completed && journal.jobs.last?.stage == .queued)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try journal.setForegroundAutomaticEnabled(true) }
    }

    @Test func nativeHeaderCannotBeReadOrExecutedAsLegacyAlbumScope() throws {
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.applyLibraryScan(PhotoBackupLibraryScan.plan([nativeScanned("global", at: 1)]), allowCloud: false)
        try journal.header.validate(namespace: "synthetic")
        #expect(throws: PhotoBackupStateError.invalidTransition) { try journal.resumeForVerification() }
        #expect(throws: PhotoBackupStateError.invalidTransition) { try journal.enqueue([nativeScanned("other", at: 2).source]) }
        let missingSource = PhotoBackupJournal.Header(version: 4, namespace: "synthetic", selectedAlbumIDs: [], allowCloud: false, excludedAlbumIDs: [], rawJPEGVersion: 1)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try missingSource.validate(namespace: "synthetic") }
        let unsafeAutomatic = PhotoBackupJournal.Header(version: 4, namespace: "synthetic", selectedAlbumIDs: ["organization"], allowCloud: false, excludedAlbumIDs: [], rawJPEGVersion: 1, foregroundAutomaticEnabled: true, scanSource: .nativeLibrary)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try unsafeAutomatic.validate(namespace: "synthetic") }
    }

    @Test func globalScanDoesNotRequireAlbumCatalogOrSelectionAndNeverReadsOriginals() async throws {
        try await withNativeBackupFixture { fixture in
            fixture.driver.assets = [nativeScanned("hidden-outside-old-album", at: 3), nativeScanned("burst-member", at: 2), nativeScanned("video", at: 1, kind: .video), nativeScanned("live", at: 4, kind: .livePhoto)]
            #expect(!fixture.controller.hasLoadedAlbums && fixture.controller.selected.isEmpty && fixture.controller.requiresSelectionScan)
            let task = try #require(fixture.controller.scan(using: fixture.manager))
            await task.value
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.jobs.map(\.source.localID) == ["video", "burst-member", "hidden-outside-old-album", "live"])
            #expect(saved.jobs.map(\.source.kind) == [.video, .photo, .photo, .livePhoto])
            #expect(saved.scanSource == .nativeLibrary && saved.version == 4 && !fixture.controller.requiresSelectionScan)
            #expect(fixture.driver.calls == 1 && fixture.driver.albumCalls == 0 && fixture.exporter.calls == 0)
            #expect(NativeBackupNoNetworkProtocol.requests(host: fixture.endpoint.host!) == 0)
        }
    }

    @Test(arguments: ["cancel", "permission", "account"])
    func scanRetirementCannotPublishAfterCancellationPermissionOrAccountChange(_ reason: String) async throws {
        try await withNativeBackupFixture(history: true) { fixture in
            let before = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            let beforeJobs = try nativeCanonicalJobs(before.jobs)
            fixture.driver.assets = [nativeScanned("new-native-item", at: 1)]
            fixture.driver.beforeReturn = { [weak manager = fixture.manager, driver = fixture.driver] in
                switch reason {
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                case "permission": driver.authorization = .denied
                default: manager?.configure(session: nil, endpoint: nil)
                }
            }
            let task = try #require(fixture.controller.scan(using: fixture.manager))
            await task.value
            let after = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(after.version == before.version && after.scanSource == nil)
            #expect(try nativeCanonicalJobs(after.jobs) == beforeJobs)
            #expect(fixture.exporter.calls == 0 && NativeBackupNoNetworkProtocol.requests(host: fixture.endpoint.host!) == 0)
        }
    }

    @Test func deniedPermissionDoesNotInvokeScannerOrChangePlan() async throws {
        try await withNativeBackupFixture { fixture in
            fixture.driver.authorization = .denied
            #expect(fixture.controller.scan(using: fixture.manager) == nil)
            #expect(fixture.driver.calls == 0 && fixture.exporter.calls == 0)
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.scanSource == nil)
        }
    }

    @Test func organizationDraftNeverNarrowsNativeInventoryOrChangesCloudConsent() async throws {
        try await withNativeBackupFixture { fixture in
            fixture.driver.assets = [nativeScanned("whole-library", at: 1)]
            try await (#require(fixture.controller.scan(using: fixture.manager))).value
            let before = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            fixture.controller.selected = ["organization-only"]
            fixture.controller.excluded = ["organization-excluded"]
            #expect(fixture.controller.requiresOrganizationSave && !fixture.controller.requiresSelectionScan)
            fixture.controller.allowCloud = true
            #expect(fixture.controller.requiresSelectionScan)
            await fixture.controller.saveOrganizationSelection(using: fixture.manager)
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.scanSource == .nativeLibrary && saved.selectedAlbumIDs == ["organization-only"])
            #expect(saved.excludedAlbumIDs == ["organization-excluded"] && !saved.allowCloud)
            #expect(!fixture.controller.requiresOrganizationSave && fixture.controller.requiresSelectionScan)
            #expect(try nativeCanonicalJobs(saved.jobs) == nativeCanonicalJobs(before.jobs))
            #expect(fixture.driver.calls == 1 && fixture.exporter.calls == 0)
        }
    }

    @Test func legacyAutomaticConsentCannotExpandIntoNativeOriginalBackup() async throws {
        try await withNativeBackupFixture(history: true, automatic: true) { fixture in
            #expect(!fixture.controller.foregroundAutomaticEnabled && !fixture.controller.backgroundAutomaticEnabled)
            await fixture.controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: true)?.value
            #expect(fixture.controller.runSystemBackground(using: fixture.manager) == nil)
            #expect(try await fixture.controller.refreshBackgroundConsent(using: fixture.manager) == false)
            await fixture.controller.setForegroundAutomaticEnabled(true, using: fixture.manager)
            await fixture.controller.setBackgroundAutomaticEnabled(true, using: fixture.manager)
            #expect(fixture.driver.calls == 0 && fixture.exporter.calls == 0)
            fixture.driver.assets = [nativeScanned("new-global-item", at: 1)]
            try await (#require(fixture.controller.scan(using: fixture.manager))).value
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.scanSource == .nativeLibrary && saved.foregroundAutomaticEnabled == false && saved.backgroundAutomaticEnabled == false)
            #expect(fixture.driver.calls == 1 && fixture.exporter.calls == 0)
            #expect(NativeBackupNoNetworkProtocol.requests(host: fixture.endpoint.host!) == 0)
        }
    }

    @Test func rawAndLiveSourceContractsSurviveVersionFourHeaderAndHotWrites() async throws {
        try await withNativeBackupFixture { fixture in
            let pair = try PhotoBackupRawJPEGSource(originals: [
                .init(kind: .photo, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 100, pixelHeight: 100),
                .init(kind: .alternatePhoto, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 100, pixelHeight: 100),
            ], hasAdjustments: false, adjustmentTime: nil)
            fixture.driver.assets = [.init(source: .init(localID: "raw-pair", modifiedAt: Date(timeIntervalSince1970: 1), kind: .rawJPEG, rawJPEG: pair), capturedAt: .distantPast), nativeScanned("live", at: 1, kind: .livePhoto)]
            try await (#require(fixture.controller.scan(using: fixture.manager))).value
            try await fixture.store.updatePhotoBackupAutomationSettings(scope: fixture.scope, foreground: false, background: false, networkRecovery: false)
            let saved = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(saved.version == 4 && saved.scanSource == .nativeLibrary && saved.jobs.first?.source.rawJPEG == pair)
            var raw = try #require(saved.jobs.first)
            try raw.begin()
            try await fixture.store.savePhotoBackupJob(raw, scope: fixture.scope)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.first?.stage == .exporting)
            #expect(fixture.exporter.calls == 0)
        }
    }
}

@MainActor private final class NativeBackupDriver {
    var authorization = PHAuthorizationStatus.authorized
    var calls = 0, albumCalls = 0
    var assets: [PhotoBackupScannedAsset] = []
    var beforeReturn: (() -> Void)?
    var evidence: [String: PhotoBackupDisplayAliasEvidence] = [:]
    var evidenceCalls = 0
    var beforeEvidenceReturn: (() -> Void)?
}

@MainActor private final class NativeBackupNeverExporter: PhotoBackupResourceExporting {
    var calls = 0
    func export(_: PhotoBackupSource, allowCloud _: Bool) async throws -> PhotoBackupResources {
        calls += 1; throw PhotoBackupStateError.invalidTransition
    }
}

@MainActor private final class NativeBackupFixture {
    let root: URL, endpoint: URL
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let manager: LibraryManagementController
    let driver: NativeBackupDriver
    let exporter: NativeBackupNeverExporter
    let controller: PhotoBackupController
    init(history: Bool, automatic: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-backup-" + UUID().uuidString)
        let endpoint = URL(string: "https://native-backup-" + UUID().uuidString.lowercased() + ".invalid/api")!
        let session = AccountSession(apiURL: endpoint, accessToken: "synthetic", userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session), store = SQLiteLibraryIndexStore(databaseURL: root.appendingPathComponent("index.sqlite"))
        let manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeBackupNoNetworkProtocol.self]
            return configuration
        })
        manager.configure(session: session, endpoint: endpoint)
        var journal: PhotoBackupJournal = if history {
            try nativeHistory(namespace: scope.cacheNamespace)
        } else {
            PhotoBackupJournal(namespace: scope.cacheNamespace)
        }
        if automatic {
            try journal.setForegroundAutomaticEnabled(true); try journal.setBackgroundAutomaticEnabled(true)
        }
        try await store.prepare(scope: scope); try await store.savePhotoBackups(journal, scope: scope)
        let driver = NativeBackupDriver(), exporter = NativeBackupNeverExporter()
        let controller = PhotoBackupController(store: store, exporter: exporter,
                                               albumLoader: { driver.albumCalls += 1; throw PhotoBackupController.AlbumReadError.invalidCatalog },
                                               albumScanner: { _ in driver.albumCalls += 1; throw PhotoBackupController.AlbumReadError.invalidCatalog },
                                               authorizationStatus: { driver.authorization }, observeAutomaticPhotos: false,
                                               scanSource: .nativeLibrary, libraryScanner: { validate in
                                                   driver.calls += 1; try validate(); driver.beforeReturn?(); try validate(); return driver.assets
                                               }, candidateEvidence: { ids, requestedScope in
                                                   guard requestedScope == scope else { throw LibraryWriteError.changedAccount }
                                                   driver.evidenceCalls += 1
                                                   let evidence = ids.compactMap { driver.evidence[$0] }
                                                   driver.beforeEvidenceReturn?()
                                                   return evidence
                                               })
        self.root = root; self.endpoint = endpoint; self.scope = scope; self.store = store
        self.manager = manager; self.driver = driver; self.exporter = exporter; self.controller = controller
        await controller.load(using: manager)
    }

    func close() async {
        controller.cancel(); driver.beforeReturn = nil; driver.beforeEvidenceReturn = nil; manager.configure(session: nil, endpoint: nil)
        try? await store.removeAccount(namespace: scope.cacheNamespace)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func withNativeBackupFixture(history: Bool = false, automatic: Bool = false, _ body: (NativeBackupFixture) async throws -> Void) async throws {
    let fixture = try await NativeBackupFixture(history: history, automatic: automatic)
    do { try await body(fixture) } catch { await fixture.close(); throw error }
    await fixture.close()
}

private nonisolated func nativeScanned(_ id: String, at date: TimeInterval, kind: PhotoBackupSource.Kind = .photo) -> PhotoBackupScannedAsset {
    .init(source: .init(localID: id, modifiedAt: Date(timeIntervalSince1970: date), kind: kind), capturedAt: Date(timeIntervalSince1970: date))
}

private nonisolated func nativeCandidateEvidence(_ source: PhotoBackupSource, media: LocalPhotoIdentity.MediaKind? = nil,
                                                 cloudID: String? = "synthetic-cloud", identityVersion: String = "synthetic-version",
                                                 result: LocalPhotoDisplayLocalWork.Result = .matched,
                                                 reason: LocalPhotoDisplayLocalWork.Reason = .matched,
                                                 proof: LocalMediaAssociation.Source = .exactCloudIdentity) -> PhotoBackupDisplayAliasEvidence
{
    let kind: LocalPhotoIdentity.MediaKind = if let media {
        media
    } else if source.kind == .video {
        .video
    } else if source.kind == .livePhoto {
        .livePhoto
    } else {
        .image
    }
    let association = LocalMediaAssociation(remoteID: UUID(), remoteRevision: Date(timeIntervalSince1970: 100),
                                            localIdentity: .init(localIdentifier: source.localID, modificationDate: source.modifiedAt, mediaKind: kind),
                                            checksum: Data(repeating: 1, count: 20).base64EncodedString(), source: proof)
    let work = LocalPhotoDisplayLocalWork(localID: source.localID, cloudID: cloudID, identityVersion: identityVersion,
                                          evidenceHash: "synthetic-evidence", result: result, reason: reason)
    return .init(association: association, work: work)
}

private nonisolated func nativeCanonicalJobs(_ jobs: [PhotoBackupJob]) throws -> Data {
    try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(jobs)), options: [.sortedKeys])
}

private nonisolated func nativeHistory(namespace: String) throws -> PhotoBackupJournal {
    var journal = PhotoBackupJournal(namespace: namespace)
    journal.selectedAlbumIDs = ["old-recent-projects"]
    let sources = [nativeScanned("complete", at: 1).source, nativeScanned("matched", at: 2).source,
                   nativeScanned("paused-live", at: 3, kind: .livePhoto).source, nativeScanned("failed", at: 4).source,
                   nativeScanned("cancelled", at: 5).source]
    try journal.enqueue(sources)
    let ids = journal.jobs.map(\.id)
    try journal.update(ids[0]) { try $0.begin(); try $0.exported(); try $0.recordPrimary(UUID(), duplicate: false); try $0.confirmVerifiedReceipt() }
    try journal.update(ids[1]) { try $0.confirmExistingMatch() }
    try journal.update(ids[2]) { try $0.begin(); try $0.exported(); try $0.recordMotion(UUID()); $0.pause() }
    try journal.update(ids[3]) { $0.fail(.network) }
    try journal.update(ids[4]) { $0.cancel() }
    return journal
}

private final nonisolated class NativeBackupNoNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let counts = Mutex<[String: Int]>([:])
    static func requests(host: String) -> Int {
        counts.withLock { $0[host, default: 0] }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.counts.withLock { $0[request.url?.host ?? "unknown", default: 0] += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
