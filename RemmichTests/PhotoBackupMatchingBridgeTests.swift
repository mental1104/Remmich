import Foundation
import Synchronization
import Testing
@testable import Remmich

/// Real controller/client/namespace SQLite; only Photos observations and HTTP transport are synthetic.
@Suite("Original backup evidence matching bridge", .serialized)
@MainActor struct PhotoBackupMatchingBridgeTests {
    @Test func completedOriginalEvidenceRefreshesTerminalMatchingOnce() async throws {
        try await withMatchingBridge { fixture in
            let initialRequests = fixture.http.counts
            #expect(initialRequests.streams == 1 && initialRequests.acks == 1)
            let ordinary = try #require(fixture.matches.resumeFullLibraryMatching(using: fixture.manager, userInitiated: false))
            await ordinary.value
            #expect(fixture.http.counts.streams == 1)
            let refresh = try #require(fixture.matches.originalBackupEvidenceDidChange(using: fixture.manager))
            await refresh.value
            let progress = try await fixture.store.progress(scope: fixture.scope)
            #expect(fixture.http.counts.streams == 2 && fixture.http.counts.acks == 2 && fixture.http.counts.unexpected == 0)
            #expect(fixture.matches.fullLibraryReconciler?.state == .needsReview)
            #expect(progress.phase == .needsReview && progress.totalLocal == 1 && progress.processedLocal == 1 && progress.pendingLocal == 1)
            #expect(fixture.inventory.authorizationRequests == 1 && fixture.checksum.calls == 0)
            let terminal = try #require(fixture.matches.resumeFullLibraryMatching(using: fixture.manager, userInitiated: false))
            await terminal.value
            #expect(fixture.http.counts.streams == 2)
        }
    }

    @Test func completedOriginalEvidencePreservesExplicitMatchingPause() async throws {
        try await withMatchingBridge { fixture in
            fixture.matches.pauseFullLibraryMatching()
            let before = fixture.http.counts
            let refresh = fixture.matches.originalBackupEvidenceDidChange(using: fixture.manager)
            #expect(refresh == nil && UserDefaults.standard.bool(forKey: fixture.pauseKey))
            let foreground = fixture.matches.resumeFullLibraryMatching(using: fixture.manager, userInitiated: false)
            await foreground?.value
            #expect(UserDefaults.standard.bool(forKey: fixture.pauseKey))
            #expect(fixture.http.counts.streams == before.streams && fixture.http.counts.acks == before.acks && fixture.http.counts.unexpected == 0)
            #expect(fixture.inventory.authorizationRequests == 1 && fixture.checksum.calls == 0)
        }
    }

    @Test func retiredAccountCannotPublishOriginalEvidenceRefresh() async throws {
        try await withMatchingBridge { fixture in
            let before = fixture.http.counts
            fixture.manager.configure(session: fixture.otherAccount, endpoint: fixture.endpoint)
            #expect(fixture.manager.backupScope != fixture.scope)
            let refresh = fixture.matches.originalBackupEvidenceDidChange(using: fixture.manager)
            #expect(refresh == nil)
            #expect(fixture.http.counts.streams == before.streams && fixture.http.counts.acks == before.acks && fixture.http.counts.unexpected == 0)
            #expect(fixture.inventory.authorizationRequests == 1 && fixture.checksum.calls == 0)
        }
    }
}

@MainActor private func withMatchingBridge(_ body: @MainActor (MatchingBridgeFixture) async throws -> Void) async throws {
    let fixture = MatchingBridgeFixture()
    do {
        try await fixture.start()
        try await body(fixture)
        await fixture.close()
    } catch {
        await fixture.close()
        throw error
    }
}

