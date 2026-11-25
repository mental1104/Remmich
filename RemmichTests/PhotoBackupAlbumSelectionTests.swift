import Foundation
import Testing
@testable import Remmich

/// 相簿选择纯领域与真实账号SQLite验收；不访问PhotoKit、iCloud或真实媒体。
@Suite("Backup album exclusions")
struct PhotoBackupAlbumSelectionTests {
    /// 同时属于包含和排除集合的照片必须排除；其他重复项去重，并按日期和稳定ID排序。
    @Test func exclusionsOverrideIncludedAlbumsWithoutChangingOrder() throws {
        let first = scannedBackup("first", capturedAt: 10)
        let tied = scannedBackup("tied", capturedAt: 10)
        let excluded = scannedBackup("private", capturedAt: 1)
        let selection = try PhotoBackupAlbumSelection(included: ["all", "overlap"], excluded: ["private-album"])
        let scan = try selection.scan([
            .init(id: "all", assets: [tied, excluded, first]),
            .init(id: "overlap", assets: [first]),
            .init(id: "private-album", assets: [excluded]),
        ])
        #expect(scan.sources.map(\.localID) == ["first", "tied"])
        #expect(scan.excludedSourceIDs == ["private"])
        #expect(scan.selection == selection)
    }

    /// 丢失排除相簿不能按空排除继续；同一源在枚举中版本不同也应显式重扫。
    @Test func rejectsMissingExclusionsAndConflictingSourceVersions() throws {
        let asset = scannedBackup("same", capturedAt: 1)
        let selection = try PhotoBackupAlbumSelection(included: ["all"], excluded: ["missing"])
        #expect(throws: PhotoBackupAlbumSelectionError.unavailableAlbum) {
            try selection.scan([.init(id: "all", assets: [asset])])
        }
        let changed = PhotoBackupScannedAsset(source: .init(localID: asset.source.localID, modifiedAt: Date(timeIntervalSince1970: 2), kind: .photo), capturedAt: asset.capturedAt)
        let overlapping = try PhotoBackupAlbumSelection(included: ["one", "two"], excluded: [])
        #expect(throws: PhotoBackupAlbumSelectionError.changedSource) {
            try overlapping.scan([.init(id: "one", assets: [asset]), .init(id: "two", assets: [changed])])
        }
    }

    /// 同一个集合既包含又排除时合法但没有可上传源；完成记录不可因排除被改写为取消。
    @Test func completeHistorySurvivesAnEmptyEligibleSelection() throws {
        let asset = scannedBackup("already-complete", capturedAt: 1)
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.enqueue([asset.source, scannedBackup("not-selected", capturedAt: 2).source])
        let completeID = try #require(journal.jobs.first?.id)
        try journal.update(completeID) { job in
            try job.begin(); try job.exported(); try job.recordPrimary(UUID(), duplicate: false); try job.confirmVerifiedReceipt()
        }
        let selection = try PhotoBackupAlbumSelection(included: ["all"], excluded: ["all"])
        let scan = try selection.scan([.init(id: "all", assets: [asset])])
        #expect(try journal.applyAlbumScan(scan, allowCloud: false) == 0)
        #expect(journal.jobs.map(\.stage) == [.completed, .cancelled])
        #expect(journal.version == 2 && journal.excludedAlbumIDs == ["all"])
    }

    /// 一次明确新扫描更新整个待执行范围，保留被取消项的部分回执；SQLite冷恢复后规则仍属于原账号。
    @Test func persistsExclusionsAndCancelsObsoletePendingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupExclusions-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let scope = exclusionBackupScope()
        try await store.prepare(scope: scope)
        let keep = scannedBackup("included", capturedAt: 2)
        let hidden = PhotoBackupScannedAsset(source: .init(localID: "excluded", modifiedAt: nil, kind: .livePhoto), capturedAt: .distantPast)
        let noLongerSelected = scannedBackup("old-selection", capturedAt: 3)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([hidden.source, noLongerSelected.source])
        let hiddenID = try #require(journal.jobs.first?.id)
        let motionID = UUID()
        try journal.update(hiddenID) { job in try job.begin(); try job.exported(); try job.recordMotion(motionID); job.pause() }
        let selection = try PhotoBackupAlbumSelection(included: ["selected"], excluded: ["excluded-album"])
        let scan = try selection.scan([.init(id: "selected", assets: [keep, hidden]), .init(id: "excluded-album", assets: [hidden])])
        try journal.applyAlbumScan(scan, allowCloud: true)
        try await store.savePhotoBackups(journal, scope: scope)

        let cold = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        var restored = try await cold.loadPhotoBackups(scope: scope)
        #expect(restored.version == 2 && restored.selectedAlbumIDs == ["selected"] && restored.excludedAlbumIDs == ["excluded-album"])
        #expect(restored.allowCloud)
        #expect(restored.jobs.map(\.stage) == [.cancelled, .cancelled, .queued])
        #expect(restored.jobs.first?.motionAssetID == motionID)
        #expect(try await cold.nextQueuedPhotoBackup(scope: scope)?.source.localID == "included")
        try restored.resumeForVerification()
        #expect(restored.jobs.map(\.stage) == [.cancelled, .cancelled, .queued])

        // 明确取消排除后仍保持格式2，避免旧版本静默接管曾有新选择语义的恢复资料。
        let cleared = try PhotoBackupAlbumSelection(included: ["selected"], excluded: [])
            .scan([.init(id: "selected", assets: [keep])])
        try restored.applyAlbumScan(cleared, allowCloud: false)
        #expect(restored.version == 2 && restored.excludedAlbumIDs == [])
    }

    /// 旧日志无排除字段仍可读；未知未来格式或缺少格式2必需规则的日志不可降级覆盖。
    @Test func readsLegacySettingsAndPreservesFutureFormats() throws {
        let legacy = #"{"version":1,"namespace":"synthetic","selectedAlbumIDs":["all"],"allowCloud":false,"jobs":[]}"#
        var journal = try JSONDecoder().decode(PhotoBackupJournal.self, from: Data(legacy.utf8))
        try journal.validate(namespace: "synthetic")
        #expect(journal.excludedAlbumIDs == nil && journal.version == 1)
        let selection = try PhotoBackupAlbumSelection(included: ["all"], excluded: [])
        let scan = try selection.scan([.init(id: "all", assets: [])])
        try journal.applyAlbumScan(scan, allowCloud: false)
        #expect(journal.version == 1 && journal.excludedAlbumIDs == nil)
        let future = #"{"version":3,"namespace":"synthetic","selectedAlbumIDs":[],"allowCloud":false,"jobs":[]}"#
        var unknown = try JSONDecoder().decode(PhotoBackupJournal.self, from: Data(future.utf8))
        #expect(throws: PhotoBackupStateError.invalidJournal) { try unknown.applyAlbumScan(scan, allowCloud: false) }
        #expect(unknown.version == 3)
        let invalid = PhotoBackupJournal.Header(version: 2, namespace: "synthetic", selectedAlbumIDs: ["all"], allowCloud: false)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try invalid.validate(namespace: "synthetic") }
    }

    /// 格式2必须来自合法的明确选择；空集合、空ID和重复包含ID均不能进入冷恢复或热队列读取。
    @Test(arguments: [[], [""], ["all", "all"]])
    func rejectsMalformedVersionTwoInclusions(_ included: [String]) {
        let header = PhotoBackupJournal.Header(version: 2, namespace: "synthetic", selectedAlbumIDs: included, allowCloud: false, excludedAlbumIDs: [])
        #expect(throws: PhotoBackupStateError.invalidJournal) { try header.validate(namespace: "synthetic") }
    }

    /// 未退役的执行状态不能被新扫描直接改写；调用者必须先等待coordinator并恢复中断状态。
    @Test func doesNotReconfigureAnInFlightJournal() throws {
        let asset = scannedBackup("in-flight", capturedAt: 1)
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.enqueue([asset.source])
        let id = try #require(journal.jobs.first?.id)
        try journal.update(id) { try $0.begin() }
        let scan = try PhotoBackupAlbumSelection(included: ["all"], excluded: ["all"]).scan([.init(id: "all", assets: [asset])])
        #expect(throws: PhotoBackupStateError.invalidTransition) { try journal.applyAlbumScan(scan, allowCloud: true) }
        #expect(journal.version == 1 && journal.selectedAlbumIDs.isEmpty && !journal.allowCloud)
        #expect(journal.jobs.first?.stage == .exporting)
    }
}

/// id为合成设备源身份，capturedAt单位为Unix秒；修改版本固定，便于独立测试排序/去重。
private nonisolated func scannedBackup(_ id: String, capturedAt: TimeInterval) -> PhotoBackupScannedAsset {
    .init(source: .init(localID: id, modifiedAt: Date(timeIntervalSince1970: 1), kind: .photo), capturedAt: Date(timeIntervalSince1970: capturedAt))
}

/// 创建真实namespace规则下的合成账号，所有SQLite文件仅在此测试独占临时根目录。
private nonisolated func exclusionBackupScope() -> MediaAccountScope {
    .init(session: .init(apiURL: URL(string: "https://backup-exclusion.example.invalid/api")!, accessToken: "synthetic", userID: "owner",
                         userEmail: "owner@example.invalid", name: "Synthetic", isAdmin: false,
                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
}
