import Foundation
import Testing
@testable import Remmich

/// 真实SQLite与合成磁盘资源经过实际worker，检查上传副作用前的检查点、完整配对、未知结果停止及取消。
@Suite("Persistent foreground backup worker")
struct PhotoBackupWorkerTests {
    /// Live Photo两次上传和主体/动态最终回读分别只能看到已落盘的motion/primary/verifying阶段。
    @Test @MainActor func persistsEachCheckpointAndVerifiesTheCompletePair() async throws {
        let fixture = try await BackupWorkerFixture(kind: .livePhoto)
        defer { fixture.removeFiles() }
        let digest = Data(repeating: 7, count: 20).base64EncodedString()
        let transport = fixture.transport(checksum: digest)
        let result = try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                                  client: transport, validateContext: {}, progress: { _, _ in })
        let restored = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(result.completed == 1 && result.failed == 0 && !result.stopped)
        #expect(restored.jobs.first?.stage == .completed)
        #expect(restored.jobs.first?.primaryChecksum == digest)
        #expect(await transport.observedStages == [.uploadingMotion, .uploadingPrimary, .verifying, .verifying])
        #expect(await transport.assetReads == [fixture.primaryID.uuidString, fixture.motionID.uuidString])
        #expect(await transport.hiddenFlags == [true, false])
        #expect(await transport.primaryPair == fixture.motionID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: fixture.exportDirectory.path))
    }

    /// 主体已确认正确配对，但动态资源最后回读已回收/身份/类型/拥有者错误，不能完成或重试上传。
    @Test(arguments: [BackupMotionResponse.trashed, .wrongID, .wrongType, .wrongOwner])
    @MainActor func rejectsInvalidMotionAtFinalRead(_ response: BackupMotionResponse) async throws {
        let fixture = try await BackupWorkerFixture(kind: .livePhoto, secondJob: true)
        defer { fixture.removeFiles() }
        let transport = fixture.transport(motionResponse: response)
        let result = try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                                  client: transport, validateContext: {}, progress: { _, _ in })
        let journal = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(result.completed == 0 && result.failed == 1 && result.stopped)
        #expect(journal.jobs.map(\.stage) == [.failed, .paused])
        #expect(journal.jobs.first?.failure == .unconfirmedResponse)
        #expect(journal.jobs.first?.primaryAssetID == fixture.primaryID && journal.jobs.first?.motionAssetID == fixture.motionID)
        #expect(await transport.uploads == 2)
        #expect(await transport.assetReads == [fixture.primaryID.uuidString, fixture.motionID.uuidString])
        #expect(await transport.observedStages == [.uploadingMotion, .uploadingPrimary, .verifying, .verifying])
    }

    /// 归档的有效动态资源仍可完成既有配对；备份验证不擅自将其改为hidden或timeline。
    @Test @MainActor func acceptsAnArchivedVerifiedMotion() async throws {
        let fixture = try await BackupWorkerFixture(kind: .livePhoto)
        defer { fixture.removeFiles() }
        let transport = fixture.transport(motionResponse: .archived)
        let result = try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                                  client: transport, validateContext: {}, progress: { _, _ in })
        #expect(result.completed == 1 && result.failed == 0 && !result.stopped)
        do {
            let persistedSnapshot = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
            #expect(persistedSnapshot.jobs.first?.stage == .completed)
        }
        #expect(await transport.assetReads == [fixture.primaryID.uuidString, fixture.motionID.uuidString])
    }

    /// 主体重复但关联不符，或连接失败时只保留部分回执并暂停后续任务，均不能计为完成或自动重发。
    @Test(arguments: [false, true])
    @MainActor func unconfirmedPairOrNetworkStopsRemainingWork(_ network: Bool) async throws {
        let fixture = try await BackupWorkerFixture(kind: .livePhoto, secondJob: true)
        defer { fixture.removeFiles() }
        let transport = fixture.transport(mismatch: !network, networkFailure: network)
        let result = try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                                  client: transport, validateContext: {}, progress: { _, _ in })
        let journal = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(result.completed == 0 && result.failed == 1 && result.stopped)
        #expect(journal.jobs.map(\.stage) == [.failed, .paused])
        #expect(journal.jobs.first?.failure == (network ? .network : .livePhotoMismatch))
        #expect(journal.jobs.first?.primaryAssetID == (network ? nil : fixture.primaryID))
        #expect(await transport.uploads == (network ? 1 : 2))
    }

    /// 真正挂起上传后取消；即使假服务器随后返回成功，取消的worker也不能记成功或启动下一项。
    @Test @MainActor func cancellationRejectsALateUploadReceipt() async throws {
        let fixture = try await BackupWorkerFixture(kind: .photo, secondJob: true)
        defer { fixture.removeFiles() }
        let transport = fixture.transport(held: true)
        let task = Task {
            try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                         client: transport, validateContext: {}, progress: { _, _ in })
        }
        let observer = Task { _ = await task.result; await transport.workerFinished() }
        defer { observer.cancel() }
        try #require(await transport.waitUntilHeld(), "The real worker must reach the upload gate")
        task.cancel()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let journal = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(journal.jobs.map(\.stage) == [.paused, .paused])
        #expect(journal.jobs.first?.primaryAssetID == nil)
        #expect(await transport.uploads == 1)
    }

    /// 普通照片/视频只上传主体并回读同类型资产；不能误传Live Photo关联或省略最终核对。
    @Test(arguments: [PhotoBackupSource.Kind.photo, .video])
    @MainActor func verifiesOrdinaryOriginals(_ kind: PhotoBackupSource.Kind) async throws {
        let fixture = try await BackupWorkerFixture(kind: kind)
        defer { fixture.removeFiles() }
        let transport = fixture.transport()
        let result = try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false,
                                                  client: transport, validateContext: {}, progress: { _, _ in })
        #expect(result.completed == 1 && result.duplicates == 1 && result.failed == 0)
        #expect(await transport.observedStages == [.uploadingPrimary, .verifying])
        #expect(await transport.hiddenFlags == [false])
        #expect(await transport.primaryPair == nil)
    }

    /// 账号发布权在上传期间撤销；旧成功既不能落盘，也不能通过暂停清理修改新一轮工作。
    @Test @MainActor func revokedContextRejectsALateSuccess() async throws {
        let fixture = try await BackupWorkerFixture(kind: .photo)
        defer { fixture.removeFiles() }
        let transport = fixture.transport(held: true)
        let context = BackupWorkerContext()
        let task = Task {
            try await fixture.worker.run(scope: fixture.scope, userID: "synthetic", allowCloud: false, client: transport,
                                         validateContext: {
                                             if !context.current {
                                                 throw LibraryWriteError.changedAccount
                                             }
                                         }, progress: { _, _ in })
        }
        let observer = Task { _ = await task.result; await transport.workerFinished() }
        defer { observer.cancel() }
        try #require(await transport.waitUntilHeld(), "The real worker must reach the upload gate")
        context.current = false
        await transport.release()
        await #expect(throws: LibraryWriteError.self) { try await task.value }
        let interrupted = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(interrupted.jobs.first?.stage == .uploadingPrimary && interrupted.jobs.first?.primaryAssetID == nil)
        try await fixture.store.recoverPhotoBackupWork(scope: fixture.scope)
        let cold = try await fixture.store.loadPhotoBackups(scope: fixture.scope)
        #expect(cold.jobs.first?.stage == .paused)
    }

    /// 单项恢复只执行指定id；完成/取消历史及其他排队项不能因按钮语义而一起启动。
    @Test func singleRetryPausesOtherQueuedJobs() throws {
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.enqueue([.init(localID: "first", modifiedAt: nil, kind: .photo), .init(localID: "second", modifiedAt: nil, kind: .video)])
        let id = try #require(journal.jobs.last?.id)
        try journal.resumeForVerification(only: id)
        #expect(journal.jobs.map(\.stage) == [.paused, .queued])
        #expect(throws: PhotoBackupStateError.invalidTransition) { try journal.resumeForVerification(only: UUID()) }
    }
}

