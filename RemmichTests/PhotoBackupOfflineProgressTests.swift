import Foundation
import Testing
@testable import Remmich

@Suite("Offline saved backup progress")
@MainActor struct PhotoBackupOfflineProgressTests {
    @Test func disconnectedAccountRestoresSavedProgressWithoutQueueingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OfflineBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try AccountSession(apiURL: #require(URL(string: "https://offline.example.invalid/api")), accessToken: "synthetic",
                                         userID: "11111111-1111-4111-8111-111111111111", userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([.init(localID: "matched", modifiedAt: Date(timeIntervalSince1970: 100), kind: .photo),
                             .init(localID: "pending", modifiedAt: Date(timeIntervalSince1970: 100), kind: .photo)])
        let first = journal.jobs[0].id, second = journal.jobs[1].id
        try journal.update(first) { try $0.confirmExistingMatch() }
        try journal.update(second) { $0.pause() }
        try await store.savePhotoBackups(journal, scope: scope)
        let manager = LibraryManagementController()
        manager.configure(session: session, endpoint: nil)
        let controller = PhotoBackupController(store: store, observeAutomaticPhotos: false)
        await controller.load(using: manager)
        #expect(manager.client == nil && manager.backupScope == nil)
        #expect(controller.jobs.map(\.stage) == [.existing, .paused])
        #expect(controller.unattemptedSummary.matched == 1 && !controller.running)
        let saved = try await store.loadPhotoBackups(scope: scope)
        #expect(saved.jobs.map(\.id) == journal.jobs.map(\.id) && saved.jobs.map(\.stage) == [.existing, .paused])
    }
}
