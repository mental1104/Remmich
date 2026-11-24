import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 用真实Store/manager/HTTP客户端验证批量操作；仅读源和HTTP字节为隔离合成夹具。
@Suite("Album batch management")
struct BatchAssetManagementStoreTests {
    /// kind遍历可达动作；逐个验证真实方法/路径/完整请求体及精确响应确认，原片从不被永久删除。
    @Test(arguments: ["favorite", "unfavorite", "archive", "timeline", "trash", "restore", "add", "remove", "cover"])
    @MainActor func sendsTheOfficialActionContract(_ kind: String) async throws {
        let action: BatchAssetAction
        let method: String
        let path: String
        let body: String
        let response: String
        let status: Int
        switch kind {
        case "favorite", "unfavorite":
            action = .favorite(kind == "favorite"); method = "PUT"; path = "assets/\(batchIDs[0])"
            body = kind == "favorite" ? #"{"isFavorite":true}"# : #"{"isFavorite":false}"#
            status = 200; response = "{}"
        case "archive", "timeline":
            action = .archived(kind == "archive"); method = "PUT"; path = "assets/\(batchIDs[0])"
            body = kind == "archive" ? #"{"visibility":"archive"}"# : #"{"visibility":"timeline"}"#
            status = 200; response = "{}"
        case "trash":
            action = .trash; method = "DELETE"; path = "assets"
            body = #"{"ids":["\#(batchIDs[0])"],"force":false}"#; status = 204; response = ""
        case "restore":
            action = .restore; method = "POST"; path = "trash/restore/assets"
            body = #"{"ids":["\#(batchIDs[0])"]}"#; status = 200; response = #"{"count":1}"#
        case "add", "remove":
            action = kind == "add" ? .addToAlbum(batchAlbum) : .removeFromAlbum(batchAlbum)
            method = kind == "add" ? "PUT" : "DELETE"; path = "albums/\(batchAlbum.id)/assets"
            body = #"{"ids":["\#(batchIDs[0])"]}"#; status = 200
            response = #"[{"id":"\#(batchIDs[0])","success":true}]"#
        default:
            action = .albumCover(batchAlbum); method = "PATCH"; path = "albums/\(batchAlbum.id)"
            body = #"{"albumThumbnailAssetId":"\#(batchIDs[0])"}"#; status = 200
            response = #"{"id":"\#(batchAlbum.id)","ownerId":"owner","albumName":"Synthetic album"}"#
        }
        let fixture = BatchHTTPFixture(exchanges: [.init(method: method, path: path, status: status, json: response)])
        defer { fixture.close() }
        let source = BatchReadFixture(pages: [[batchAsset(0)]])
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: source, manager: fixture.manager, scope: kind == "restore" ? .trash : .active)
        store.selectLoaded()
        let plan = try store.prepare(action, manager: fixture.manager)
        let request = try #require(store.start(plan, manager: fixture.manager))
        await request.value
        #expect(store.results == [.init(asset: batchAsset(0), state: .succeeded)])
        #expect(!store.hasFreshData && !store.isWorking && !fixture.manager.busy)
        #expect(fixture.manager.revision == 1)
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        try assertBatchRequest(requests[0], endpoint: fixture.endpoint, method: method, path: path, body: body)
        let query = try #require(await source.queries.first)
        #expect(query.albumID == batchAlbum.id && query.visibility == nil)
        #expect(!query.includesStacks && !query.includesPartners && query.includesTrashed == (kind == "restore"))
    }

    /// 相簿分页只全选已加载项；确认后又加载的资源不能暗中加入原选择，成功后必须重读。
    @Test @MainActor func paginationAndConfirmationKeepTheExactSelection() async throws {
        let fixture = BatchHTTPFixture(exchanges: batchIDs.prefix(2).map {
            .init(method: "PUT", path: "assets/\($0)", status: 200, json: "{}")
        })
        defer { fixture.close() }
        let source = BatchReadFixture(pages: [[batchAsset(0), batchAsset(1)], [batchAsset(1), batchAsset(2)]])
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: source, manager: fixture.manager)
        store.selectLoaded()
        let plan = try store.prepare(.favorite(true), manager: fixture.manager)
        let page = try #require(store.loadMore(manager: fixture.manager))
        await page.value
        #expect(store.assets.map(\.id) == batchIDs)
        #expect(store.selectedIDs == Set(batchIDs.prefix(2)))
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.results.map(\.id) == Array(batchIDs.prefix(2)))
        #expect(store.results.allSatisfy { $0.state == .succeeded })
        #expect(await fixture.script.requests().count == 2)
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.favorite(false), manager: fixture.manager) }
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 2)
    }

    /// 403保留单项拒绝并继续；401/429或未知结果立即停止，剩余项不发送，也不盲目重试。
    @Test(arguments: [201, 401, 403, 429, 503])
    @MainActor func separatesRejectedAndUnknownPartialResults(_ status: Int) async throws {
        var exchanges: [BatchHTTPExchange] = [
            .init(method: "PUT", path: "assets/\(batchIDs[0])", status: 200, json: "{}"),
            .init(method: "PUT", path: "assets/\(batchIDs[1])", status: status, json: "{}"),
        ]
        if status == 403 {
            exchanges.append(.init(method: "PUT", path: "assets/\(batchIDs[2])", status: 200, json: "{}"))
        }
        let fixture = BatchHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        let source = BatchReadFixture(pages: [[batchAsset(0), batchAsset(1), batchAsset(2)]])
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: source, manager: fixture.manager)
        store.selectLoaded()
        let plan = try store.prepare(.favorite(false), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        let middle: BatchAssetItemState = switch status {
        case 401: .rejected(.unauthorized)
        case 403: .rejected(.forbidden)
        case 429: .rejected(.rateLimited)
        default: .unconfirmed
        }
        #expect(store.results.map(\.state) == [.succeeded, middle, status == 403 ? .succeeded : .notAttempted])
        #expect(await fixture.script.requests().count == (status == 403 ? 3 : 2))
        #expect(!store.hasFreshData && !store.isWorking && fixture.manager.revision == 1)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        let reloadTask = store.reload(album: batchAlbum, scope: .active, factory: { source }, manager: fixture.manager)
        let reread = try #require(reloadTask)
        await reread.value
        #expect(store.hasFreshData && store.selectedIDs.isEmpty)
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.favorite(false), manager: fixture.manager) }
        #expect(await fixture.script.requests().count == (status == 403 ? 3 : 2))
    }

    /// 非本人照片的属性写入在本地明确拒绝；这不阻止其他已选本人照片得到各自真实回执。
    @Test @MainActor func ownershipIsCheckedForEachSelectedAsset() async throws {
        let fixture = BatchHTTPFixture(exchanges: [0, 2].map {
            .init(method: "PUT", path: "assets/\(batchIDs[$0])", status: 200, json: "{}")
        })
        defer { fixture.close() }
        let store = BatchAssetManagementStore()
        let source = BatchReadFixture(pages: [[batchAsset(0), batchAsset(1, owner: "another-owner"), batchAsset(2)]])
        try await loadBatch(store, source: source, manager: fixture.manager)
        store.selectLoaded()
        let plan = try store.prepare(.archived(true), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.results.map(\.state) == [.succeeded, .rejected(.notOwned), .succeeded])
        #expect(await fixture.script.requests().count == 2)
    }

    /// 同一个相簿接口返回success=false不能确认成员变化，后续项必须停止而非整组显示成功。
    @Test @MainActor func unconfirmedMembershipStopsRemainingItems() async throws {
        let fixture = BatchHTTPFixture(exchanges: [
            .init(method: "PUT", path: "albums/\(batchAlbum.id)/assets", status: 200, json: #"[{"id":"\#(batchIDs[0])","success":true}]"#),
            .init(method: "PUT", path: "albums/\(batchAlbum.id)/assets", status: 200, json: #"[{"id":"\#(batchIDs[1])","success":false,"error":"no_permission"}]"#),
        ])
        defer { fixture.close() }
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: BatchReadFixture(pages: [[batchAsset(0), batchAsset(1), batchAsset(2)]]), manager: fixture.manager)
        store.selectLoaded()
        let plan = try store.prepare(.addToAlbum(batchAlbum), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.results.map(\.state) == [.succeeded, .unconfirmed, .notAttempted])
        #expect(await fixture.script.requests().count == 2)
    }

    /// 取消一个确实在途的第二项，首项成功仍保留，当前项未知、第三项未发送，且没有自动重放。
    @Test @MainActor func cancellationKeepsAcknowledgedResultsAndStopsTheQueue() async throws {
        let fixture = BatchHTTPFixture(exchanges: [
            .init(method: "PUT", path: "assets/\(batchIDs[0])", status: 200, json: "{}"),
            .init(method: "PUT", path: "assets/\(batchIDs[1])", status: 200, json: "{}", held: true),
        ])
        defer { fixture.close() }
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: BatchReadFixture(pages: [[batchAsset(0), batchAsset(1), batchAsset(2)]]), manager: fixture.manager)
        store.selectLoaded()
        let plan = try store.prepare(.favorite(true), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        let completion = Task { await operation.value; await fixture.script.operationFinished() }
        let reached = await fixture.script.waitForHeldRequest()
        #expect(reached)
        store.cancel()
        await fixture.script.releaseHeldResponse()
        await completion.value
        #expect(store.results.map(\.state) == [.succeeded, .unconfirmed, .notAttempted])
        #expect(!store.isWorking && !fixture.manager.busy && !store.hasFreshData)
        #expect(fixture.manager.revision == 1)
        #expect(await fixture.script.requests().count == 2)
    }

    /// context区分换账号和换端点；真实旧URLSession取消后，旧任务不能改变新读源、选择或回执。
    @Test(arguments: ["account", "endpoint"])
    @MainActor func obsoleteWritesCannotPublishIntoTheNextContext(_ context: String) async throws {
        let fixture = BatchHTTPFixture(exchanges: [.init(method: "PUT", path: "assets/\(batchIDs[0])", status: 200, json: "{}", held: true)])
        defer { fixture.close() }
        let store = BatchAssetManagementStore()
        try await loadBatch(store, source: BatchReadFixture(pages: [[batchAsset(0)]]), manager: fixture.manager)
        store.selectLoaded()
        let oldPlan = try store.prepare(.favorite(true), manager: fixture.manager)
        let operation = try #require(store.start(oldPlan, manager: fixture.manager))
        let completion = Task { await operation.value; await fixture.script.operationFinished() }
        let reached = await fixture.script.waitForHeldRequest()
        #expect(reached)
        let nextEndpoint = context == "endpoint" ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
        fixture.manager.configure(session: batchSession(endpoint: fixture.endpoint, user: context == "account" ? "next-owner" : "owner"), endpoint: nextEndpoint)
        store.invalidate()
        let fresh = BatchReadFixture(pages: [[batchAsset(2, owner: "next-owner")]])
        let reread = store.reload(album: batchAlbum, scope: .active, factory: { fresh }, manager: fixture.manager)
        if let reread {
            await reread.value
        }
        #expect(store.assets.map(\.id) == [batchIDs[2]])
        #expect(store.start(oldPlan, manager: fixture.manager) == nil)
        await fixture.script.releaseHeldResponse()
        await completion.value
        #expect(store.assets.map(\.id) == [batchIDs[2]])
        #expect(store.results.isEmpty && store.selectedIDs.isEmpty && store.hasFreshData && !store.isWorking)
        #expect(!fixture.manager.busy && fixture.manager.revision == 0)
        #expect(await fixture.script.requests().count == 1)
    }

    /// 封面只能选择单个正常成员，恢复仅限回收站；无效计划不能发出任何网络写入。
    @Test @MainActor func requiresTheCorrectScopeAndOneCoverMember() async throws {
        let fixture = BatchHTTPFixture(exchanges: [])
        defer { fixture.close() }
        let store = BatchAssetManagementStore()
        let source = BatchReadFixture(pages: [[batchAsset(0), batchAsset(1)]])
        try await loadBatch(store, source: source, manager: fixture.manager)
        store.selectLoaded()
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.albumCover(batchAlbum), manager: fixture.manager) }
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.restore, manager: fixture.manager) }
        store.clearSelection()
        store.select(batchIDs[0], enabled: true)
        let otherAlbum = BatchAlbumReference(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Another album")
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.albumCover(otherAlbum), manager: fixture.manager) }
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.removeFromAlbum(otherAlbum), manager: fixture.manager) }
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.addToAlbum(.init(id: "invalid", name: "Invalid")), manager: fixture.manager) }
        try await loadBatch(store, source: source, manager: fixture.manager, scope: .trash)
        store.select(batchIDs[0], enabled: true)
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.trash, manager: fixture.manager) }
        #expect(throws: BatchAssetManagementError.self) { try store.prepare(.albumCover(batchAlbum), manager: fixture.manager) }
        #expect(await fixture.script.requests().isEmpty)
    }
}

