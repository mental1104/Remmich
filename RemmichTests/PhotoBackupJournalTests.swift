import Foundation
import Testing
@testable import Remmich

/// 用真实账号SQLite文件验证冷恢复、部分Live Photo回执、账号隔离和删除后晚写，不访问PhotoKit或网络。
@Suite("Durable photo backup journal")
struct PhotoBackupJournalTests {
    /// 动态资源已确认、静态帧未确认时进程退出；新store恢复暂停并保留回执，重新验证后才完成。
    @Test func coldRestoreRetainsMotionWithoutClaimingCompleteBackup() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("first")
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        let source = PhotoBackupSource(localID: "synthetic-live", modifiedAt: Date(timeIntervalSince1970: 100), kind: .livePhoto)
        try journal.enqueue([source])
        let id = try #require(journal.jobs.first?.id)
        let motion = UUID()
        let primary = UUID()
        try journal.update(id) { job in try job.begin(); try job.exported(); try job.recordMotion(motion) }
        try await store.savePhotoBackups(journal, scope: scope)

        // 新actor和SQLite连接模拟进程冷启动，恢复不依赖原内存状态。
        let cold = SQLiteLibraryIndexStore(databaseURL: database)
        var restored = try await cold.loadPhotoBackups(scope: scope)
        restored.recoverInterrupted()
        #expect(restored.jobs.first?.stage == .paused)
        #expect(restored.jobs.first?.failure == .interrupted)
        #expect(restored.jobs.first?.motionAssetID == motion)
        #expect(restored.jobs.first?.primaryAssetID == nil)
        try await cold.savePhotoBackups(restored, scope: scope)
        try restored.update(id) { job in
            job.queueForVerification()
            try job.begin()
            try job.exported()
            try job.recordMotion(motion)
            try job.recordPrimary(primary, duplicate: true)
            try job.confirmVerifiedReceipt()
        }
        try await cold.savePhotoBackups(restored, scope: scope)
        let confirmed = try await store.loadPhotoBackups(scope: scope)
        #expect(confirmed.jobs.first?.stage == .completed)
        #expect(confirmed.jobs.first?.primaryAssetID == primary)
        #expect(confirmed.jobs.first?.primaryWasDuplicate == true)
        #expect(confirmed.jobs.first?.attempts == 2)
    }

    /// 相同数据库根的两个认证账号互不覆盖；删账号后旧日志不能重建目录或写进新账号。
    @Test func isolatesAccountsAndRejectsLateWritesAfterRemoval() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let first = backupTestScope("first")
        let second = backupTestScope("second")
        try await store.prepare(scope: first)
        try await store.prepare(scope: second)
        var firstJournal = PhotoBackupJournal(namespace: first.cacheNamespace)
        try firstJournal.enqueue([.init(localID: "first-only", modifiedAt: nil, kind: .photo)])
        var secondJournal = PhotoBackupJournal(namespace: second.cacheNamespace)
        try secondJournal.enqueue([.init(localID: "second-only", modifiedAt: nil, kind: .video)])
        try await store.savePhotoBackups(firstJournal, scope: first)
        try await store.savePhotoBackups(secondJournal, scope: second)
        await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.savePhotoBackups(firstJournal, scope: second) }
        try await store.removeAccount(namespace: first.cacheNamespace)
        await #expect(throws: CancellationError.self) { try await store.savePhotoBackups(firstJournal, scope: first) }
        let removed = try await store.loadPhotoBackups(scope: first)
        let retained = try await store.loadPhotoBackups(scope: second)
        #expect(removed.jobs.isEmpty)
        #expect(retained.jobs.map(\.source.localID) == ["second-only"])
        let removedPath = AccountStorageLayout(storageDirectory: root).catalog(namespace: first.cacheNamespace)
        #expect(!FileManager.default.fileExists(atPath: removedPath.path))
    }

    /// 明确新扫描重查已完成备份；源版本变化取消旧待执行项，保留输入顺序和单任务身份。
    @Test func rescansReverifyReceiptsAndNeverMixSourceVersions() throws {
        var journal = PhotoBackupJournal(namespace: "synthetic")
        let first = PhotoBackupSource(localID: "photo", modifiedAt: Date(timeIntervalSince1970: 1), kind: .photo)
        let second = PhotoBackupSource(localID: "video", modifiedAt: nil, kind: .video)
        #expect(try journal.enqueue([first, second, first]) == 2)
        #expect(journal.jobs.map(\.source) == [first, second])
        let id = try #require(journal.jobs.first?.id)
        try journal.update(id) { job in
            try job.begin(); try job.exported(); try job.recordPrimary(UUID(), duplicate: false); try job.confirmVerifiedReceipt()
        }
        #expect(try journal.enqueue([first]) == 1)
        #expect(journal.jobs.first?.id == id && journal.jobs.first?.stage == .queued)
        let changed = PhotoBackupSource(localID: first.localID, modifiedAt: Date(timeIntervalSince1970: 2), kind: .photo)
        try journal.enqueue([changed])
        #expect(journal.jobs.first?.stage == .cancelled)
        #expect(journal.jobs.last?.source == changed && journal.jobs.last?.stage == .queued)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try journal.enqueue([first, changed]) }
    }

    /// 单独动态资源或未核对静态帧不能完成；未来日志版本也不能被静默清空覆盖。
    @Test func rejectsIncompletePairAndUnknownJournalVersion() throws {
        var job = PhotoBackupJob(source: .init(localID: "live", modifiedAt: nil, kind: .livePhoto))
        try job.begin()
        try job.exported()
        #expect(throws: PhotoBackupStateError.invalidTransition) { try job.recordPrimary(UUID(), duplicate: true) }
        #expect(throws: PhotoBackupStateError.invalidTransition) { try job.confirmVerifiedReceipt() }
        try job.recordMotion(UUID())
        try job.recordPrimary(UUID(), duplicate: true)
        job.fail(.livePhotoMismatch)
        #expect(job.stage == .failed && job.failure == .livePhotoMismatch)
        let encoded = #"{"version":2,"namespace":"synthetic","selectedAlbumIDs":[],"allowCloud":false,"jobs":[]}"#
        let future = try JSONDecoder().decode(PhotoBackupJournal.self, from: Data(encoded.utf8))
        #expect(throws: PhotoBackupStateError.invalidJournal) { try future.validate(namespace: "synthetic") }
    }
}

/// 返回本测试独占目录；所有SQLite和缓存文件都在此目录内，结束后统一回收。
private nonisolated func backupTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "BackupJournalTests-\(UUID().uuidString)")
}

/// user仅区分合成身份；复用真实MediaAccountScope规则，同一服务不同用户必须使用不同namespace。
private nonisolated func backupTestScope(_ user: String) -> MediaAccountScope {
    .init(session: .init(apiURL: URL(string: "https://backup.example.invalid/api")!, accessToken: "synthetic",
                         userID: user, userEmail: "\(user)@example.invalid", name: user, isAdmin: false,
                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
}
