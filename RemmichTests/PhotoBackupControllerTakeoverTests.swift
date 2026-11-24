import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 两个已打开窗口通过真实Controller/Worker/SQLite/上传客户端接管同账号任务；仅资源和HTTP字节为合成值。
@Suite("Backup controller account takeover")
struct PhotoBackupControllerTakeoverTests {
    /// single选择“只重试L”或普通“继续”；旧窗口失效时，等待窗口必须恢复遗留in-flight并重新查重。
    /// 时间上限只防回归卡死，业务顺序由请求/退役握手建立，不用sleep猜测执行时序。
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    @MainActor func takesOverAnInterruptedLivePhotoWithoutReplayingOtherJobs(_ single: Bool) async throws {
        let fixture = try await BackupTakeoverFixture(single: single)
        do {
            try await withTaskCancellationHandler {
                try await fixture.exercise(single: single)
            } onCancel: {
                // 测试被取消/超时时也关闭实际会话并释放响应门，不遗留不可恢复continuation。
                Task { @MainActor in await fixture.stop() }
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

/// 独立SHA1参考值由Node crypto计算，资源字节完全合成；不调用生产checksum来生成预期答案。
private nonisolated let takeoverMotionChecksum = "8cf716d1dc1b984bb32a25a19afc7e20ccdb38d9"
private nonisolated let takeoverPrimaryChecksum = "ab719ff9379e51b99e386c0a16fd4f2e00474e13"
private nonisolated let takeoverMotionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let takeoverPrimaryID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private nonisolated let takeoverUserID = "99999999-9999-4999-8999-999999999999"
private nonisolated let takeoverMotionBytes = Data("synthetic takeover motion\n".utf8)
private nonisolated let takeoverPrimaryBytes = Data("synthetic takeover primary\n".utf8)
private nonisolated let takeoverAssetJSON = #"{"id":"22222222-2222-4222-8222-222222222222","ownerId":"99999999-9999-4999-8999-999999999999","isFavorite":false,"visibility":"timeline","isTrashed":false,"type":"IMAGE","originalFileName":"synthetic.jpg","livePhotoVideoId":"11111111-1111-4111-8111-111111111111","exifInfo":null}"#
/// 动态回读使用独立VIDEO对象；不能把still的正确关联当作动态资源存在/非回收站的证据。
private nonisolated let takeoverMotionAssetJSON = #"{"id":"11111111-1111-4111-8111-111111111111","ownerId":"99999999-9999-4999-8999-999999999999","isFavorite":false,"visibility":"hidden","isTrashed":false,"type":"VIDEO","originalFileName":"synthetic.mov","livePhotoVideoId":null,"exifInfo":null}"#

/// 每例拥有随机账号namespace、独立SQLite连接、两个真实manager/controller和有限HTTP响应脚本。
@MainActor private final class BackupTakeoverFixture {
    let root: URL
    let endpoint: URL
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let liveJobID: UUID
    let otherJobID: UUID?
    let exporter: TakeoverResourceExporter
    let script: TakeoverHTTPScript
    let firstManager: LibraryManagementController
    let waitingManager: LibraryManagementController
    let first: PhotoBackupController
    let waiting: PhotoBackupController
    private var firstRun: Task<Void, Never>?
    private var waitingRun: Task<Void, Never>?
    private var observer: Task<Void, Never>?

    /// single为true时额外排入Q，用于证明单项按钮不会偷偷导出/上传其他任务；false只排入L。
    init(single: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupTakeover-\(UUID())", directoryHint: .isDirectory)
        let endpoint = URL(string: "https://backup-takeover-\(UUID().uuidString.lowercased()).invalid/api")!
        let session = AccountSession(apiURL: endpoint, accessToken: "takeover-fixture", userID: takeoverUserID,
                                     userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session)
        let databaseURL = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: databaseURL)
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.enqueue([.init(localID: "synthetic-live", modifiedAt: nil, kind: .livePhoto)]
            + (single ? [.init(localID: "synthetic-other", modifiedAt: nil, kind: .photo)] : []))
        do {
            try await store.prepare(scope: scope)
            try await store.savePhotoBackups(journal, scope: scope)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let liveJobID = journal.jobs[0].id
        let exporter = TakeoverResourceExporter(root: root.appending(path: "exports"), store: store, scope: scope)
        let script = TakeoverHTTPScript(store: store, scope: scope, liveJobID: liveJobID)
        TakeoverURLProtocol.install(script, endpoint: endpoint)
        // 不同窗口使用各自的真实SQLite连接/manager，避免以共享Controller状态冒充接管。
        let firstManager = LibraryManagementController(configurationFactory: Self.configuration)
        let waitingManager = LibraryManagementController(configurationFactory: Self.configuration)
        firstManager.configure(session: session, endpoint: endpoint)
        waitingManager.configure(session: session, endpoint: endpoint)
        self.root = root; self.endpoint = endpoint; self.scope = scope; self.store = store
        self.liveJobID = liveJobID; otherJobID = journal.jobs.dropFirst().first?.id
        self.exporter = exporter; self.script = script
        self.firstManager = firstManager; self.waitingManager = waitingManager
        first = PhotoBackupController(store: SQLiteLibraryIndexStore(databaseURL: databaseURL), exporter: exporter)
        waiting = PhotoBackupController(store: SQLiteLibraryIndexStore(databaseURL: databaseURL), exporter: exporter)
    }

    /// 返回只拦截本测试会话的配置；无全局注册、真实Cookie或真实网络回退。
    private nonisolated static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TakeoverURLProtocol.self]
        return configuration
    }

    /// single绑定明确按钮语义；完整执行真实接管，并独立读取SQLite、请求、计数和资源清理结果。
    func exercise(single: Bool) async throws {
        #expect(firstManager.backupScope == waitingManager.backupScope && waitingManager.backupScope == scope)
        await first.load(using: firstManager)
        await waiting.load(using: waitingManager)
        #expect(first.jobs.map(\.id) == waiting.jobs.map(\.id))
        #expect(waiting.jobs.map(\.id) == [liveJobID] + (otherJobID.map { [$0] } ?? []))
        let old = try #require(first.resume(using: firstManager))
        firstRun = old
        observer = Task { await old.value; await script.oldOperationFinished() }
        try #require(await script.waitForOldPrimary(), "The real controller must reach the held primary duplicate check")

        // 主帧请求已经发出，动态回执必须先落盘；此处不是手工设置job阶段。
        let interrupted = try await store.loadPhotoBackups(scope: scope)
        let partial = try #require(interrupted.jobs.first)
        #expect(partial.stage == .uploadingPrimary && partial.attempts == 1)
        #expect(partial.motionAssetID == takeoverMotionID && partial.primaryAssetID == nil)
        #expect(first.running && firstManager.busy && !waiting.running)
        if let otherJobID {
            #expect(interrupted.jobs.first { $0.id == otherJobID }?.stage == .queued)
        }

        // 旧上下文不能再暂停回写；已经打开的B直接接管，不重新调用load来掩盖resume恢复缺陷。
        firstManager.configure(session: nil, endpoint: nil)
        let next = try #require(waiting.resume(using: waitingManager, jobID: single ? liveJobID : nil))
        waitingRun = next
        await next.value
        await old.value
        let completed = try await store.loadPhotoBackups(scope: scope)
        let confirmed = try #require(completed.jobs.first)
        #expect(confirmed.id == liveJobID && confirmed.stage == .completed && confirmed.attempts == 2)
        #expect(confirmed.motionAssetID == takeoverMotionID && confirmed.primaryAssetID == takeoverPrimaryID && confirmed.primaryWasDuplicate)
        #expect(confirmed.failure == nil && waiting.completed == 1 && waiting.duplicates == 1 && waiting.failed == 0)
        #expect(!first.running && !waiting.running && !firstManager.busy && !waitingManager.busy)
        #expect(first.completed == 0 && firstManager.revision == 0 && waitingManager.revision == 1)
        #expect(waiting.jobs.first?.stage == .completed && waiting.jobs.first?.attempts == 2)
        if let otherJobID {
            let other = try #require(completed.jobs.first { $0.id == otherJobID })
            #expect(other.stage == .paused && other.attempts == 0 && other.primaryAssetID == nil)
            #expect(waiting.jobs.first { $0.id == otherJobID }?.stage == .paused)
        }
        #expect(exporter.observations.map(\.localID) == ["synthetic-live", "synthetic-live"])
        #expect(exporter.observations.map(\.stage) == [.exporting, .exporting])
        #expect(exporter.observations.map(\.attempts) == [1, 2] && exporter.observations.allSatisfy { !$0.allowCloud })
        #expect(exporter.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let requests = await script.requests()
        try #require(requests.count == 6)
        #expect(requests.map(\.job.stage) == [.uploadingMotion, .uploadingPrimary, .uploadingMotion, .uploadingPrimary, .verifying, .verifying])
        #expect(requests.map(\.job.attempts) == [1, 1, 2, 2, 2, 2])
        #expect(requests[2].job.motionAssetID == takeoverMotionID && requests[2].job.primaryAssetID == nil)
        #expect(requests[4].job.motionAssetID == takeoverMotionID && requests[4].job.primaryAssetID == takeoverPrimaryID)
        #expect(requests[5].job.motionAssetID == takeoverMotionID && requests[5].job.primaryAssetID == takeoverPrimaryID)
        var correlations = Set<String>()
        for index in 0 ..< 4 {
            let checksum = index.isMultiple(of: 2) ? takeoverMotionChecksum : takeoverPrimaryChecksum
            let correlation = try assertTakeoverRequest(requests[index].request, endpoint: endpoint, checksum: checksum)
            let unique = correlations.insert(correlation).inserted
            #expect(unique)
        }
        #expect(requests[4].request.method == "GET" && requests[4].request.url == endpoint.appending(path: "assets/\(takeoverPrimaryID.uuidString)"))
        #expect(requests[4].request.body == nil && requests[4].request.contentType == nil)
        #expect(requests[5].request.method == "GET" && requests[5].request.url == endpoint.appending(path: "assets/\(takeoverMotionID.uuidString)"))
        #expect(requests[5].request.authorization == "Bearer takeover-fixture" && requests[5].request.body == nil && requests[5].request.contentType == nil)

        // 迟到服务器响应真正退出协议任务后再核对，避免仅在释放gate前比较快照造成假通过。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeLate = try encoder.encode(completed)
        await script.releaseOldPrimary()
        try #require(await script.waitForOldResponseExit(), "The old HTTP responder must retire after release")
        let afterLate = try await store.loadPhotoBackups(scope: scope)
        #expect(try encoder.encode(afterLate) == beforeLate)
        #expect(firstManager.revision == 0 && waitingManager.revision == 1)
        #expect(await script.requests().count == 6)
    }

    /// 即使超时/断言提前抛错，也取消实际任务和URLSession，并释放所有响应/观察门。
    func stop() async {
        first.cancel(); waiting.cancel(); firstRun?.cancel(); waitingRun?.cancel()
        firstManager.configure(session: nil, endpoint: nil)
        waitingManager.configure(session: nil, endpoint: nil)
        await script.abort()
    }

    /// 只在所有业务任务和旧HTTP响应退出后删除本例根目录；不触及系统照片库或应用账号。
    func close() async {
        await stop()
        await firstRun?.value; await waitingRun?.value; await observer?.value
        _ = await script.waitForOldResponseExit()
        TakeoverURLProtocol.remove(endpoint: endpoint)
        try? FileManager.default.removeItem(at: root)
    }
}

/// 仅替代PhotoKit导出；真实读取SQLite证明begin已保存，写两个微小原始文件供真实SHA1/查重流程使用。
@MainActor private final class TakeoverResourceExporter: PhotoBackupResourceExporting {
    /// 记录导出时实际源、持久阶段/次数及iCloud选项，不以生产Controller的内存列表生成答案。
    struct Observation {
        let localID: String
        let stage: PhotoBackupJob.Stage
        let attempts: Int
        let allowCloud: Bool
    }

    let root: URL
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    private(set) var observations: [Observation] = []
    private(set) var directories: [URL] = []

    /// root只存本测试合成文件；store/scope用于独立读取已落盘任务，不能修改业务状态。
    init(root: URL, store: SQLiteLibraryIndexStore, scope: MediaAccountScope) {
        self.root = root; self.store = store; self.scope = scope
    }

    /// source为真实worker请求，allowCloud只记录选项；返回新目录，清理由生产worker负责。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        let journal = try await store.loadPhotoBackups(scope: scope)
        guard let job = journal.jobs.first(where: { $0.source == source }) else { throw PhotoBackupStateError.invalidTransition }
        observations.append(.init(localID: source.localID, stage: job.stage, attempts: job.attempts, allowCloud: allowCloud))
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let primary = directory.appending(path: "synthetic.jpg")
        let motion = directory.appending(path: "synthetic.mov")
        try takeoverPrimaryBytes.write(to: primary); try takeoverMotionBytes.write(to: motion)
        return .init(directory: directory, primary: .init(file: primary, name: "synthetic.jpg"),
                     motion: source.kind == .livePhoto ? .init(file: motion, name: "synthetic.mov") : nil,
                     created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0), favorite: false)
    }
}

