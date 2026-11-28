import Foundation
import Observation
import Photos
import Synchronization
import Testing
@testable import Remmich

/// Real Controller/Coordinator/SQLite/Worker/client; synthetic Photos, files and private HTTP only.
@Suite("Native foreground original backup")
@MainActor struct PhotoBackupNativeAutomaticTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func defaultOffAndLegacyConsentNeverAuthorizeNativeOriginals(_ legacy: Bool) async throws {
        try await withNativeAutomatic(legacy: legacy) { f in
            f.port.assets.append(nativeAutomaticAsset("not-authorized", at: 2))
            await f.activate()?.value
            await f.request()?.value
            await f.track(f.controller.networkRouteValidated(using: f.manager, scope: f.scope, eventID: UUID()))?.value
            let cold = try await f.journal()
            #expect(cold.nativeForegroundBackupEnabled != true && !f.controller.nativeForegroundBackupEnabled)
            #expect(f.port.scans == 0 && f.port.albumReads == 0 && f.exporter.observations.isEmpty && f.server.counts == [0, 0, 0, 0])
            #expect(f.controller.runSystemBackground(using: f.manager) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func explicitNativeStartPersistsSeparateConsentAndOriginalCloudChoice(_ cloud: Bool) async throws {
        try await withNativeAutomatic(cloud: cloud) { f in
            f.port.assets.append(nativeAutomaticAsset("manual-first", at: 2))
            await f.activate()?.value
            let requested = await f.controller.startNativeForegroundBackup(using: f.manager)
            let task = try #require(requested)
            await f.track(task)?.value
            let cold = try await f.journal()
            #expect(cold.version == 5 && cold.nativeForegroundBackupEnabled == true && cold.allowCloud == cloud)
            #expect(cold.foregroundAutomaticEnabled != true && cold.backgroundAutomaticEnabled != true && cold.foregroundNetworkRecoveryEnabled != true)
            #expect(cold.jobs.first { $0.source.localID == "manual-first" }?.stage == .completed)
            #expect(f.exporter.observations.map(\.allowCloud) == [cloud] && f.server.counts == [1, 1, 1, 0])
            #expect(f.controller.runSystemBackground(using: f.manager) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func photosEventsUploadNewItemsAndChecksumDeduplicateWithoutReplayingCompleted() async throws {
        try await withNativeAutomatic(enabled: true, cloud: true) { f in
            let initial = try await f.journal()
            let baseline = try #require(initial.jobs.first { $0.source.localID == "baseline" })
            let before = try nativeAutomaticPayload(baseline)
            f.port.assets.append(nativeAutomaticAsset("new-one", at: 2))
            await f.activate()?.value
            #expect(f.server.counts == [1, 1, 1, 0] && f.exporter.observations.map(\.localID) == ["new-one"])
            await f.request()?.value
            #expect(f.server.counts == [1, 1, 1, 0] && f.exporter.observations.count == 1)
            f.port.assets.append(nativeAutomaticAsset("new-two-same-bytes", at: 3))
            await f.request()?.value
            let cold = try await f.journal()
            #expect(f.server.counts == [2, 1, 2, 0] && f.exporter.observations.count == 2)
            #expect(cold.jobs.allSatisfy { $0.stage == .completed } && f.exporter.observations.allSatisfy { $0.stage == .exporting && $0.allowCloud })
            let retained = try #require(cold.jobs.first { $0.source.localID == "baseline" })
            #expect(try nativeAutomaticPayload(retained) == before)
            #expect(f.exporter.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func coldForegroundRestoresOnlyTheSavedNativeConsent() async throws {
        try await withNativeAutomatic(enabled: true) { f in
            f.port.assets.append(nativeAutomaticAsset("arrived-while-closed", at: 2))
            let cold = f.makeController()
            await cold.load(using: f.manager)
            await f.track(cold.automaticConditionsChanged(using: f.manager, scope: f.scope, active: true))?.value
            let saved = try await f.journal()
            #expect(cold.nativeForegroundBackupEnabled && saved.nativeForegroundBackupEnabled == true)
            #expect(saved.jobs.first { $0.source.localID == "arrived-while-closed" }?.stage == .completed)
            #expect(f.server.counts == [1, 1, 1, 0] && f.exporter.observations.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundDuringConsentPersistenceCannotStartOriginalsUntilForeground() async throws {
        try await withNativeAutomatic { f in
            await f.activate()?.value
            f.port.assets.append(nativeAutomaticAsset("consent-background-race", at: 2))
            let gate = NativeAutomaticConsentGate()
            defer { gate.release() }
            let blocker = Task<Void, Never> {
                _ = try? await PhotoBackupRunCoordinator.perform(scope: f.scope) { await gate.hold() }
                gate.operationFinished()
            }
            _ = f.track(blocker)
            try #require(await gate.waitForEntry())
            withObservationTracking { _ = f.controller.configuringAutomatic } onChange: {
                Task { @MainActor in gate.consentStarted(f.controller.configuringAutomatic) }
            }
            let start = Task<Void, Never> {
                let work = await f.controller.startNativeForegroundBackup(using: f.manager)
                await f.track(work)?.value
                gate.startFinished()
            }
            _ = f.track(start)
            try #require(await gate.waitForConsent())
            let inactive = f.controller.automaticConditionsChanged(using: f.manager, scope: f.scope, active: false)
            gate.release()
            await blocker.value; await start.value; await f.track(inactive)?.value
            let saved = try await f.journal()
            #expect(saved.nativeForegroundBackupEnabled == true && f.exporter.observations.isEmpty && f.server.counts == [0, 0, 0, 0])
            await f.activate()?.value
            #expect(f.server.counts == [1, 1, 1, 0] && f.exporter.observations.map(\.localID) == ["consent-background-race"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func offlinePausePersistsBeforeConnectionReturns() async throws {
        try await withNativeAutomatic(enabled: true) { f in
            await f.activate()?.value
            let beforeScans = f.port.scans
            f.manager.configure(session: f.account, endpoint: nil)
            await f.track(f.controller.automaticConditionsChanged(using: f.manager, scope: f.scope, active: true))?.value
            await f.controller.setNativeForegroundBackupEnabled(false, using: f.manager)
            let paused = try await f.journal()
            #expect(paused.nativeForegroundBackupEnabled == false && !f.controller.nativeForegroundBackupEnabled)
            f.port.assets.append(nativeAutomaticAsset("arrived-after-offline-pause", at: 2))
            f.manager.configure(session: f.account, endpoint: f.endpoint)
            await f.activate()?.value
            await f.track(f.controller.networkRouteValidated(using: f.manager, scope: f.scope, eventID: UUID()))?.value
            #expect(f.server.counts == [0, 0, 0, 0] && f.exporter.observations.isEmpty && f.port.scans == beforeScans)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitPausePersistsAndBlocksPhotosNetworkAndColdForegroundRestart() async throws {
        try await withNativeAutomatic(enabled: true) { f in
            await f.activate()?.value
            await f.controller.setNativeForegroundBackupEnabled(false, using: f.manager)
            f.port.assets.append(nativeAutomaticAsset("after-explicit-pause", at: 2))
            let before = f.server.counts, scans = f.port.scans
            await f.request()?.value
            await f.track(f.controller.networkRouteValidated(using: f.manager, scope: f.scope, eventID: UUID()))?.value
            let cold = f.makeController()
            await cold.load(using: f.manager)
            await f.track(cold.automaticConditionsChanged(using: f.manager, scope: f.scope, active: true))?.value
            let saved = try await f.journal()
            #expect(saved.nativeForegroundBackupEnabled == false && !cold.nativeForegroundBackupEnabled)
            #expect(f.server.counts == before && f.port.scans == scans && f.exporter.observations.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["background", "permission", "account"])
    func lateResourcesCannotCompleteAfterLifecycleOrAuthorizationRetirement(_ reason: String) async throws {
        try await withNativeAutomatic(enabled: true) { f in
            f.port.assets.append(nativeAutomaticAsset("held-original", at: 2))
            f.exporter.hold = true
            let first = try #require(f.activate())
            try #require(await f.exporter.waitUntilHeld())
            let retirement: Task<Void, Never>?
            if reason == "background" {
                retirement = f.controller.automaticConditionsChanged(using: f.manager, scope: f.scope, active: false)
            } else if reason == "permission" {
                f.port.authorization = .denied
                retirement = nil
            } else {
                let other = f.otherAccount
                f.manager.configure(session: other, endpoint: f.endpoint)
                retirement = f.controller.automaticConditionsChanged(using: f.manager, scope: MediaAccountScope(session: other), active: true)
            }
            f.exporter.release()
            await f.track(retirement)?.value
            await first.value
            let saved = try await f.journal()
            let held = try #require(saved.jobs.first { $0.source.localID == "held-original" })
            #expect(held.stage != .completed && held.attempts == 1 && held.primaryAssetID == nil && held.primaryChecksum == nil)
            #expect(f.server.counts == [0, 0, 0, 0] && f.exporter.observations.count == 1)
            if reason == "account" {
                let other = try await SQLiteLibraryIndexStore(databaseURL: f.database).loadPhotoBackups(scope: MediaAccountScope(session: f.otherAccount))
                #expect(other.nativeForegroundBackupEnabled != true && other.jobs.isEmpty)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeRecoveryNeverRequeuesFailedCancelledOrUnconfirmedOriginals() async throws {
        try await withNativeAutomatic(enabled: true) { f in
            let names = ["failed", "cancelled", "receipt", "safe-unattempted"]
            f.port.assets += names.enumerated().map { nativeAutomaticAsset($0.element, at: Double($0.offset + 2)) }
            var saved = try await f.journal()
            try saved.applyLibraryScan(PhotoBackupLibraryScan.plan(f.port.assets), allowCloud: saved.allowCloud)
            for job in saved.jobs where names.contains(job.source.localID) {
                try saved.update(job.id) { value in
                    switch value.source.localID {
                    case "failed": try value.begin(); value.fail(.network)
                    case "cancelled": value.cancel()
                    case "receipt":
                        try value.begin(); try value.exported(); try value.recordPrimary(UUID(), duplicate: false, checksum: nativeAutomaticDigest); value.pause()
                    default: value.pause()
                    }
                }
            }
            try await f.store.savePhotoBackups(saved, scope: f.scope)
            await f.activate()?.value
            await f.track(f.controller.networkRouteValidated(using: f.manager, scope: f.scope, eventID: UUID()))?.value
            let cold = try await f.journal()
            #expect(cold.jobs.first { $0.source.localID == "failed" }?.stage == .failed)
            #expect(cold.jobs.first { $0.source.localID == "cancelled" }?.stage == .cancelled)
            let receipt = try #require(cold.jobs.first { $0.source.localID == "receipt" })
            #expect(receipt.stage == .paused && receipt.primaryAssetID != nil && receipt.primaryChecksum == nativeAutomaticDigest && receipt.attempts == 1)
            #expect(cold.jobs.first { $0.source.localID == "safe-unattempted" }?.stage == .completed)
            #expect(f.exporter.observations.map(\.localID) == ["safe-unattempted"] && f.server.counts == [1, 1, 1, 0])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func enabledRuleWaitsForExistingPhotosPermissionWithoutScanning() async throws {
        try await withNativeAutomatic(enabled: true) { f in
            f.port.authorization = .denied
            f.port.assets.append(nativeAutomaticAsset("permission-wait", at: 2))
            await f.activate()?.value
            await f.request()?.value
            #expect(f.port.scans == 0 && f.port.albumReads == 0 && f.exporter.observations.isEmpty && f.server.counts == [0, 0, 0, 0])
        }
    }
}

@MainActor private func withNativeAutomatic(enabled: Bool = false, cloud: Bool = false, legacy: Bool = false,
                                            _ body: @MainActor (NativeAutomaticFixture) async throws -> Void) async throws
{
    let f = try await NativeAutomaticFixture(cloud: cloud, legacy: legacy)
    do {
        if enabled {
            await f.controller.setNativeForegroundBackupEnabled(true, using: f.manager)
        }
        try await body(f)
        await f.close()
    } catch { await f.close(); throw error }
}

private nonisolated let nativeAutomaticDigest = "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
private nonisolated let nativeAutomaticHex = "a9993e364706816aba3e25717850c26c9cd0d89d"
private nonisolated let nativeAutomaticRemote = "22222222-2222-4222-8222-222222222222"

private nonisolated func nativeAutomaticAsset(_ id: String, at time: TimeInterval) -> PhotoBackupScannedAsset {
    .init(source: .init(localID: id, modifiedAt: Date(timeIntervalSince1970: time), kind: .photo), capturedAt: Date(timeIntervalSince1970: time))
}

private nonisolated func nativeAutomaticPayload(_ job: PhotoBackupJob) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(job)
}

@MainActor private final class NativeAutomaticPhotos {
    var authorization: PHAuthorizationStatus = .authorized
    var assets = [nativeAutomaticAsset("baseline", at: 1)]
    private(set) var scans = 0
    var albumReads = 0
    func scan(_ validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> [PhotoBackupScannedAsset] {
        scans += 1; try Task.checkCancellation(); try validate(); return assets
    }
}

@MainActor private final class NativeAutomaticPreflight: PhotoBackupPreflighting {
    func plan(jobs: [PhotoBackupJob], scope _: MediaAccountScope, client _: any PhotoBackupContinuityQuerying, verificationIDs _: Set<UUID>,
              progress: @MainActor (Int, Int) -> Void, validateContext: @MainActor () throws -> Void) async throws -> PhotoBackupPreflightPlan
    {
        try Task.checkCancellation(); try validateContext(); progress(jobs.count, jobs.count)
        return .init(allowed: Set(jobs.map(\.source)), existing: [], review: [])
    }
}

@MainActor private final class NativeAutomaticFixture {
    let root: URL
    let database: URL
    let endpoint: URL
    let scope: MediaAccountScope
    let account: AccountSession
    let otherAccount: AccountSession
    let store: SQLiteLibraryIndexStore
    let manager: LibraryManagementController
    let controller: PhotoBackupController
    let port: NativeAutomaticPhotos
    let exporter: NativeAutomaticExporter
    let server: NativeAutomaticServer
    private var controllers: [PhotoBackupController]
    private var tasks: [Task<Void, Never>] = []
    private var observers: [Task<Void, Never>] = []

    init(cloud: Bool, legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NativeAutomatic-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        let database = root.appending(path: "index.sqlite"), endpoint = URL(string: "https://native-auto-" + UUID().uuidString.lowercased() + ".invalid/api")!
        self.database = database; self.endpoint = endpoint
        let account = nativeAutomaticAccount(endpoint: endpoint), scope = MediaAccountScope(session: account)
        self.scope = scope; self.account = account; otherAccount = nativeAutomaticAccount(endpoint: endpoint)
        let store = SQLiteLibraryIndexStore(databaseURL: database), port = NativeAutomaticPhotos()
        self.store = store; self.port = port
        let exporter = NativeAutomaticExporter(root: root.appending(path: "exports"), store: store, scope: scope)
        self.exporter = exporter
        let server = NativeAutomaticServer(endpoint: endpoint, ownerID: account.userID)
        self.server = server; NativeAutomaticProtocol.install(server, host: endpoint.host!)
        let manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NativeAutomaticProtocol.self]; return configuration
        })
        self.manager = manager
        let controller = Self.controller(store: store, port: port, exporter: exporter)
        self.controller = controller; controllers = [controller]
        manager.configure(session: account, endpoint: endpoint)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        if legacy {
            let selection = try PhotoBackupAlbumSelection(included: ["legacy-only"], excluded: [])
            try journal.applyAlbumScan(selection.scan([.init(id: "legacy-only", assets: [])]), allowCloud: cloud)
            try journal.setForegroundAutomaticEnabled(true)
        } else {
            try journal.applyLibraryScan(PhotoBackupLibraryScan.plan(port.assets), allowCloud: cloud)
            let id = try #require(journal.jobs.first?.id)
            try journal.update(id) { value in
                try value.begin(); try value.exported(); try value.recordPrimary(UUID(), duplicate: false, checksum: nativeAutomaticDigest); try value.confirmVerifiedReceipt()
            }
        }
        try await store.savePhotoBackups(journal, scope: scope)
        await controller.load(using: manager)
        await controller.automaticConditionsChanged(using: manager, scope: scope, active: false)?.value
    }

    private static func controller(store: SQLiteLibraryIndexStore, port: NativeAutomaticPhotos, exporter: NativeAutomaticExporter) -> PhotoBackupController {
        .init(store: store, exporter: exporter, albumLoader: {
            port.albumReads += 1; Issue.record("Native backup must not request album permission or selection"); throw LibraryWriteError.unavailable
        }, authorizationStatus: { port.authorization }, observeAutomaticPhotos: false, preflight: NativeAutomaticPreflight(),
        scanSource: .nativeLibrary, libraryScanner: { validate in try await port.scan(validate) }, candidateEvidence: { _, _ in [] })
    }

    func makeController() -> PhotoBackupController {
        let value = Self.controller(store: SQLiteLibraryIndexStore(databaseURL: database), port: port, exporter: exporter)
        controllers.append(value); return value
    }

    func activate() -> Task<Void, Never>? {
        track(controller.automaticConditionsChanged(using: manager, scope: scope, active: true))
    }

    func request() -> Task<Void, Never>? {
        track(controller.automaticLibraryChanged())
    }

    func track(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        guard let task else { return nil }
        tasks.append(task)
        observers.append(Task { [exporter] in await task.value; exporter.finished() })
        return task
    }

    func journal() async throws -> PhotoBackupJournal {
        try await SQLiteLibraryIndexStore(databaseURL: database).loadPhotoBackups(scope: scope)
    }

    func close() async {
        let retirements = controllers.map { $0.automaticConditionsChanged(using: manager, scope: manager.backupScope, active: false) }
        controllers.forEach { $0.cancel() }; tasks.forEach { $0.cancel() }; exporter.release(); exporter.finished()
        for task in retirements {
            await task?.value
        }
        for task in tasks {
            await task.value
        }
        for task in observers {
            await task.value
        }
        for value in controllers {
            await value.waitForCurrentWork()
        }
        manager.configure(session: nil, endpoint: nil)
        NativeAutomaticProtocol.remove(host: endpoint.host!)
        try? FileManager.default.removeItem(at: root)
    }
}

private nonisolated func nativeAutomaticAccount(endpoint: URL) -> AccountSession {
    .init(apiURL: endpoint, accessToken: "native-automatic-fixture", userID: UUID().uuidString.lowercased(), userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

@MainActor private final class NativeAutomaticExporter: PhotoBackupResourceExporting {
    struct Observation { let localID: String; let stage: PhotoBackupJob.Stage; let allowCloud: Bool }
    let root: URL
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    var hold = false
    private(set) var observations: [Observation] = []
    private(set) var directories: [URL] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false
    private var ended = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    init(root: URL, store: SQLiteLibraryIndexStore, scope: MediaAccountScope) {
        self.root = root; self.store = store; self.scope = scope
    }

    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        let saved = try await store.loadPhotoBackups(scope: scope)
        let job = try #require(saved.jobs.first { $0.source == source })
        observations.append(.init(localID: source.localID, stage: job.stage, allowCloud: allowCloud))
        if hold {
            await withCheckedContinuation { continuation in
                gate = continuation; held = true
                let pending = waiters; waiters = []; pending.forEach { $0.resume(returning: true) }
            }
        }
        // Deliberately returns a late synthetic resource after cancellation; the real Worker must reject it.
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appending(path: "synthetic.jpg"); try Data("abc".utf8).write(to: file)
        return .init(directory: directory, primary: .init(file: file, name: "synthetic.jpg"), motion: nil,
                     created: Date(timeIntervalSince1970: 100), modified: source.modifiedAt ?? Date(timeIntervalSince1970: 100), favorite: false)
    }

    func waitUntilHeld() async -> Bool {
        if held {
            return true
        }; if ended {
            return false
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        gate?.resume(); gate = nil
    }

    func finished() {
        ended = true
        let pending = waiters; waiters = []; pending.forEach { $0.resume(returning: false) }
    }
}

/// Holds the real account coordinator while the explicit consent setter is waiting to persist.
@MainActor private final class NativeAutomaticConsentGate {
    private enum Event: Hashable { case entry, consent }
    private var results: [Event: Bool] = [:]
    private var waiters: [Event: [CheckedContinuation<Bool, Never>]] = [:]
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        if released {
            return
        }
        await withCheckedContinuation { value in continuation = value; publish(.entry, true) }
    }

    func waitForEntry() async -> Bool {
        await wait(.entry)
    }

    func waitForConsent() async -> Bool {
        await wait(.consent)
    }

    func consentStarted(_ value: Bool) {
        publish(.consent, value)
    }

    func startFinished() {
        publish(.consent, false)
    }

    func operationFinished() {
        publish(.entry, false)
    }

    func release() {
        released = true; continuation?.resume(); continuation = nil
    }

    private func wait(_ event: Event) async -> Bool {
        if let value = results[event] {
            return value
        }
        return await withCheckedContinuation { waiters[event, default: []].append($0) }
    }

    private func publish(_ event: Event, _ value: Bool) {
        guard results[event] == nil else { return }
        results[event] = value
        let pending = waiters.removeValue(forKey: event) ?? []; pending.forEach { $0.resume(returning: value) }
    }
}

/// Counters are checksum-check / media POST / fresh asset GET / unexpected route.
private final nonisolated class NativeAutomaticServer: Sendable {
    let endpoint: URL
    let ownerID: String
    private struct State: Sendable { var counts = [0, 0, 0, 0]; var uploaded = false }
    private let state = Mutex(State())
    var counts: [Int] {
        state.withLock { $0.counts }
    }

    init(endpoint: URL, ownerID: String) {
        self.endpoint = endpoint; self.ownerID = ownerID
    }

    func reply(_ request: URLRequest) throws -> (Int, Data) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer native-automatic-fixture", let url = request.url else { throw URLError(.userAuthenticationRequired) }
        if request.httpMethod == "POST", url == endpoint.appending(path: "assets/bulk-upload-check") {
            struct Check: Decodable { struct Item: Decodable { let id: String; let checksum: String }; let assets: [Item] }
            let value = try JSONDecoder().decode(Check.self, from: Self.body(request)), item = try #require(value.assets.first)
            guard value.assets.count == 1, UUID(uuidString: item.id) != nil, item.checksum == nativeAutomaticHex else { throw URLError(.cannotDecodeContentData) }
            let duplicate = state.withLock { $0.counts[0] += 1; return $0.uploaded }
            let result: [String: Any] = duplicate
                ? ["id": item.id, "action": "reject", "assetId": nativeAutomaticRemote, "isTrashed": false]
                : ["id": item.id, "action": "accept"]
            return try (200, JSONSerialization.data(withJSONObject: ["results": [result]]))
        }
        if request.httpMethod == "POST", url == endpoint.appending(path: "assets") {
            guard request.value(forHTTPHeaderField: "x-immich-checksum") == nativeAutomaticHex,
                  request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true else { throw URLError(.cannotDecodeContentData) }
            state.withLock { $0.counts[1] += 1; $0.uploaded = true }
            return try (201, JSONSerialization.data(withJSONObject: ["id": nativeAutomaticRemote, "status": "created"]))
        }
        if request.httpMethod == "GET", url == endpoint.appending(path: "assets/" + nativeAutomaticRemote) {
            state.withLock { $0.counts[2] += 1 }
            let asset: [String: Any] = ["id": nativeAutomaticRemote, "ownerId": ownerID, "isFavorite": false, "visibility": "timeline", "isTrashed": false,
                                        "isOffline": false, "isEdited": false, "type": "IMAGE", "originalFileName": "synthetic.jpg", "checksum": nativeAutomaticDigest,
                                        "livePhotoVideoId": NSNull(), "exifInfo": NSNull()]
            return try (200, JSONSerialization.data(withJSONObject: asset))
        }
        state.withLock { $0.counts[3] += 1 }
        throw URLError(.unsupportedURL)
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let input = request.httpBodyStream else { throw URLError(.cannotDecodeRawData) }
        input.open(); defer { input.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 {
                return data
            }
            data.append(contentsOf: buffer.prefix(count)); guard data.count <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
        }
    }
}

private final nonisolated class NativeAutomaticProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: NativeAutomaticServer]>([:])
    private let stopped = Mutex(false)
    static func install(_ server: NativeAutomaticServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    static func remove(host: String) {
        _ = servers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let url = request.url, let server = Self.servers.withLock({ $0[url.host ?? ""] }) else { throw URLError(.badURL) }
            let (status, data) = try server.reply(request)
            guard !stopped.withLock({ $0 }), let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            if !stopped.withLock({ $0 }) {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