/// 所有测试使用固定合法UUID和纯合成相簿，不关联真实媒体。
private nonisolated let batchIDs = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"]
private nonisolated let batchAlbum = BatchAlbumReference(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Synthetic album")

/// index选择合法合成身份，owner决定权限反例；返回不包含原片路径/真实EXIF的时间线资产。
private nonisolated func batchAsset(_ index: Int, owner: String = "owner") -> TimelineAssetSummary {
    let date = Date(timeIntervalSince1970: 0)
    return .init(id: batchIDs[index], ownerID: owner, capturedAt: date, uploadedAt: date, localOffsetHours: 0,
                 mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline,
                 livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date)
}

/// endpoint/user是合成会话上下文，不读取Keychain或真实登录。
private nonisolated func batchSession(endpoint: URL, user: String = "owner") -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic-\(user)", userID: user, userEmail: "\(user)@example.invalid", name: user,
          isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// store通过真实重载方法消费source；scope由独立测试指定，不绕过选择或确认状态机。
@MainActor private func loadBatch(_ store: BatchAssetManagementStore, source: BatchReadFixture,
                                  manager: LibraryManagementController, scope: BatchAssetScope = .active) async throws
{
    // 在宏外让factory按真实@Sendable参数求解，避免#require的参数捕获转发丢失闭包约束。
    let reloadTask = store.reload(album: batchAlbum, scope: scope, factory: { source }, manager: manager)
    let read = try #require(reloadTask)
    await read.value
    #expect(store.hasFreshData && !store.isLoading)
}

/// 只替代时间线字节来源，记录实际查询范围；不执行批量业务或改写Store状态。
private actor BatchReadFixture: TimelineReading {
    let pages: [[TimelineAssetSummary]]
    private(set) var queries: [TimelineQuery] = []

    /// pages为独立确定的桶内容，允许跨页重复ID以验证真实Store去重。
    init(pages: [[TimelineAssetSummary]]) {
        self.pages = pages
    }

    /// query记录调用方真实相簿/回收站范围，返回固定桶而非根据Store状态造答案。
    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        queries.append(query)
        return pages.indices.map { .init(id: .init(rawValue: "bucket-\($0)"), assetCount: pages[$0].count) }
    }

    /// bucketID必须是该读源声明的桶；query只记录实际传入值，空/错误索引明确失败。
    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        queries.append(query)
        guard let index = Int(bucketID.rawValue.replacingOccurrences(of: "bucket-", with: "")), pages.indices.contains(index) else {
            throw BatchAssetManagementError.invalidResponse
        }
        return pages[index]
    }

    /// 本页不生成回忆，不访问网络。
    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