/// 真正URLSession请求的有限不可变快照，避免将Foundation流跨Actor发送。
private nonisolated struct TakeoverRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let cookie: String?
    let body: Data?

    /// request来自本测试会话；完整读取最多100KB JSON，无媒体文件或真实凭据。
    init(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else { throw URLError(.badURL) }
        self.method = method; self.url = url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type"); cookie = request.value(forHTTPHeaderField: "Cookie")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 100_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = bytes
        } else {
            body = nil
        }
    }
}

/// 一个请求及独立SQLite连接当时读取的任务快照；不会向Controller/Worker注入阶段。
private nonisolated struct TakeoverHTTPObservation: Sendable { let request: TakeoverRequest; let job: PhotoBackupJob }

/// 固定HTTP回执及序号；序号用于确认旧响应真正退出，而不是仅释放了continuation。
private nonisolated struct TakeoverReply: Sendable { let step: Int; let data: Data }

/// 真实查重请求的小型边界DTO；correlation由客户端生成，响应只原样关联该一次请求。
private nonisolated struct TakeoverCheck: Decodable {
    /// 每次只查一个真实合成文件的SHA1；不允许旧回执取代新的请求。
    struct Item: Decodable { let id: String; let checksum: String }
    let assets: [Item]
}

/// 合成重复响应仍经过真实客户端的ID/回收站校验，不替代上传或worker业务。
private nonisolated struct TakeoverDuplicateResponse: Encodable {
    /// id为本次correlation，assetId为固定合成服务器回执；false明确表示不在回收站。
    struct Item: Encodable { let id: String; let action: String; let assetId: String; let isTrashed: Bool }
    let results: [Item]
}

