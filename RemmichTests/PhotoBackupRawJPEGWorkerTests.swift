import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实Exporter/Worker/上传客户端/SQLite闭环；只替换Photos系统端口与私有HTTP响应，完整字节是明确的合成payload。
@Suite("Complete RAW JPEG worker recovery")
@MainActor struct PhotoBackupRawJPEGWorkerTests {
    /// 顺序交换仍同时备份两个原图；RAW可已存在、JPEG新建，真实multipart不得把两份拼成一个或附加Live关联。
    @Test(arguments: [false, true], [false, true])
    func uploadsBothOriginalsWithIndependentChecksums(_ reverse: Bool, _ rawDuplicate: Bool) async throws {
        let fixture = try await RawJPEGBackupFixture(reverse: reverse, rawDuplicate: rawDuplicate)
        defer { fixture.close() }
        let result = try await fixture.run()
        #expect(result.completed == 1 && result.failed == 0 && result.duplicates == 0 && !result.stopped)
        let cold = try await fixture.coldJournal()
        let job = try #require(cold.jobs.first)
        #expect(job.stage == .completed && job.rawReceipt?.checksum == rawJPEGTestRAWBase64 && job.jpegReceipt?.checksum == rawJPEGTestJPEGBase64)
        #expect(job.rawReceipt?.assetID == rawJPEGTestRAWID && job.jpegReceipt?.assetID == rawJPEGTestJPEGID)
        #expect(job.primaryAssetID == nil && job.motionAssetID == nil && job.rawReceipt?.duplicate == rawDuplicate && job.jpegReceipt?.duplicate == false)
        #expect(cold.version == 3 && cold.header.rawJPEGVersion == 1)
        let requests = await fixture.server.observations
        #expect(requests.filter { $0.request.path.hasSuffix("bulk-upload-check") }.count == 2)
        #expect(requests.filter { $0.request.path == "/api/assets" }.count == (rawDuplicate ? 1 : 2))
        let jpegCheck = try #require(requests.first { $0.request.body?.range(of: Data(rawJPEGTestJPEGHex.utf8)) != nil })
        #expect(jpegCheck.job.rawReceipt?.assetID == rawJPEGTestRAWID && jpegCheck.job.jpegReceipt == nil)
        #expect(fixture.system.reads == [.raw, .jpeg] && fixture.system.cloudOptions == [false, false])
        #expect(fixture.system.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// 第二份真正查重断网后只保留已fresh核对的RAW；新SQLite连接恢复并重导出两份，不能只用旧UUID完成。
    @Test func coldRestoreRechecksTheFirstConfirmedImage() async throws {
        let fixture = try await RawJPEGBackupFixture(mode: .failJPEGOnce)
        defer { fixture.close() }
        let first = try await fixture.run()
        #expect(first.completed == 0 && first.failed == 1 && first.stopped)
        let partial = try await fixture.coldJournal()
        #expect(partial.jobs.first?.stage == .failed && partial.jobs.first?.rawReceipt?.assetID == rawJPEGTestRAWID && partial.jobs.first?.jpegReceipt == nil)
        try await fixture.resumeFromCold()
        let second = try await fixture.run(cold: true)
        let restored = try await fixture.coldJournal()
        #expect(second.completed == 1 && second.failed == 0 && restored.jobs.first?.attempts == 2 && restored.jobs.first?.stage == .completed)
        #expect(restored.jobs.first?.rawReceipt?.duplicate == true && restored.jobs.first?.jpegReceipt?.duplicate == false)
        let observations = await fixture.server.observations
        let checks = observations.filter { $0.request.path.hasSuffix("bulk-upload-check") }
        try #require(checks.count == 4)
        #expect(checks.map(\.job.attempts) == [1, 1, 2, 2])
        #expect(checks[2].request.body?.range(of: Data(rawJPEGTestRAWHex.utf8)) != nil && checks[2].job.rawReceipt?.assetID == rawJPEGTestRAWID)
        #expect(fixture.system.reads == [.raw, .jpeg, .raw, .jpeg])
    }

    /// 第一份落盘后在真实第二份HTTP挂起点取消/换号；晚回执不能发布成功，冷恢复保留首份且继续需重新查重。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func retirementRetainsOnlyVerifiedComponent(_ changeAccount: Bool) async throws {
        let fixture = try await RawJPEGBackupFixture(mode: .holdJPEGOnce)
        let task = Task { try await fixture.run() }
        let observer = Task { _ = await task.result; await fixture.server.workerEnded() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.server.waitUntilHeld(), "The actual JPEG request must reach its gate")
                let partial = try await fixture.coldJournal()
                #expect(partial.jobs.first?.rawReceipt?.assetID == rawJPEGTestRAWID && partial.jobs.first?.jpegReceipt == nil)
                if changeAccount {
                    fixture.manager.configure(session: nil, endpoint: nil)
                } else {
                    task.cancel()
                }
                await fixture.server.release()
                do { _ = try await task.value; Issue.record("Retired worker must not complete") } catch {}
                let cold = SQLiteLibraryIndexStore(databaseURL: fixture.database)
                try await cold.recoverPhotoBackupWork(scope: fixture.scope)
                let recovered = try await cold.loadPhotoBackups(scope: fixture.scope)
                #expect(recovered.jobs.first?.stage == .paused && recovered.jobs.first?.rawReceipt?.assetID == rawJPEGTestRAWID && recovered.jobs.first?.jpegReceipt == nil)
                fixture.manager.configure(session: fixture.session, endpoint: fixture.endpoint)
                try await fixture.resumeFromCold()
                let result = try await fixture.run(cold: true)
                #expect(result.completed == 1 && result.failed == 0)
                let requests = await fixture.server.observations
                #expect(requests.filter { $0.request.body?.range(of: Data(rawJPEGTestRAWHex.utf8)) != nil }.count == 2)
            } onCancel: {
                // XCTest/Testing取消外层等待时也必须释放非合作HTTP门，真实Worker随后退役再清目录。
                Task { @MainActor in task.cancel(); await fixture.server.release(); await fixture.server.workerEnded() }
            }
        } catch {
            task.cancel(); await fixture.server.release(); _ = await task.result
            await observer.value; fixture.close(); throw error
        }
        await observer.value; fixture.close()
    }

    /// 错误created/duplicate、UUID、拥有者、类型、回收站、缺失/错误摘要和最终回读失效，都不能成为整组完成。
    @Test(arguments: ["status", "upload-id", "asset-id", "owner", "type", "trash", "checksum", "missing-checksum", "offline", "missing-offline", "final-raw"])
    func rejectsUnconfirmedImageReceipts(_ fault: String) async throws {
        let fixture = try await RawJPEGBackupFixture(fault: fault)
        defer { fixture.close() }
        let result = try await fixture.run()
        let restored = try await fixture.coldJournal()
        #expect(result.completed == 0 && result.failed == 1 && result.stopped)
        #expect(restored.jobs.first?.stage == .failed && restored.jobs.first?.failure == .unconfirmedResponse)
        #expect(restored.jobs.first?.primaryAssetID == nil && restored.jobs.first?.motionAssetID == nil)
    }

    /// 两份都已存在时也必须重新查重和四次fresh读；完全重复只计一个完整逻辑任务。
    @Test func countsTwoVerifiedDuplicatesAsOneGroup() async throws {
        let fixture = try await RawJPEGBackupFixture(rawDuplicate: true, jpegDuplicate: true)
        defer { fixture.close() }
        let result = try await fixture.run()
        let observations = await fixture.server.observations
        #expect(result.completed == 1 && result.duplicates == 1)
        #expect(observations.filter { $0.request.method == "GET" }.count == 4 && observations.allSatisfy { $0.request.path != "/api/assets" })
    }

    /// JPEG原始字节已存在且属于既有Live配对仍可确认；仅验证所需原图，不删除/修改已有motion关联。
    @Test func acceptsDuplicateJPEGWithoutChangingExistingMotion() async throws {
        let fixture = try await RawJPEGBackupFixture(rawDuplicate: true, jpegDuplicate: true, fault: "existing-motion")
        defer { fixture.close() }
        let result = try await fixture.run()
        let restored = try await fixture.coldJournal()
        let requests = await fixture.server.observations
        #expect(result.completed == 1 && result.duplicates == 1 && restored.jobs.first?.jpegReceipt?.duplicate == true)
        #expect(requests.count == 6 && requests.allSatisfy { $0.request.method == "GET" || $0.request.path == "/api/assets/bulk-upload-check" })
        #expect(requests.allSatisfy { $0.request.method != "PUT" && $0.request.method != "DELETE" && $0.request.method != "PATCH" })
    }

    /// 源变成不支持/权限丢失时不能进入HTTP；第二份读取失败也回收已经导出的第一份临时文件。
    @Test(arguments: ["unsupported", "permission", "jpeg-read"])
    func rejectedExportNeverCreatesPartialServerBackup(_ failure: String) async throws {
        let fixture = try await RawJPEGBackupFixture()
        defer { fixture.close() }
        fixture.system.failure = failure
        let result = try await fixture.run()
        let restored = try await fixture.coldJournal()
        #expect(result.completed == 0 && result.failed == 1 && result.stopped == (failure != "unsupported"))
        #expect(restored.jobs.first?.rawReceipt == nil && restored.jobs.first?.jpegReceipt == nil)
        #expect(await fixture.server.observations.isEmpty)
        #expect(fixture.system.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// 导出期间完整源描述变化时临时两文件均回收，真实Worker不能发起任何查重/上传。
    @Test func changedResourceDescriptionFailsBeforeAnyHTTP() async throws {
        let fixture = try await RawJPEGBackupFixture()
        defer { fixture.close() }
        fixture.system.changeAfterRead = true
        let result = try await fixture.run()
        let restored = try await fixture.coldJournal()
        #expect(result.completed == 0 && result.failed == 1 && !result.stopped)
        #expect(restored.jobs.first?.failure == .sourceChanged && restored.jobs.first?.rawReceipt == nil)
        #expect(await fixture.server.observations.isEmpty)
        #expect(fixture.system.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

/// 合成字节仅验证流式SHA1与逐份保留，不是可解码DNG/JPEG或真实PhotoKit证据；摘要由独立Node crypto计算。
private nonisolated let rawJPEGTestRAWBytes = Data("synthetic RAW original v1\n".utf8)
private nonisolated let rawJPEGTestJPEGBytes = Data("synthetic JPEG original v1\n".utf8)
private nonisolated let rawJPEGTestRAWHex = "18fa986cc0749d20bf6b1717ab4340cd6f5418c6"
private nonisolated let rawJPEGTestJPEGHex = "3cb598cc68b018675f50272fe027653407a0b08a"
private nonisolated let rawJPEGTestRAWBase64 = "GPqYbMB0nSC/axcXq0NAzW9UGMY="
private nonisolated let rawJPEGTestJPEGBase64 = "PLWYzGiwGGdfUCcv4CdlNAegsIo="
private nonisolated let rawJPEGTestRAWID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let rawJPEGTestJPEGID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

/// 每例隔离账号、SQLite、URLSession和源端口；真实扫描生成格式3，不直接改表或构造成功状态。
@MainActor private final class RawJPEGBackupFixture {
    let root: URL
    let database: URL
    let endpoint: URL
    let session: AccountSession
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let server: RawJPEGBackupHTTPServer
    let manager: LibraryManagementController
    let system: RawJPEGBackupSystemPort

    /// 参数控制资源顺序、服务器已有成员及明确故障；所有目录/host均本例独占，失败不访问生产。
    init(reverse: Bool = false, rawDuplicate: Bool = false, jpegDuplicate: Bool = false,
         mode: RawJPEGBackupHTTPServer.Mode = .normal, fault: String = "") async throws
    {
        root = FileManager.default.temporaryDirectory.appending(path: "RawJPEGWorker-\(UUID())", directoryHint: .isDirectory)
        database = root.appending(path: "index.sqlite")
        endpoint = URL(string: "https://raw-jpeg-\(UUID().uuidString.lowercased()).invalid/api")!
        session = .init(apiURL: endpoint, accessToken: "raw-jpeg-fixture", userID: "synthetic", userEmail: "synthetic@example.invalid",
                        name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        scope = .init(session: session); store = SQLiteLibraryIndexStore(databaseURL: database)
        system = try RawJPEGBackupSystemPort(reverse: reverse)
        server = .init(store: store, scope: scope, rawDuplicate: rawDuplicate, jpegDuplicate: jpegDuplicate, mode: mode, fault: fault)
        RawJPEGBackupURLProtocol.install(server, host: endpoint.host!)
        manager = LibraryManagementController(configurationFactory: Self.configuration)
        manager.configure(session: session, endpoint: endpoint)
        do {
            try await store.prepare(scope: scope)
            let selection = try PhotoBackupAlbumSelection(included: ["synthetic-album"], excluded: [])
            let scan = try selection.scan([.init(id: "synthetic-album", assets: [.init(source: system.source, capturedAt: nil)])])
            var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
            try journal.applyAlbumScan(scan, allowCloud: false)
            try await store.savePhotoBackups(journal, scope: scope)
        } catch { close(); throw error }
    }

    /// 私有URLProtocol拦截本测试所有请求，无共享会话/全局注册或真实网络后备。
    private nonisolated static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [RawJPEGBackupURLProtocol.self]; return value
    }

    /// cold选择新SQLite actor；真实当前manager代际在所有await后由Worker验证。
    func run(cold: Bool = false) async throws -> PhotoBackupRunResult {
        guard let client = manager.client else { throw LibraryWriteError.unavailable }
        let owner = manager.generation
        let workerStore = cold ? SQLiteLibraryIndexStore(databaseURL: database) : store
        let worker = PhotoBackupWorker(store: workerStore, exporter: PhotoKitBackupResourceExporter(rawJPEGReader: system))
        return try await worker.run(scope: scope, userID: "synthetic", allowCloud: false, client: client, validateContext: { [manager, scope] in
            guard manager.generation == owner, manager.backupScope == scope else { throw LibraryWriteError.changedAccount }
        }, progress: { _, _ in })
    }

    /// 每次新actor从磁盘读取完整回执，避免把原Worker内存当作冷恢复证据。
    func coldJournal() async throws -> PhotoBackupJournal {
        try await SQLiteLibraryIndexStore(databaseURL: database).loadPhotoBackups(scope: scope)
    }

    /// 真实冷恢复后执行明确继续；只修改真实领域状态并保存，不手写SQLite成功行。
    func resumeFromCold() async throws {
        let cold = SQLiteLibraryIndexStore(databaseURL: database)
        try await cold.recoverPhotoBackupWork(scope: scope)
        var journal = try await cold.loadPhotoBackups(scope: scope)
        try journal.resumeForVerification()
        try await cold.savePhotoBackups(journal, scope: scope)
    }

    /// 调用方须先等待所有Worker/HTTP门退役；只清本例账号与临时资源，不操作真实Photos。
    func close() {
        RawJPEGBackupURLProtocol.remove(host: endpoint.host!); manager.configure(session: nil, endpoint: nil)
        try? FileManager.default.removeItem(at: root)
        for directory in system.directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// 替代公开Photos元数据/字节端口；真正Exporter负责顺序、前后观察、取消与目录回收，未替换Worker或上传算法。
@MainActor private final class RawJPEGBackupSystemPort: PhotoBackupRawJPEGResourceReading {
    let source: PhotoBackupSource
    var reads: [PhotoBackupImageRole] = []
    var cloudOptions: [Bool] = []
    var directories: [URL] = []
    var changeAfterRead = false
    var failure = ""

    /// reverse仅改变系统资源枚举顺序；真实政策仍须从公开UTI选中角色。
    init(reverse: Bool) throws {
        let raw = PhotoBackupOriginalImage(kind: .alternatePhoto, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 3, pixelHeight: 2)
        let jpeg = PhotoBackupOriginalImage(kind: .photo, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 3, pixelHeight: 2)
        let pair = try PhotoBackupRawJPEGSource(originals: reverse ? [jpeg, raw] : [raw, jpeg], hasAdjustments: false, adjustmentTime: nil)
        source = .init(localID: "synthetic-pair", modifiedAt: Date(timeIntervalSince1970: 100), kind: .rawJPEG, rawJPEG: pair)
    }

    /// 返回同版本完整公开描述，故障模式仅改变资源名称而非localID/修改时间，检验完整描述门禁。
    func observe(_ expected: PhotoBackupSource) throws -> PhotoBackupRawJPEGObservation {
        try Task.checkCancellation()
        guard expected == source else { throw PhotoBackupExportError(reason: .sourceChanged) }
        if failure == "unsupported" {
            throw PhotoBackupExportError(reason: .unsupportedResources)
        }
        if failure == "permission" {
            throw PhotoBackupExportError(reason: .permission)
        }
        var observed = source
        if changeAfterRead, !reads.isEmpty, let pair = source.rawJPEG {
            let raw = PhotoBackupOriginalImage(kind: pair.raw.kind, uniformTypeIdentifier: pair.raw.uniformTypeIdentifier,
                                               originalFilename: "changed.dng", pixelWidth: pair.raw.pixelWidth, pixelHeight: pair.raw.pixelHeight)
            let changed = try PhotoBackupRawJPEGSource(originals: [raw, pair.jpeg], hasAdjustments: false, adjustmentTime: nil)
            observed = .init(localID: source.localID, modifiedAt: source.modifiedAt, kind: .rawJPEG, rawJPEG: changed)
        }
        return .init(source: observed, created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 100), favorite: false)
    }

    /// 写入角色对应的完整合成字节；文件已由真实Exporter安排为私有路径，明确记录allowCloud没有隐式放宽。
    func read(_ role: PhotoBackupImageRole, source expected: PhotoBackupSource, file: URL, allowCloud: Bool) async throws {
        try Task.checkCancellation(); guard expected == source else { throw PhotoBackupExportError(reason: .sourceChanged) }
        reads.append(role); cloudOptions.append(allowCloud); directories.append(file.deletingLastPathComponent())
        if role == .jpeg, failure == "jpeg-read" {
            throw URLError(.networkConnectionLost)
        }
        try (role == .raw ? rawJPEGTestRAWBytes : rawJPEGTestJPEGBytes).write(to: file, options: .withoutOverwriting)
    }
}

/// URLSession交出的实际HTTP快照；在回调线程读完最多64KiB的合成multipart/JSON，不跨Actor传InputStream。
private nonisolated struct RawJPEGBackupRequest: Sendable {
    let method: String
    let path: String
    let url: URL
    let authorization: String?
    let checksum: String?
    let contentType: String?
    let body: Data?

    /// request来自本测试URLSession；body与stream互斥读取，缺少multipart真实字节不能靠重建请求补造。
    init(_ request: URLRequest) throws {
        guard let url = request.url else { throw URLError(.badURL) }
        self.url = url; path = url.path; method = request.httpMethod ?? ""
        authorization = request.value(forHTTPHeaderField: "Authorization"); checksum = request.value(forHTTPHeaderField: "x-immich-checksum")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        if let value = request.httpBody {
            body = value
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                result.append(contentsOf: buffer.prefix(count))
                guard result.count < 65536 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = result
        } else {
            body = nil
        }
    }
}

/// 请求与从真实SQLite读取的检查点；测试替身不向Worker回写阶段或成功回执。
private nonisolated struct RawJPEGBackupObservation: Sendable { let request: RawJPEGBackupRequest; let job: PhotoBackupJob }

/// 实际HTTP状态和字节，统一交URLSession自身解码；不是直接构造Worker的上传结果。
private nonisolated struct RawJPEGBackupReply: Sendable { let status: Int; let data: Data }

/// 官方单份校验和查重请求；nonce只关联本次请求，不当成设备资源身份或持久回执。
private nonisolated struct RawJPEGBackupCheck: Decodable {
    struct Item: Decodable { let id: String; let checksum: String }
    let assets: [Item]
}

/// 只接受既有官方查重、multipart上传与资产GET；按真实校验和维护两份独立合成资产，无媒体GET/Stack/原片修改。
private actor RawJPEGBackupHTTPServer {
    nonisolated enum Mode: Sendable { case normal, failJPEGOnce, holdJPEGOnce }
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    let mode: Mode
    let fault: String
    private var existing: Set<PhotoBackupImageRole>
    private var jpegChecks = 0
    private var reads: [PhotoBackupImageRole: Int] = [:]
    private var held = false
    private var ended = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private(set) var observations: [RawJPEGBackupObservation] = []

    /// 初始已有成员模拟服务器重复；store/scope只读真实当时检查点，mode/fault指定单个明确故障。
    init(store: SQLiteLibraryIndexStore, scope: MediaAccountScope, rawDuplicate: Bool, jpegDuplicate: Bool, mode: Mode, fault: String) {
        self.store = store; self.scope = scope; self.mode = mode; self.fault = fault
        existing = []
        if rawDuplicate {
            existing.insert(.raw)
        }; if jpegDuplicate {
            existing.insert(.jpeg)
        }
    }

    /// request必须带本例Bearer并命中唯一允许路由；严格检查原始multipart完整字节、文件名、校验和及无额外身份方案。
    func response(_ request: RawJPEGBackupRequest) async throws -> RawJPEGBackupReply {
        guard request.authorization == "Bearer raw-jpeg-fixture" else { throw URLError(.userAuthenticationRequired) }
        let journal = try await store.loadPhotoBackups(scope: scope)
        guard let job = journal.jobs.first else { throw PhotoBackupStateError.invalidJournal }
        observations.append(.init(request: request, job: job))
        if request.method == "POST", request.path == "/api/assets/bulk-upload-check" {
            guard request.contentType == "application/json", let body = request.body else { throw URLError(.badServerResponse) }
            let check = try JSONDecoder().decode(RawJPEGBackupCheck.self, from: body)
            guard check.assets.count == 1, let item = check.assets.first, UUID(uuidString: item.id) != nil,
                  let role = role(for: item.checksum) else { throw URLError(.badServerResponse) }
            if role == .jpeg {
                jpegChecks += 1
                if jpegChecks == 1, mode == .failJPEGOnce {
                    throw URLError(.networkConnectionLost)
                }
                if jpegChecks == 1, mode == .holdJPEGOnce, !released {
                    await withCheckedContinuation { value in
                        continuation = value; held = true
                        let waiting = observers; observers = []; waiting.forEach { $0.resume(returning: true) }
                    }
                }
            }
            let itemBody: [String: Any] = existing.contains(role)
                ? ["id": item.id, "action": "reject", "assetId": id(for: role).uuidString, "isTrashed": false, "reason": "duplicate"]
                : ["id": item.id, "action": "accept"]
            return try reply(["results": [itemBody]])
        }
        if request.method == "POST", request.path == "/api/assets" {
            guard let checksum = request.checksum, let role = role(for: checksum), let body = request.body,
                  request.contentType?.hasPrefix("multipart/form-data; boundary=") == true else { throw URLError(.badServerResponse) }
            let bytes = role == .raw ? rawJPEGTestRAWBytes : rawJPEGTestJPEGBytes
            let other = role == .raw ? rawJPEGTestJPEGBytes : rawJPEGTestRAWBytes
            let filename = role == .raw ? "synthetic.dng" : "synthetic.jpg"
            guard body.range(of: bytes) != nil, body.range(of: other) == nil,
                  body.range(of: Data("name=\"assetData\"; filename=\"\(filename)\"".utf8)) != nil,
                  !["livePhotoVideoId", "visibility", "deviceAssetId", "deviceId"].contains(where: { body.range(of: Data("name=\"\($0)\"".utf8)) != nil })
            else { throw URLError(.badServerResponse) }
            existing.insert(role)
            return try reply(["id": fault == "upload-id" && role == .jpeg ? "invalid-id" : id(for: role).uuidString,
                              "status": fault == "status" && role == .jpeg ? "unknown" : "created"], status: 201)
        }
        if request.method == "GET", request.body == nil,
           let role = [PhotoBackupImageRole.raw, .jpeg].first(where: { request.path == "/api/assets/\(id(for: $0).uuidString)" }), existing.contains(role)
        {
            reads[role, default: 0] += 1
            let invalid = role == .jpeg
            var value: [String: Any] = ["id": invalid && fault == "asset-id" ? UUID().uuidString : id(for: role).uuidString, "ownerId": invalid && fault == "owner" ? "other" : "synthetic",
                                        "type": invalid && fault == "type" ? "VIDEO" : "IMAGE", "isTrashed": invalid && fault == "trash", "isOffline": invalid && fault == "offline",
                                        "isFavorite": false, "visibility": "timeline", "originalFileName": role == .raw ? "synthetic.dng" : "synthetic.jpg",
                                        "checksum": role == .raw ? rawJPEGTestRAWBase64 : rawJPEGTestJPEGBase64]
            if invalid && fault == "checksum" || role == .raw && fault == "final-raw" && reads[role] == 2 {
                value["checksum"] = Data(repeating: 9, count: 20).base64EncodedString()
            }
            if invalid, fault == "missing-checksum" {
                value.removeValue(forKey: "checksum")
            }
            if invalid, fault == "missing-offline" {
                value.removeValue(forKey: "isOffline")
            }
            if invalid, fault == "existing-motion" {
                value["livePhotoVideoId"] = "33333333-3333-4333-8333-333333333333"
            }
            return try reply(value)
        }
        throw URLError(.unsupportedURL)
    }

    /// 仅两个独立Node摘要能选择成员；文件名/请求次序不能决定返回哪份资产。
    private func role(for checksum: String) -> PhotoBackupImageRole? {
        checksum == rawJPEGTestRAWHex ? .raw : checksum == rawJPEGTestJPEGHex ? .jpeg : nil
    }

    /// 返回本例固定远端身份，与本地PHAsset身份和查重nonce明确区分。
    private func id(for role: PhotoBackupImageRole) -> UUID {
        role == .raw ? rawJPEGTestRAWID : rawJPEGTestJPEGID
    }

    /// object只含本例合成协议数据；输出JSON字节和真实状态供客户端完成现有解码。
    private func reply(_ object: [String: Any], status: Int = 200) throws -> RawJPEGBackupReply {
        try .init(status: status, data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// 等待真实第二份请求进入；若Worker先失败则返回false，不用sleep猜测时序。
    func waitUntilHeld() async -> Bool {
        if held {
            return true
        }; if ended {
            return false
        }
        return await withCheckedContinuation { observers.append($0) }
    }

    /// 外层Worker完成后解除未进入的观察者；失败也不能让测试永久等待入场。
    func workerEnded() {
        ended = true; let waiting = observers; observers = []; waiting.forEach { $0.resume(returning: false) }
    }

    /// 释放非合作服务迟到响应供Task清理；不人为取消或完成Worker/修改SQLite。
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

/// 本例私有会话的网络边界；全部host/路由都拦截，未知项失败而非回源，Mutex保护取消/Task安装竞争。
private final nonisolated class RawJPEGBackupURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let servers = Mutex<[String: RawJPEGBackupHTTPServer]>([:])
    private let loading = Mutex(Loading())

    /// host必须为本例独占.invalid地址；只登记私有URLSession脚本，不注册全局协议。
    static func install(_ server: RawJPEGBackupHTTPServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    /// 测试所有Worker退役后移除自己的host，不触及其他并行测试。
    static func remove(host: String) {
        _ = servers.withLock { $0.removeValue(forKey: host) }
    }

    /// 全部请求都拦截，不能让错误endpoint漏进真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留实际argv/URL/body，不在替身中修正生产请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 请求字节在当前回调读完后跨入独立actor；晚响应只在请求仍拥有发布权时交回URLSession。
    override func startLoading() {
        do {
            let captured = try RawJPEGBackupRequest(request)
            guard let server = Self.servers.withLock({ $0[captured.url.host ?? ""] }) else { throw URLError(.badURL) }
            let task = Task { @Sendable [weak self, captured, server] in
                do {
                    let reply = try await server.response(captured)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }),
                          let response = HTTPURLResponse(url: captured.url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
                } catch {
                    if let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 只取消自己的响应Task，非合作服务门由测试释放；取消后的回调不再发布旧账号字节。
    override func stopLoading() {
        loading.withLock { $0.stopped = true; $0.task?.cancel() }
    }
}