/// 一次HTTP交换的预期响应；path始终相对测试API根，held只控制响应时序。
private nonisolated struct BatchHTTPExchange: Sendable {
    let method: String
    let path: String
    let status: Int
    let json: String
    var held = false
}

/// 真实URLSession请求的不可变快照，避免Foundation流跨actor共享。
private nonisolated struct BatchCapturedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let body: Data?

    /// request来自测试会话自己的URLProtocol；完整捕获有限JSON字节，不读取媒体文件。
    init(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else { throw URLError(.badURL) }
        self.method = method; self.url = url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 2048)
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

/// 独立请求序列与可取消响应gate；未知额外请求失败，绝不会建立真实网络连接。
private actor BatchHTTPScript {
    private let exchanges: [BatchHTTPExchange]
    private var captured: [BatchCapturedRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var observed = false
    private var finished = false

    /// exchanges是测试独立声明的精确顺序，不从批量业务状态反推响应。
    init(_ exchanges: [BatchHTTPExchange]) {
        self.exchanges = exchanges
    }

    /// request记录真实方法/路由/头/体；返回固定响应，held通过显式握手暂停一次。
    func response(for request: BatchCapturedRequest, endpoint: URL) async throws -> BatchHTTPExchange {
        let index = captured.count
        captured.append(request)
        guard exchanges.indices.contains(index) else { throw URLError(.badServerResponse) }
        let exchange = exchanges[index]
        guard request.method == exchange.method, request.url == endpoint.appending(path: exchange.path),
              request.authorization == "Bearer synthetic-owner", request.contentType == "application/json" else { throw URLError(.badServerResponse) }
        if exchange.held {
            await withCheckedContinuation { continuation in
                pending = continuation; observed = true
                waiter?.resume(returning: true); waiter = nil
            }
        }
        return exchange
    }

    /// 返回捕获值供测试上下文断言，不在URLSession非测试回调中伪造成功或吞掉失败。
    func requests() -> [BatchCapturedRequest] {
        captured
    }

    /// 等待已安装的在途响应；操作若提前失败会返回false，避免测试无限等待。
    func waitForHeldRequest() async -> Bool {
        if observed {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 真实Store操作结束后唤醒未到达gate的观察者，提前失败不能变成CI死锁。
    func operationFinished() {
        finished = true
        if !observed {
            waiter?.resume(returning: false); waiter = nil
        }
    }

    /// 测试在取消/换账号后释放原响应；URLProtocol仍须遵守真正取消，不强行向业务发送迟到成功。
    func releaseHeldResponse() {
        pending?.resume(); pending = nil
    }
}

/// 每个测试独占的会话/host配置，默认生产构造完全不变。
@MainActor private struct BatchHTTPFixture {
    let endpoint: URL
    let manager: LibraryManagementController
    let script: BatchHTTPScript

    /// exchanges为固定HTTP响应序列；只在本会话安装协议，所有意外host也由协议拒绝。
    init(exchanges: [BatchHTTPExchange]) {
        endpoint = URL(string: "https://batch-\(UUID().uuidString.lowercased()).invalid/api")!
        script = BatchHTTPScript(exchanges)
        BatchManagementProtocol.install(script, endpoint: endpoint)
        manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BatchManagementProtocol.self]
            return configuration
        })
        manager.configure(session: batchSession(endpoint: endpoint), endpoint: endpoint)
    }

    /// 先使真实客户端取消，再移除本测试host；不影响任何正常账户/URLSession。
    func close() {
        manager.configure(session: nil, endpoint: nil)
        BatchManagementProtocol.remove(endpoint: endpoint)
    }
}

