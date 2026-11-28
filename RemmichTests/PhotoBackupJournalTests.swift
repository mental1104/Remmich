import Foundation
import SQLite3
import Testing
@testable import Remmich

/// 用真实账号SQLite文件验证冷恢复、部分Live Photo回执、账号隔离和删除后晚写，不访问PhotoKit或网络。
@Suite("Durable photo backup journal")
struct PhotoBackupJournalTests {
    @Test @MainActor func nativeForegroundConsentPersistsInTheHeaderWithoutRewritingJobs() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("native-consent"), url = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        let source = PhotoBackupSource(localID: "native-original", modifiedAt: .distantPast, kind: .photo)
        try journal.applyLibraryScan(PhotoBackupLibraryScan.plan([.init(source: source, capturedAt: .distantPast)]), allowCloud: true)
        try await store.savePhotoBackups(journal, scope: scope)
        #expect(try await store.photoBackupNativeForegroundEnabled(scope: scope) == false)
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        let before = try probe.rows("SELECT job_id,position,stage,payload FROM photo_backup_jobs ORDER BY position")
        for event in ["INSERT", "UPDATE", "DELETE"] {
            try probe.execute("CREATE TRIGGER reject_native_job_\(event) BEFORE \(event) ON photo_backup_jobs BEGIN SELECT RAISE(ABORT,'native consent rewrote jobs'); END")
        }
        try await store.updatePhotoBackupAutomationSettings(scope: scope, nativeForeground: true)
        // Unrelated legacy setting saves must retain the explicit native flag and version.
        try await store.updatePhotoBackupAutomationSettings(scope: scope, foreground: false, background: false, networkRecovery: false)
        let cold = SQLiteLibraryIndexStore(databaseURL: url)
        let enabled = try await cold.loadPhotoBackups(scope: scope)
        #expect(enabled.version == 5 && enabled.nativeForegroundBackupEnabled == true && enabled.allowCloud)
        #expect(try await cold.photoBackupNativeForegroundEnabled(scope: scope))
        #expect(try await cold.photoBackupNativeForegroundEnabled(scope: backupTestScope("other-native-account")) == false)
        try await store.updatePhotoBackupAutomationSettings(scope: scope, nativeForeground: false)
        let stopped = try await cold.loadPhotoBackups(scope: scope)
        #expect(stopped.version == 5 && stopped.nativeForegroundBackupEnabled == false && stopped.allowCloud)
        #expect(try await cold.photoBackupNativeForegroundEnabled(scope: scope) == false)
        #expect(try probe.rows("SELECT job_id,position,stage,payload FROM photo_backup_jobs ORDER BY position") == before)
        var stoppedPlan = stopped
        #expect(throws: PhotoBackupStateError.invalidTransition) {
            try stoppedPlan.applyNativeAutomaticLibraryScan(PhotoBackupLibraryScan.plan([.init(source: source, capturedAt: .distantPast)]))
        }
    }

    @Test @MainActor func versionFiveRawJPEGKeepsItsHotWriteAndMatchingCheckpointPaths() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("native-v5-raw"), url = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        try await store.prepare(scope: scope)
        let pair = try PhotoBackupRawJPEGSource(originals: [
            .init(kind: .photo, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 100, pixelHeight: 100),
            .init(kind: .alternatePhoto, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 100, pixelHeight: 100),
        ], hasAdjustments: false, adjustmentTime: nil)
        let sources = ["raw-hot", "raw-matched"].map { PhotoBackupSource(localID: $0, modifiedAt: .distantPast, kind: .rawJPEG, rawJPEG: pair) }
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.applyLibraryScan(PhotoBackupLibraryScan.plan(sources.map { .init(source: $0, capturedAt: .distantPast) }), allowCloud: false)
        try journal.setNativeForegroundBackupEnabled(true)
        try await store.savePhotoBackups(journal, scope: scope)
        var raw = journal.jobs[0]
        try raw.begin(); try raw.exported()
        let receipt = try PhotoBackupImageReceipt(assetID: UUID(), checksum: Data(repeating: 1, count: 20).base64EncodedString(), duplicate: true)
        try raw.recordImage(receipt, role: .raw)
        try await store.savePhotoBackupJob(raw, scope: scope)
        try await store.checkpointPhotoBackupMatches([journal.jobs[1]], scope: scope)
        let cold = SQLiteLibraryIndexStore(databaseURL: url)
        let saved = try await cold.loadPhotoBackups(scope: scope)
        #expect(saved.version == 5 && saved.nativeForegroundBackupEnabled == true)
        #expect(saved.jobs[0].stage == .uploadingPrimary && saved.jobs[0].rawReceipt == receipt && saved.jobs[0].jpegReceipt == nil)
        #expect(saved.jobs[1].stage == .existing && saved.jobs[1].rawReceipt == nil && saved.jobs[1].jpegReceipt == nil)
        #expect(saved.jobs.allSatisfy { $0.stage != .completed })
    }

    /// 第二行失去queued资格时必须回滚第一行；成功批次只改变选中任务，冷连接看到相同边界。
    @Test func matchingCheckpointIsAtomicAndKeepsOtherJobs() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("match-checkpoint"), url = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue((0 ..< 3).map { .init(localID: "checkpoint-\($0)", modifiedAt: nil, kind: .photo) })
        try await store.savePhotoBackups(journal, scope: scope)
        var held = journal.jobs[1]; held.pause()
        try await store.savePhotoBackupJob(held, scope: scope)
        await #expect(throws: PhotoBackupStateError.invalidTransition) {
            try await store.checkpointPhotoBackupMatches(Array(journal.jobs.prefix(2)), scope: scope)
        }
        let cold = SQLiteLibraryIndexStore(databaseURL: url)
        let unchanged = try await cold.loadPhotoBackups(scope: scope)
        #expect(unchanged.jobs.map(\.stage) == [.queued, .paused, .queued])
        try await store.checkpointPhotoBackupMatches([journal.jobs[0], journal.jobs[2]], scope: scope)
        let saved = try await cold.loadPhotoBackups(scope: scope)
        #expect(saved.jobs.map(\.stage) == [.existing, .paused, .existing])
        #expect(saved.jobs.map(\.id) == journal.jobs.map(\.id))
        #expect(saved.jobs.allSatisfy { $0.attempts == 0 && $0.primaryAssetID == nil })
    }

    /// 开关保存不得重写任何任务；真实SQLite触发器拒绝INSERT/UPDATE/DELETE，保留回执和范围。
    @Test func automationSettingsOnlyWriteTheHeader() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("header-settings")
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        journal.selectedAlbumIDs = ["synthetic-selected"]
        journal.allowCloud = true
        try journal.enqueue((0 ..< 512).map { .init(localID: "synthetic-\($0)", modifiedAt: nil, kind: .photo) })
        try journal.update(journal.jobs[0].id) { job in
            try job.begin(); try job.exported(); try job.recordPrimary(UUID(), duplicate: true)
        }
        try await store.savePhotoBackups(journal, scope: scope)
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        let before = try probe.rows("SELECT job_id,position,stage,payload FROM photo_backup_jobs ORDER BY position")
        for event in ["INSERT", "UPDATE", "DELETE"] {
            try probe.execute("CREATE TRIGGER reject_job_\(event) BEFORE \(event) ON photo_backup_jobs BEGIN SELECT RAISE(ABORT,'settings rewrote jobs'); END")
        }
        try await store.updatePhotoBackupAutomationSettings(scope: scope, foreground: true, background: true, networkRecovery: true)
        try await store.updatePhotoBackupAutomationSettings(scope: scope, foreground: false, background: false)
        let saved = try await store.loadPhotoBackups(scope: scope)
        #expect(saved.foregroundAutomaticEnabled == false && saved.backgroundAutomaticEnabled == false)
        #expect(saved.foregroundNetworkRecoveryEnabled == true)
        #expect(saved.allowCloud && saved.selectedAlbumIDs == journal.selectedAlbumIDs)
        #expect(try probe.rows("SELECT job_id,position,stage,payload FROM photo_backup_jobs ORDER BY position") == before)
        try probe.execute("UPDATE photo_backup_headers SET payload=json_set(payload,'$.version',99)")
        await #expect(throws: PhotoBackupStateError.invalidJournal) {
            try await store.updatePhotoBackupAutomationSettings(scope: scope, foreground: false)
        }
        try await store.removeAccount(namespace: scope.cacheNamespace)
        await #expect(throws: CancellationError.self) {
            try await store.updatePhotoBackupAutomationSettings(scope: scope, background: false)
        }
    }

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
        #expect(confirmed.jobs.first?.primaryChecksum == nil)
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
        let encoded = #"{"version":3,"namespace":"synthetic","selectedAlbumIDs":[],"allowCloud":false,"jobs":[]}"#
        let future = try JSONDecoder().decode(PhotoBackupJournal.self, from: Data(encoded.utf8))
        #expect(throws: PhotoBackupStateError.invalidJournal) { try future.validate(namespace: "synthetic") }
    }

    /// 512项扫描后连续保存Live Photo五个检查点；SQLite触发器证明仅更新该行，其他payload/位置及header未重写。
    @Test func individualCheckpointsOnlyWriteTheExistingJob() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("row-checkpoints")
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        journal.selectedAlbumIDs = ["selected-synthetic"]
        journal.allowCloud = true
        try journal.enqueue((0 ..< 512).map { .init(localID: "source-\($0)", modifiedAt: nil, kind: $0 == 0 ? .livePhoto : .photo) })
        try await store.savePhotoBackups(journal, scope: scope)
        let files = await store.databaseFiles(scope: scope)
        let probe = try BackupJournalSQLProbe(url: files.catalog)
        let before = try probe.rows("SELECT job_id,position,payload FROM photo_backup_jobs ORDER BY position")
        try probe.execute("CREATE TABLE backup_test_writes(kind TEXT NOT NULL,job_id TEXT NOT NULL)")
        for event in ["UPDATE", "INSERT", "DELETE"] {
            let owner = event == "DELETE" ? "OLD" : "NEW"
            try probe.execute("CREATE TRIGGER backup_test_\(event) AFTER \(event) ON photo_backup_jobs BEGIN INSERT INTO backup_test_writes VALUES('\(event)',\(owner).job_id); END")
        }
        try probe.execute("CREATE TRIGGER backup_test_header AFTER UPDATE ON photo_backup_headers BEGIN INSERT INTO backup_test_writes VALUES('HEADER','header'); END")
        var job = try #require(try await store.nextQueuedPhotoBackup(scope: scope))
        let id = job.id
        let motion = UUID()
        try job.begin()
        try await store.savePhotoBackupJob(job, scope: scope)
        try job.exported()
        try await store.savePhotoBackupJob(job, scope: scope)
        try job.recordMotion(motion)
        try await store.savePhotoBackupJob(job, scope: scope)
        try job.recordPrimary(UUID(), duplicate: true)
        try await store.savePhotoBackupJob(job, scope: scope)
        try job.confirmVerifiedReceipt()
        try await store.savePhotoBackupJob(job, scope: scope)

        #expect(try probe.rows("SELECT kind,job_id FROM backup_test_writes ORDER BY rowid") == Array(repeating: ["UPDATE", id.uuidString], count: 5))
        let after = try probe.rows("SELECT job_id,position,payload FROM photo_backup_jobs ORDER BY position")
        #expect(Array(after.dropFirst()) == Array(before.dropFirst()))
        #expect(after.first?.prefix(2) == before.first?.prefix(2))
        #expect(try await store.nextQueuedPhotoBackup(scope: scope)?.source.localID == "source-1")
        let plan = try probe.rows("EXPLAIN QUERY PLAN SELECT job_id,stage,payload FROM photo_backup_jobs WHERE scope=? AND stage='queued' ORDER BY position LIMIT 1", [scope.cacheNamespace])
        #expect(plan.contains { $0.last?.contains("photo_backup_jobs_queue") == true })
        #expect(!plan.contains { $0.last?.contains("TEMP B-TREE") == true })
        let cold = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let restored = try await cold.loadPhotoBackups(scope: scope)
        #expect(restored.jobs.map(\.id) == journal.jobs.map(\.id))
        #expect(restored.selectedAlbumIDs == journal.selectedAlbumIDs && restored.allowCloud)
        #expect(restored.jobs.first?.stage == .completed && restored.jobs.first?.motionAssetID == motion)
    }

    /// 冷恢复只暂停in-flight；显式停止还暂停queued，已确认回执和完成/失败/取消历史均不改写。
    @Test func indexedRecoveryAndPausePreserveReceiptsAndOtherHistory() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("row-recovery")
        let url = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue((0 ..< 6).map { .init(localID: "source-\($0)", modifiedAt: nil, kind: $0 == 0 ? .livePhoto : .photo) })
        let ids = journal.jobs.map(\.id)
        let motion = UUID()
        try journal.update(ids[0]) { job in try job.begin(); try job.exported(); try job.recordMotion(motion) }
        try journal.update(ids[1]) { try $0.begin() }
        try journal.update(ids[3]) { job in try job.begin(); try job.exported(); try job.recordPrimary(UUID(), duplicate: false); try job.confirmVerifiedReceipt() }
        try journal.update(ids[4]) { $0.fail(.network) }
        try journal.update(ids[5]) { $0.cancel() }
        try await store.savePhotoBackups(journal, scope: scope)
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        let history = try probe.rows("SELECT job_id,position,payload FROM photo_backup_jobs WHERE position>=3 ORDER BY position")
        let cold = SQLiteLibraryIndexStore(databaseURL: url)
        try await cold.recoverPhotoBackupWork(scope: scope)
        let recovered = try await cold.loadPhotoBackups(scope: scope)
        #expect(recovered.jobs.map(\.stage) == [.paused, .paused, .queued, .completed, .failed, .cancelled])
        #expect(recovered.jobs[0].motionAssetID == motion && recovered.jobs[0].primaryAssetID == nil)
        #expect(recovered.jobs[0].failure == .interrupted && recovered.jobs[1].failure == .interrupted)
        #expect(try await cold.nextQueuedPhotoBackup(scope: scope)?.id == ids[2])
        try await cold.pausePhotoBackupWork(scope: scope)
        #expect(try await cold.nextQueuedPhotoBackup(scope: scope) == nil)
        let paused = try await cold.loadPhotoBackups(scope: scope)
        #expect(paused.jobs.map(\.stage) == [.paused, .paused, .paused, .completed, .failed, .cancelled])
        #expect(paused.jobs[0].motionAssetID == motion && paused.jobs[0].failure == .interrupted)
        #expect(paused.jobs[2].failure == nil)
        #expect(try probe.rows("SELECT job_id,position,payload FROM photo_backup_jobs WHERE position>=3 ORDER BY position") == history)
    }

    /// 单项保存既不能创建未扫描任务、替换源版本，也不能写入另一账号或在删除后恢复旧记录。
    @Test func individualWritesRejectUnknownSourceAndDeletedAccount() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("known")
        let other = backupTestScope("other")
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        try await store.prepare(scope: other)
        let source = PhotoBackupSource(localID: "synthetic", modifiedAt: nil, kind: .photo)
        let unknown = PhotoBackupJob(source: source)
        await #expect(throws: PhotoBackupStateError.invalidTransition) { try await store.savePhotoBackupJob(unknown, scope: scope) }
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([source])
        try await store.savePhotoBackups(journal, scope: scope)
        var job = try #require(try await store.nextQueuedPhotoBackup(scope: scope))
        let changed = PhotoBackupJob(source: .init(localID: source.localID, modifiedAt: Date(timeIntervalSince1970: 1), kind: .photo), id: job.id)
        await #expect(throws: PhotoBackupStateError.invalidTransition) { try await store.savePhotoBackupJob(changed, scope: scope) }
        await #expect(throws: PhotoBackupStateError.invalidTransition) { try await store.savePhotoBackupJob(job, scope: other) }
        try job.begin()
        try await store.savePhotoBackupJob(job, scope: scope)
        try await store.removeAccount(namespace: scope.cacheNamespace)
        await #expect(throws: CancellationError.self) { try await store.savePhotoBackupJob(job, scope: scope) }
        try await store.pausePhotoBackupWork(scope: scope)
        try await store.recoverPhotoBackupWork(scope: scope)
        #expect(try await store.nextQueuedPhotoBackup(scope: scope) == nil)
        #expect(try await store.loadPhotoBackups(scope: scope).jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: AccountStorageLayout(storageDirectory: root).catalog(namespace: scope.cacheNamespace).path))
        // 同账号重新认证后即使目录重新存在，旧单项检查点也不能插入它自己。
        try await store.recordAccountIdentity(backupTestSession("known"))
        await #expect(throws: PhotoBackupStateError.invalidTransition) { try await store.savePhotoBackupJob(job, scope: scope) }
        #expect(try await store.nextQueuedPhotoBackup(scope: scope) == nil)
    }

    /// 已有旧blob同事务转成独立行并保留全部身份/次序/部分回执；后续冷读不重复插入或退回旧快照。
    @Test func convertsLegacyBlobOnceWithoutDiscardingRecoveryData() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("legacy")
        let url = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        journal.selectedAlbumIDs = ["synthetic-album"]
        try journal.enqueue([.init(localID: "first", modifiedAt: nil, kind: .livePhoto), .init(localID: "second", modifiedAt: nil, kind: .photo)])
        let id = try #require(journal.jobs.first?.id)
        let motion = UUID()
        try journal.update(id) { job in try job.begin(); try job.exported(); try job.recordMotion(motion) }
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        let json = try String(decoding: JSONEncoder().encode(journal), as: UTF8.self)
        try probe.insertLegacy(json: json, namespace: scope.cacheNamespace)
        let restored = try await store.loadPhotoBackups(scope: scope)
        #expect(restored.jobs.map(\.id) == journal.jobs.map(\.id))
        #expect(restored.selectedAlbumIDs == journal.selectedAlbumIDs && restored.jobs[0].motionAssetID == motion)
        #expect(try probe.rows("SELECT payload FROM photo_backups").isEmpty)
        #expect(try probe.rows("SELECT job_id FROM photo_backup_jobs ORDER BY position").map { $0[0] } == journal.jobs.map(\.id.uuidString))
        let cold = SQLiteLibraryIndexStore(databaseURL: url)
        try await cold.recoverPhotoBackupWork(scope: scope)
        #expect(try await store.loadPhotoBackups(scope: scope).jobs[0].stage == .paused)
        #expect(try await store.nextQueuedPhotoBackup(scope: scope)?.source.localID == "second")
    }

    /// future/corrupt旧blob及future新header都必须阻止读写，不得借bulk或单项保存覆盖尚可恢复的原始资料。
    @Test(arguments: ["future-legacy", "corrupt-legacy", "future-header"])
    func refusesUnknownOrCorruptRecoveryFormats(_ format: String) async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope(format)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([.init(localID: "synthetic", modifiedAt: nil, kind: .photo)])
        let job = try #require(journal.jobs.first)
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        let json: String
        let table: String
        if format == "future-header" {
            try await store.savePhotoBackups(journal, scope: scope)
            json = #"{"version":3,"namespace":"\#(scope.cacheNamespace)","selectedAlbumIDs":[],"allowCloud":false}"#
            table = "photo_backup_headers"
            try probe.execute("UPDATE photo_backup_headers SET payload=?", [json])
        } else {
            json = format == "future-legacy"
                ? #"{"version":3,"namespace":"\#(scope.cacheNamespace)","selectedAlbumIDs":[],"allowCloud":false,"jobs":[]}"# : "{damaged"
            table = "photo_backups"
            try probe.insertLegacy(json: json, namespace: scope.cacheNamespace)
        }
        if format == "corrupt-legacy" {
            await #expect(throws: DecodingError.self) { try await store.loadPhotoBackups(scope: scope) }
            await #expect(throws: DecodingError.self) { try await store.savePhotoBackups(journal, scope: scope) }
            await #expect(throws: DecodingError.self) { try await store.savePhotoBackupJob(job, scope: scope) }
            await #expect(throws: DecodingError.self) { try await store.nextQueuedPhotoBackup(scope: scope) }
            await #expect(throws: DecodingError.self) { try await store.pausePhotoBackupWork(scope: scope) }
            await #expect(throws: DecodingError.self) { try await store.recoverPhotoBackupWork(scope: scope) }
        } else {
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.loadPhotoBackups(scope: scope) }
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.savePhotoBackups(journal, scope: scope) }
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.savePhotoBackupJob(job, scope: scope) }
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.nextQueuedPhotoBackup(scope: scope) }
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.pausePhotoBackupWork(scope: scope) }
            await #expect(throws: PhotoBackupStateError.invalidJournal) { try await store.recoverPhotoBackupWork(scope: scope) }
        }
        #expect(try probe.rows("SELECT payload FROM \(table)") == [[json]])
    }

    /// 新行格式损坏时，冷读和批量保存均失败；原始payload不能被空快照覆盖，方便后续明确恢复。
    @Test func bulkReplacementPreservesCorruptExistingJobRows() async throws {
        let root = backupTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = backupTestScope("corrupt-row")
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([.init(localID: "synthetic", modifiedAt: nil, kind: .photo)])
        try await store.savePhotoBackups(journal, scope: scope)
        let probe = try await BackupJournalSQLProbe(url: store.databaseFiles(scope: scope).catalog)
        try probe.execute("UPDATE photo_backup_jobs SET payload=?", ["{damaged"])
        await #expect(throws: DecodingError.self) { try await store.loadPhotoBackups(scope: scope) }
        await #expect(throws: DecodingError.self) { try await store.savePhotoBackups(.init(namespace: scope.cacheNamespace), scope: scope) }
        #expect(try probe.rows("SELECT payload FROM photo_backup_jobs") == [["{damaged"]])
    }
}