@MainActor private final class MatchingBridgeFixture {
    let directory: URL
    let endpoint: URL
    let account: AccountSession
    let otherAccount: AccountSession
    let scope: MediaAccountScope
    let store: LocalPhotoDisplayReconciliationStore
    let manager: LibraryManagementController
    let matches: LocalMediaMatchController
    let inventory: MatchingBridgeInventory
    let checksum: MatchingBridgeNoChecksum
    let http: MatchingBridgeHTTPState
    var pauseKey: String {
        "LocalPhotoDisplayReconciliation.userPaused." + scope.cacheNamespace
    }

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PhotoBackupMatchingBridge-" + UUID().uuidString, directoryHint: .isDirectory)
        self.directory = directory
        let inventory = MatchingBridgeInventory(), checksum = MatchingBridgeNoChecksum(), http = MatchingBridgeHTTPState()
        self.inventory = inventory; self.checksum = checksum; self.http = http
        let endpoint = URL(string: "https://backup-matching-" + UUID().uuidString.lowercased() + ".invalid/api")!
        self.endpoint = endpoint
        let account = matchingBridgeAccount(endpoint: endpoint)
        self.account = account
        otherAccount = matchingBridgeAccount(endpoint: endpoint)
        scope = MediaAccountScope(session: account)
        let store = LocalPhotoDisplayReconciliationStore(directory: directory.appending(path: "display", directoryHint: .isDirectory))
        self.store = store
        MatchingBridgeURLProtocol.install(http, host: endpoint.host!)
        let manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MatchingBridgeURLProtocol.self]
            return configuration
        })
        self.manager = manager
        matches = LocalMediaMatchController(inventory: inventory, metadata: MatchingBridgeMetadata(), checksum: checksum,
                                            persistence: LocalMediaAssociationStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory)),
                                            displayPersistence: LocalPhotoDisplayAssociationStore(reconciliationStore: store), observeChanges: false,
                                            reconciliationStore: store)
        manager.configure(session: account, endpoint: endpoint)
    }

    func start() async throws {
        let task = try #require(matches.resumeFullLibraryMatching(using: manager))
        await task.value
        #expect(matches.fullLibraryReconciler?.state == .needsReview)
        let progress = try await store.progress(scope: scope)
        #expect(progress.totalLocal == 1 && progress.processedLocal == 1 && progress.pendingLocal == 1)
        #expect(http.counts.streams == 1 && http.counts.acks == 1 && http.counts.unexpected == 0)
    }

    func close() async {
        matches.suspendFullLibraryMatching()
        await matches.fullLibraryReconciler?.waitForRetirement()
        manager.configure(session: nil, endpoint: nil)
        MatchingBridgeURLProtocol.remove(host: endpoint.host!)
        // Only this fixture's random account/endpoint namespace is removed.
        UserDefaults.standard.removeObject(forKey: pauseKey)
        try? FileManager.default.removeItem(at: directory)
    }
}

private nonisolated func matchingBridgeAccount(endpoint: URL) -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic-matching-bridge", userID: UUID().uuidString.lowercased(),
          userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// No cloud identity means the real worker never invokes its default reverse PhotoKit resolver.
@MainActor private final class MatchingBridgeInventory: LocalPhotoInventoryReading {
    var authorization: LocalPhotoLibraryAccess {
        .full
    }

    private(set) var authorizationRequests = 0
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorizationRequests += 1; return .full
    }

    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try Task.checkCancellation(); try validateContext()
        return ["synthetic-matching-bridge-item"]
    }
}

@MainActor private struct MatchingBridgeMetadata: LocalPhotoMetadataReading {
    func snapshots(for ids: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try Task.checkCancellation(); try validateContext()
        #expect(ids.count <= 64 && ids.allSatisfy { $0 == "synthetic-matching-bridge-item" })
        return ids.map { id in
            .init(identity: .init(localIdentifier: id, modificationDate: Date(timeIntervalSince1970: 200), mediaKind: .image),
                  creationDate: Date(timeIntervalSince1970: 100), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
                  pixelWidth: 10, pixelHeight: 10, duration: 0, mediaSubtypes: 0, resources: [], cloudIdentity: .unavailable)
        }
    }
}

@MainActor private final class MatchingBridgeNoChecksum: LocalPhotoChecksumReading {
    private(set) var calls = 0
    func checksum(for _: LocalPhotoSnapshot, validateContext _: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        calls += 1
        Issue.record("Metadata-only matching must not read original bytes")
        throw LibraryWriteError.unavailable
    }
}

private final nonisolated class MatchingBridgeHTTPState: Sendable {
    struct Counts: Sendable { var acks = 0; var streams = 0; var unexpected = 0 }
    private let values = Mutex(Counts())
    var counts: Counts {
        values.withLock { $0 }
    }

    func response(to request: URLRequest) throws -> (String, Data) {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/sync/ack"):
            values.withLock { $0.acks += 1 }
            return ("application/json", Data("[]".utf8))
        case ("POST", "/api/sync/stream"):
            values.withLock { $0.streams += 1 }
            let complete = #"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|11111111-1111-4111-8111-111111111111"}"# + "\n"
            return ("application/jsonlines+json", Data(complete.utf8))
        default:
            values.withLock { $0.unexpected += 1 }
            throw URLError(.unsupportedURL)
        }
    }
}

/// This URLSession-only transport intercepts every request; unknown hosts never reach the network.
private final nonisolated class MatchingBridgeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let states = Mutex<[String: MatchingBridgeHTTPState]>([:])
    static func install(_ state: MatchingBridgeHTTPState, host: String) {
        states.withLock { $0[host] = state }
    }

    static func remove(host: String) {
        _ = states.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let host = request.url?.host, let state = Self.states.withLock({ $0[host] }), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let (mime, data) = try state.response(to: request)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime]) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