/// fixture/method/path/body为独立期望；逐值比较完整JSON，避免只检查一个字段漏掉危险force/额外ID。
private nonisolated func assertBatchRequest(_ request: BatchCapturedRequest, endpoint: URL,
                                            method: String, path: String, body: String) throws
{
    #expect(request.method == method && request.url == endpoint.appending(path: path))
    #expect(request.authorization == "Bearer synthetic-owner" && request.contentType == "application/json")
    let actual = try JSONSerialization.jsonObject(with: #require(request.body))
    let expected = try JSONSerialization.jsonObject(with: Data(body.utf8))
    #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
}

/// 本地HTTP响应器只装入测试配置；每个随机host独立路由，取消状态跨URLSession回调线程同步。
private final nonisolated class BatchManagementProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry: Sendable { let script: BatchHTTPScript; let endpoint: URL }
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: Entry]>([:])
    private let loading = Mutex(Loading())

    /// script/endpoint属于一个测试，注册在本类私有表中，不调用URLProtocol全局注册。
    static func install(_ script: BatchHTTPScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
    }

    /// 只移除本测试endpoint，不影响其他并行测试或正常会话。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 拦截该隔离会话全部请求，确保错误host也不能落入真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 不改写原请求，实际路径与HTTP语义由生产客户端构建。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 快照请求后异步返回固定字节；捕获/路由错误直接使真正URLSession请求失败。
    override func startLoading() {
        do {
            let capturedRequest = try BatchCapturedRequest(request)
            guard let entry = Self.scripts.withLock({ $0[capturedRequest.url.host ?? ""] }) else { throw URLError(.badURL) }
            // 与目录夹具保持同一显式发送边界，Task只捕获不可变快照和受锁保护的self。
            let task = Task { @Sendable [weak self, capturedRequest, entry] in
                do {
                    let exchange = try await entry.script.response(for: capturedRequest, endpoint: entry.endpoint)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    guard let response = HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status, httpVersion: nil,
                                                         headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(exchange.json.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 真正URLSession取消后不再投递响应；响应gate仍由测试明确释放以清理fixture。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}