/// 每例独占账号目录与临时媒体；文件均合成，无PhotoKit、真实网络或私人照片。
@MainActor private struct BackupWorkerFixture {
    let root: URL
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let worker: PhotoBackupWorker
    let motionID = UUID()
    let primaryID = UUID()
    let exportDirectory: URL
    let kind: PhotoBackupSource.Kind

    /// kind为首项媒体类型，secondJob用于证明失败/取消停止后续上传。
    init(kind: PhotoBackupSource.Kind, secondJob: Bool = false) async throws {
        self.kind = kind
        root = FileManager.default.temporaryDirectory.appending(path: "BackupWorker-\(UUID())", directoryHint: .isDirectory)
        exportDirectory = root.appending(path: "export", directoryHint: .isDirectory)
        scope = .init(session: .init(apiURL: URL(string: "https://backup.example.invalid/api")!, accessToken: "synthetic",
                                     userID: "synthetic", userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
        store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.prepare(scope: scope)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([.init(localID: "first", modifiedAt: nil, kind: kind)] + (secondJob ? [.init(localID: "second", modifiedAt: nil, kind: .photo)] : []))
        try await store.savePhotoBackups(journal, scope: scope)
        worker = PhotoBackupWorker(store: store, exporter: SyntheticBackupExporter(directory: exportDirectory, store: store, scope: scope))
    }

    /// 只回收本测试根目录，不能触及应用账号或系统照片库。
    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 参数选择当前例故障与可选合成checksum；只传Sendable值，不跨Actor传递整个主线程fixture。
    func transport(mismatch: Bool = false, networkFailure: Bool = false, held: Bool = false,
                   motionResponse: BackupMotionResponse = .valid, checksum: String? = nil) -> BackupWorkerTransport
    {
        .init(store: store, scope: scope, motionID: motionID, primaryID: primaryID, kind: kind,
              mismatch: mismatch, networkFailure: networkFailure, held: held, motionResponse: motionResponse, checksum: checksum)
    }
}

/// 发布权门只在主Actor变更；模拟真实账号/端点代际撤销，不冒充服务器鉴权。
@MainActor private final class BackupWorkerContext { var current = true }

/// 在真正执行阶段生成最小磁盘资源，并从SQLite独立验证begin已经持久化。
@MainActor private struct SyntheticBackupExporter: PhotoBackupResourceExporting {
    let directory: URL
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope

    /// source确定合成资源组合；allowCloud只记录真实接口边界，本fixture不使用网络。
    func export(_ source: PhotoBackupSource, allowCloud _: Bool) async throws -> PhotoBackupResources {
        let journal = try await store.loadPhotoBackups(scope: scope)
        #expect(journal.jobs.first(where: { $0.source == source })?.stage == .exporting)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primary = directory.appending(path: "primary")
        let motion = directory.appending(path: "motion")
        try Data("synthetic primary".utf8).write(to: primary)
        try Data("synthetic motion".utf8).write(to: motion)
        return .init(directory: directory, primary: .init(file: primary, name: "primary.jpg"),
                     motion: source.kind == .livePhoto ? .init(file: motion, name: "motion.mov") : nil,
                     created: .distantPast, modified: .distantPast, favorite: false)
    }
}

/// 动态资源仅在最终GET中改变状态，模拟上传/查重之后的变化，不伪造主体关联或绕过真实worker。
nonisolated enum BackupMotionResponse: Equatable, Sendable { case valid, archived, trashed, wrongID, wrongType, wrongOwner }

/// 注入上传回执/网络失败和等待门；真实worker、SQLite及状态转换都不替换。
private actor BackupWorkerTransport: PhotoBackupUploading {
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    let motionID: UUID
    let primaryID: UUID
    let mismatch: Bool
    let networkFailure: Bool
    let held: Bool
    let kind: PhotoBackupSource.Kind
    let motionResponse: BackupMotionResponse
    let checksum: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private var didHold = false
    private var didFinish = false
    private(set) var uploads = 0
    private(set) var observedStages: [PhotoBackupJob.Stage] = []
    private(set) var hiddenFlags: [Bool] = []
    private(set) var primaryPair: String?
    private(set) var assetReads: [String] = []

    /// store/scope为隔离数据库，两个ID为合成回执，kind为主体类型；checksum可验证完整透传，其他参数选择故障。
    init(store: SQLiteLibraryIndexStore, scope: MediaAccountScope, motionID: UUID, primaryID: UUID, kind: PhotoBackupSource.Kind,
         mismatch: Bool = false, networkFailure: Bool = false, held: Bool = false, motionResponse: BackupMotionResponse = .valid, checksum: String? = nil)
    {
        self.store = store; self.scope = scope; self.motionID = motionID; self.primaryID = primaryID; self.kind = kind
        self.mismatch = mismatch; self.networkFailure = networkFailure; self.held = held
        self.motionResponse = motionResponse
        self.checksum = checksum
    }

    /// 与生产上传签名一致；读取SQLite证明检查点先于网络，按hidden区分动态/主体回执。
    func upload(file _: URL, filename _: String, created _: Date, modified _: Date, favorite _: Bool,
                hidden: Bool, livePhotoVideoID: String?) async throws -> LibraryMutationClient.UploadResult
    {
        uploads += 1; hiddenFlags.append(hidden)
        if !hidden {
            primaryPair = livePhotoVideoID
        }
        if let stage = try await store.loadPhotoBackups(scope: scope).jobs.first?.stage {
            observedStages.append(stage)
        }
        if held {
            await withCheckedContinuation { continuation in
                gate = continuation; didHold = true
                let pending = observers; observers = []; pending.forEach { $0.resume(returning: true) }
            }
        }
        if networkFailure {
            throw URLError(.networkConnectionLost)
        }
        return .init(id: (hidden ? motionID : primaryID).uuidString, status: "duplicate", checksum: checksum)
    }

    /// id区分主体与动态请求；动态故障只影响最终GET，核对前持久阶段始终为verifying。
    func asset(_ id: String) async throws -> ManagedAsset {
        assetReads.append(id)
        if let stage = try await store.loadPhotoBackups(scope: scope).jobs.first?.stage {
            observedStages.append(stage)
        }
        if UUID(uuidString: id) == motionID {
            return .init(id: (motionResponse == .wrongID ? UUID() : motionID).uuidString,
                         ownerId: motionResponse == .wrongOwner ? "other-synthetic" : "synthetic",
                         isFavorite: false, visibility: motionResponse == .archived ? "archive" : "hidden",
                         isTrashed: motionResponse == .trashed, type: motionResponse == .wrongType ? "IMAGE" : "VIDEO",
                         originalFileName: "synthetic.mov", livePhotoVideoId: nil, exifInfo: nil)
        }
        return .init(id: id, ownerId: "synthetic", isFavorite: false, visibility: "timeline", isTrashed: false,
                     type: kind == .video ? "VIDEO" : "IMAGE", originalFileName: "synthetic.jpg",
                     livePhotoVideoId: kind == .livePhoto ? (mismatch ? UUID() : motionID).uuidString : nil, exifInfo: nil)
    }

    /// 等待真实upload到达门；若已到达立即返回，不用定时sleep猜测调度。
    func waitUntilHeld() async -> Bool {
        if didHold {
            return true
        }
        if didFinish {
            return false
        }
        return await withCheckedContinuation { observers.append($0) }
    }

    /// worker若在到达门前已失败，唤醒观察者并返回false，避免测试留下永不恢复的continuation。
    func workerFinished() {
        didFinish = true
        let pending = observers; observers = []; pending.forEach { $0.resume(returning: false) }
    }

    /// 在取消之后释放真实成功回执，检查生产worker是否仍拒绝迟到成功。
    func release() {
        gate?.resume(); gate = nil
    }
}