/// 固定六次HTTP交换并在旧主帧查重处挂起；最后still/motion回读均在真实verifying检查点。
private actor TakeoverHTTPScript {
    private let store: SQLiteLibraryIndexStore
    private let scope: MediaAccountScope
    private let liveJobID: UUID
    private var observations: [TakeoverHTTPObservation] = []
    private var oldPrimary: CheckedContinuation<Void, Never>?
    private var gateObservers: [CheckedContinuation<Bool, Never>] = []
    private var exitObservers: [CheckedContinuation<Bool, Never>] = []
    private var held = false
    private var oldFinished = false
    private var oldResponseExited = false
    private var aborted = false

    /// store/scope/liveJobID只用于独立观察真实检查点；不写入任务、不根据Controller结果伪造回答。
    init(store: SQLiteLibraryIndexStore, scope: MediaAccountScope, liveJobID: UUID) {
        self.store = store; self.scope = scope; self.liveJobID = liveJobID
    }

    /// request为真实Bearer请求，endpoint为隔离API根；四次查重后依次GET still/motion，不跳过动态核对。
    func response(_ request: TakeoverRequest, endpoint: URL) async throws -> TakeoverReply {
        guard !aborted else { throw CancellationError() }
        let step = observations.count
        guard step < 6, request.authorization == "Bearer takeover-fixture", request.cookie == nil else { throw URLError(.badServerResponse) }
        let journal = try await store.loadPhotoBackups(scope: scope)
        guard !aborted else { throw CancellationError() }
        guard let job = journal.jobs.first(where: { $0.id == liveJobID }) else { throw PhotoBackupStateError.invalidTransition }
        observations.append(.init(request: request, job: job))
        if step >= 4 {
            let id = step == 4 ? takeoverPrimaryID : takeoverMotionID
            guard request.method == "GET", request.url == endpoint.appending(path: "assets/\(id.uuidString)"),
                  request.body == nil else { throw URLError(.badServerResponse) }
            return .init(step: step, data: Data((step == 4 ? takeoverAssetJSON : takeoverMotionAssetJSON).utf8))
        }
        guard request.method == "POST", request.url == endpoint.appending(path: "assets/bulk-upload-check"),
              request.contentType == "application/json", let body = request.body else { throw URLError(.badServerResponse) }
        let check = try JSONDecoder().decode(TakeoverCheck.self, from: body)
        guard check.assets.count == 1, let item = check.assets.first, UUID(uuidString: item.id) != nil,
              item.checksum == (step.isMultiple(of: 2) ? takeoverMotionChecksum : takeoverPrimaryChecksum) else { throw URLError(.badServerResponse) }
        if step == 1 {
            await withCheckedContinuation { continuation in
                oldPrimary = continuation; held = true
                let observers = gateObservers; gateObservers = []; observers.forEach { $0.resume(returning: true) }
            }
        }
        let assetID = step.isMultiple(of: 2) ? takeoverMotionID : takeoverPrimaryID
        let data = try JSONEncoder().encode(TakeoverDuplicateResponse(results: [.init(id: item.id, action: "reject", assetId: assetID.uuidString, isTrashed: false)]))
        return .init(step: step, data: data)
    }

    /// 返回全部真实请求与磁盘快照供测试独立断言，不在协议回调吞掉失败。
    func requests() -> [TakeoverHTTPObservation] {
        observations
    }

    /// 旧任务未到达gate便结束时返回false；超时/取消也通过abort唤醒，不无限等待。
    func waitForOldPrimary() async -> Bool {
        if held {
            return true
        }
        if oldFinished || aborted {
            return false
        }
        return await withCheckedContinuation { gateObservers.append($0) }
    }

    /// Controller返回完整任务句柄后调用；早期错误与未达到预期HTTP的回归均唤醒观察者。
    func oldOperationFinished() {
        oldFinished = true
        if !held {
            let observers = gateObservers; gateObservers = []; observers.forEach { $0.resume(returning: false) }
        }
    }

    /// 释放旧主帧的真实HTTP响应，不取消或改变生产业务任务。
    func releaseOldPrimary() {
        oldPrimary?.resume(); oldPrimary = nil
    }

    /// step为已完成交付/已丢弃的协议响应；只在旧主帧退出后确认迟到响应检查点。
    func responseExited(step: Int) {
        guard step == 1 else { return }
        oldResponseExited = true
        let observers = exitObservers; exitObservers = []; observers.forEach { $0.resume(returning: true) }
    }

    /// 等待旧响应实际退出；根本未进入gate的早期失败返回false，不悬挂清理任务。
    func waitForOldResponseExit() async -> Bool {
        if oldResponseExited {
            return true
        }
        if !held, oldFinished || aborted {
            return false
        }
        return await withCheckedContinuation { exitObservers.append($0) }
    }

    /// 测试失败/取消清理：释放正在等待的服务响应及所有观察continuation，不影响真实服务。
    func abort() {
        aborted = true; releaseOldPrimary()
        let gates = gateObservers; gateObservers = []; gates.forEach { $0.resume(returning: false) }
        let exits = exitObservers; exitObservers = []; exits.forEach { $0.resume(returning: false) }
    }
}