/// 独立SQLite观察连接只供合成测试使用；直接观察实际写事件/执行计划，避免用生产实现的返回值自证未重写。
private final nonisolated class BackupJournalSQLProbe {
    private let handle: OpaquePointer

    /// url为测试独占账号catalog，打开失败立即终止断言；不创建生产目录或访问网络。
    init(url: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw PhotoBackupStateError.invalidJournal
        }
        handle = opened
    }

    /// 释放独立测试观察连接，真实store的连接仍由原actor管理。
    deinit { sqlite3_close(handle) }

    /// sql/values只来自本测试的合成输入；执行完整语句并要求SQLITE_DONE，不吞SQL错误。
    func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
    }

    /// 返回所有列的文本，供精确比较payload/顺序/触发器事件；NULL只用于计划文本时视为空串。
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return output
            }
            try #require(status == SQLITE_ROW)
            output.append((0 ..< sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    /// json/namespace模拟已有版本1单行格式；插入原文以证明转换失败时没有删除或改写恢复资料。
    func insertLegacy(json: String, namespace: String) throws {
        try execute("CREATE TABLE IF NOT EXISTS photo_backups(scope TEXT PRIMARY KEY REFERENCES scopes(scope) ON DELETE CASCADE,payload TEXT NOT NULL)")
        try execute("INSERT INTO photo_backups(scope,payload) VALUES(?,?)", [namespace, json])
    }

    /// 预编译并绑定原始字符串，返回由调用方法finalize的statement；失败路径同样释放，不拼接payload进SQL。
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw PhotoBackupStateError.invalidJournal
        }
        do {
            for (index, value) in values.enumerated() {
                try #require(sqlite3_bind_text(prepared, Int32(index + 1), value, -1,
                                               unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK)
            }
            return prepared
        } catch {
            sqlite3_finalize(prepared)
            throw error
        }
    }
}

/// 返回本测试独占目录；所有SQLite和缓存文件都在此目录内，结束后统一回收。
private nonisolated func backupTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "BackupJournalTests-\(UUID().uuidString)")
}

/// user仅区分合成身份；复用真实MediaAccountScope规则，同一服务不同用户必须使用不同namespace。
private nonisolated func backupTestScope(_ user: String) -> MediaAccountScope {
    .init(session: backupTestSession(user))
}

/// user为合成认证身份；允许删除后重新认证同账号，证明单项保存仍不能重建已经消失的任务。
private nonisolated func backupTestSession(_ user: String) -> AccountSession {
    .init(apiURL: URL(string: "https://backup.example.invalid/api")!, accessToken: "synthetic",
          userID: user, userEmail: "\(user)@example.invalid", name: user, isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}