/// request/endpoint/checksum为实际请求及独立参考值；完整比较JSON，额外字段或省略值也必须失败。
private nonisolated func assertTakeoverRequest(_ request: TakeoverRequest, endpoint: URL, checksum: String) throws -> String {
    #expect(request.method == "POST" && request.url == endpoint.appending(path: "assets/bulk-upload-check"))
    #expect(request.authorization == "Bearer takeover-fixture" && request.contentType == "application/json" && request.cookie == nil)
    let data = try #require(request.body)
    let decoded = try JSONDecoder().decode(TakeoverCheck.self, from: data)
    let item = try #require(decoded.assets.first)
    let expected: [String: Any] = ["assets": [["id": item.id, "checksum": checksum]]]
    let actual = try JSONSerialization.jsonObject(with: data)
    #expect(UUID(uuidString: item.id) != nil)
    #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
    return item.id
}

/// 仅安装于本测试会话的URLProtocol；所有未知host/路由均失败，绝无真实网络回退。
private final nonisolated class TakeoverURLProtocol: URLProtocol, @unchecked Sendable {
    /// 私有host注册项，不使用URLProtocol的进程全局注册。
    private struct Entry: Sendable { let script: TakeoverHTTPScript; let endpoint: URL }
    /// Mutex保护URLSession线程取消与异步响应任务安装的竞争。
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: Entry]>([:])
    private let loading = Mutex(Loading())

    /// script/endpoint属于一个随机host，不覆盖其他测试会话。
    static func install(_ script: TakeoverHTTPScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
    }

    /// 本测试任务退出后移除自己的host，不影响正常URLSession。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 拦截隔离会话的所有请求，错误host也必须失败而非流入外网。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留实际请求，不在测试替身中修正生产路径/字段。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 完整请求经过脚本和真实SQLite读取；取消后丢弃旧字节，再显式通知响应已退役。
    override func startLoading() {
        do {
            let capturedRequest = try TakeoverRequest(request)
            guard let entry = Self.scripts.withLock({ $0[capturedRequest.url.host ?? ""] }) else { throw URLError(.badURL) }
            // 快照/脚本显式跨入Task；旧响应退出通知仍在取消后执行，不能省略gate清理。
            let task = Task { @Sendable [weak self, capturedRequest, entry] in
                var completedStep: Int?
                do {
                    let reply = try await entry.script.response(capturedRequest, endpoint: entry.endpoint)
                    completedStep = reply.step
                    if let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) {
                        guard let response = HTTPURLResponse(url: capturedRequest.url, statusCode: 200, httpVersion: nil,
                                                             headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: reply.data)
                        client?.urlProtocolDidFinishLoading(self)
                    }
                } catch {
                    if let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
                if let completedStep {
                    await entry.script.responseExited(step: completedStep)
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 真实会话/Task取消后拒绝迟到交付；响应continuation由脚本显式释放，清理也能唤醒。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}
