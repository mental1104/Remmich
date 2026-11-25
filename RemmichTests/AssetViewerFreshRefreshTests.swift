import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实单张GET→有限观察→查看器session发布；隔离URLSession fixture不发送真实HTTP，不伪造派生ready。
@Suite("Fresh viewer asset refresh")
@MainActor
struct AssetViewerFreshRefreshTests {
    /// HTTP读取使用当前选中ID/owner、精确200、Bearer/前缀路径及4秒超时；保留同秒的新版本而不猜尺寸。
    @Test func freshGetPublishesServerSummaryAndPreservesSelection() async throws {
        let fixture = makeFixture(bodies: [document(updated: "1970-01-01T00:01:40.200Z", width: 40, height: 60)])
        defer { fixture.close() }
        let initial = asset()
        let session = AssetViewerSession(route: .init(selectedAsset: initial, initialAssets: [initial], origin: .timeline(bucketID: .init(rawValue: "synthetic"), contentName: "Synthetic")))
        let controller = AssetViewerRefreshController(pause: {})
        await controller.refresh(asset: initial, afterEdit: false, read: {
            try await fixture.client.freshViewerAsset(initial.id, ownerID: initial.ownerID)
        }, isCurrent: { true }, publish: { session.replaceSelectedAsset($0) }).value
        let selected = try #require(session.selectedAsset)
        #expect(selected.id == initial.id && selected.ownerID == initial.ownerID && session.selectedAssetID == initial.id)
        #expect(selected.capturedAt == initial.capturedAt && selected.uploadedAt == initial.uploadedAt)
        #expect(abs(selected.thumbnailRevision.timeIntervalSince1970 - 100.2) < 0.0001)
        #expect(selected.thumbnailRevision != initial.thumbnailRevision && selected.aspectRatio == 40.0 / 60)
        #expect(selected.isFavorite && selected.visibility == .archive && selected.thumbhash == "synthetic")
        #expect(!controller.busy && controller.message?.contains("可能仍在生成") == true)
        let requests = fixture.transport.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1 && request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.path == "/prefix/api/assets/\(initial.id)" && request.url?.query == nil)
        #expect(request.timeoutInterval == 4 && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    }

    /// 编辑后即使版本始终不变，也只读取四次，最终保留未确认生成的提示；不能持续轮询或标记ready。
    @Test func editObservationStopsAfterFourRealReads() async {
        let fixture = makeFixture(bodies: Array(repeating: document(updated: "1970-01-01T00:01:40.100Z"), count: 4))
        defer { fixture.close() }
        let initial = asset()
        let controller = AssetViewerRefreshController(pause: {})
        var publications: [TimelineAssetSummary] = []
        await controller.refresh(asset: initial, afterEdit: true, read: {
            try await fixture.client.freshViewerAsset(initial.id, ownerID: initial.ownerID)
        }, isCurrent: { true }, publish: { publications.append($0); return true }).value
        #expect(fixture.transport.requests.count == 4 && publications.count == 4)
        #expect(publications.allSatisfy { abs($0.thumbnailRevision.timeIntervalSince1970 - 100.1) < 0.0001 })
        #expect(!controller.busy && controller.message == "编辑参数已保存。预览可能仍在生成，可再次刷新。")
    }

    /// 首次读取后在间隔中切换资源/账号/路由或进入后台，旧任务不得继续GET或发布；取消不以成功状态替代。
    @Test(arguments: ["selection", "account", "route", "background"])
    func contextCancellationStopsFurtherReads(_ reason: String) async throws {
        let fixture = makeFixture(bodies: Array(repeating: document(updated: "1970-01-01T00:01:40.200Z"), count: 4))
        defer { fixture.close() }
        let gate = ViewerRefreshPauseGate()
        let controller = AssetViewerRefreshController(pause: { await gate.pause() })
        let initial = asset()
        let other = asset(id: "22222222-2222-4222-8222-222222222222")
        let session = AssetViewerSession(route: .init(selectedAsset: initial, initialAssets: [initial, other], origin: .timeline(bucketID: .init(rawValue: "synthetic"), contentName: "Synthetic")))
        let manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ViewerFreshProtocol.self]
            return configuration
        })
        let account = AccountSession(apiURL: fixture.client.apiURL, accessToken: "synthetic", userID: initial.ownerID,
                                     userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        manager.configure(session: account, endpoint: account.apiURL)
        defer { manager.configure(session: nil, endpoint: nil) }
        let client = try #require(manager.client)
        let owner = manager.generation
        var foreground = true
        var publications = 0
        let task = controller.refresh(asset: initial, afterEdit: true, read: {
            do { return try await client.freshViewerAsset(initial.id, ownerID: initial.ownerID) }
            catch { await gate.release(); throw error }
        }, isCurrent: { manager.generation == owner && session.selectedAssetID == initial.id && foreground }, publish: { _ in publications += 1; return true })
        await gate.reached()
        #expect(controller.busy && publications == 1)
        switch reason {
        case "selection": #expect(session.selectImmediately(other.id))
        case "account":
            let switched = AccountSession(apiURL: account.apiURL, accessToken: "synthetic-other", userID: "other-owner",
                                          userEmail: "other@example.invalid", name: "Other", isAdmin: false, serverVersion: account.serverVersion)
            manager.configure(session: switched, endpoint: switched.apiURL)
            #expect(manager.generation != owner)
        case "route":
            manager.configure(session: account, endpoint: account.apiURL.appending(path: "alias"))
            #expect(manager.generation != owner)
        default: foreground = false
        }
        controller.cancel()
        await gate.release()
        await task.value
        #expect(fixture.transport.requests.count == 1 && publications == 1)
        #expect(!controller.busy && controller.message == nil)
    }

    /// 取消不可依赖底层read及时返回；明确读取一次新资源后，旧读取即使返回真实DTO也不能覆盖新状态。
    @Test func obsoletePendingReadCannotPublishAfterReplacement() async throws {
        let fixture = makeFixture(bodies: [document(updated: "1970-01-01T00:01:40.200Z")])
        defer { fixture.close() }
        let gate = ViewerRefreshPauseGate()
        let initial = asset()
        let dto = try JSONDecoder().decode(AssetViewerFreshAsset.self, from: Data(document(updated: "1970-01-01T00:01:40.100Z").utf8))
        let controller = AssetViewerRefreshController(pause: {})
        var published: [Date] = []
        let old = controller.refresh(asset: initial, afterEdit: false, read: {
            await gate.pause()
            return dto
        }, isCurrent: { true }, publish: { published.append($0.thumbnailRevision); return true })
        await gate.reached()
        await controller.refresh(asset: initial, afterEdit: false, read: {
            try await fixture.client.freshViewerAsset(initial.id, ownerID: initial.ownerID)
        }, isCurrent: { true }, publish: { published.append($0.thumbnailRevision); return true }).value
        await gate.release()
        await old.value
        #expect(published.count == 1 && abs((published.first?.timeIntervalSince1970 ?? 0) - 100.2) < 0.0001)
    }

    /// 正在读取的旧邻居桶晚返回时，不能用同id旧summary覆盖直读的新版本；选择和源列表都保留更新。
    @Test func lateBucketLoadingKeepsTheFreshSelectedVersion() async throws {
        let initial = asset()
        let gate = ViewerRefreshPauseGate()
        let bucket = TimelineBucketID(rawValue: "synthetic")
        let session = AssetViewerSession(route: .init(selectedAsset: initial, initialAssets: [initial], origin: .timeline(bucketID: bucket, contentName: "Synthetic")), bucketIDs: [bucket], loadBucket: { _ in
            await gate.pause()
            return [initial]
        })
        let loading = Task { await session.start() }
        await gate.reached()
        let dto = try JSONDecoder().decode(AssetViewerFreshAsset.self, from: Data(document(updated: "1970-01-01T00:01:40.200Z", width: 40, height: 60).utf8))
        let fresh = try dto.replacing(initial)
        #expect(session.replaceSelectedAsset(fresh))
        await gate.release()
        await loading.value
        #expect(session.selectedAsset == fresh && session.sourceAssets.first == fresh && session.selectedAssetID == initial.id)
        #expect(!session.replaceSelectedAsset(initial))
    }

    /// 非200/失配ID或owner/视频/错误版本/超时都失败且不发布；显式新刷新可以恢复，不以旧缓存成功掩盖错误。
    @Test(arguments: ["201", "403", "wrong-id", "wrong-owner", "video", "bad-date", "timeout"])
    func failedReadsRequireExplicitRetry(_ scenario: String) async {
        var body = document(updated: "1970-01-01T00:01:40.200Z")
        switch scenario {
        case "wrong-id": body = body.replacingOccurrences(of: id, with: "22222222-2222-4222-8222-222222222222")
        case "wrong-owner": body = body.replacingOccurrences(of: "synthetic-owner", with: "different-owner")
        case "video": body = body.replacingOccurrences(of: "IMAGE", with: "VIDEO")
        case "bad-date": body = body.replacingOccurrences(of: "1970-01-01T00:01:40.200Z", with: "bad-date")
        default: break
        }
        let fixture = makeFixture(bodies: [body, document(updated: "1970-01-01T00:01:40.200Z")],
                                  firstStatus: Int(scenario) ?? 200, timesOutFirst: scenario == "timeout")
        defer { fixture.close() }
        let initial = asset()
        let controller = AssetViewerRefreshController(pause: {})
        var publications = 0
        let read: @Sendable () async throws -> AssetViewerFreshAsset = { try await fixture.client.freshViewerAsset(initial.id, ownerID: initial.ownerID) }
        await controller.refresh(asset: initial, afterEdit: true, read: read, isCurrent: { true }, publish: { _ in publications += 1; return true }).value
        #expect(publications == 0 && fixture.transport.requests.count == 1 && controller.message?.contains("刷新未完成") == true)
        await controller.refresh(asset: initial, afterEdit: false, read: read, isCurrent: { true }, publish: { _ in publications += 1; return true }).value
        #expect(publications == 1 && fixture.transport.requests.count == 2 && !controller.busy)
    }

    /// 只使用合成UUID；源revision与新响应处于同一秒。
    private var id: String {
        "11111111-1111-4111-8111-111111111111"
    }

    /// 返回包含服务端真实显示字段的合成文档；updated/width/height由测试独立指定，不从产品变换推导。
    private func document(updated: String, width: Int = 60, height: Int = 40) -> String {
        #"{"id":"\#(id)","ownerId":"synthetic-owner","type":"IMAGE","livePhotoVideoId":null,"updatedAt":"\#(updated)","width":\#(width),"height":\#(height),"thumbhash":"synthetic","isFavorite":true,"visibility":"archive","isTrashed":false}"#
    }

    /// 返回独立初始session快照；不触发索引或访问图库。
    private func asset(id: String? = nil) -> TimelineAssetSummary {
        .init(id: id ?? self.id, ownerID: "synthetic-owner", capturedAt: .distantPast, uploadedAt: .distantPast, localOffsetHours: 8,
              mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1.5, isFavorite: false, visibility: .timeline,
              livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: Date(timeIntervalSince1970: 100.1))
    }

    /// 为每个真实client配置独立随机host+局部URLProtocol；只注册fixture映射，不修改全局网络处理器。
    private func makeFixture(bodies: [String], firstStatus: Int = 200, timesOutFirst: Bool = false) -> ViewerFreshFixture {
        let host = "viewer-\(UUID().uuidString.lowercased()).invalid"
        let transport = ViewerFreshTransport(bodies: bodies, firstStatus: firstStatus, timesOutFirst: timesOutFirst)
        ViewerFreshProtocol.handlers.withLock { $0[host] = transport }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ViewerFreshProtocol.self]
        let client = LibraryMutationClient(apiURL: URL(string: "https://\(host)/prefix/api")!, token: "synthetic", userID: "synthetic-owner", configuration: configuration)
        return .init(client: client, transport: transport, host: host)
    }
}

/// fixture所有权包；退出时取消自己的真实URLSession并移除映射，不影响其他测试。
private nonisolated struct ViewerFreshFixture: Sendable {
    let client: LibraryMutationClient
    let transport: ViewerFreshTransport
    let host: String
    /// 只关闭本fixture通道和映射，不影响其他测试会话。
    func close() {
        client.cancel(); ViewerFreshProtocol.handlers.withLock { $0.removeValue(forKey: host) }
    }
}

/// 锁保护请求与固定响应序列，后台URLProtocol不读取MainActor测试状态。
private final nonisolated class ViewerFreshTransport: Sendable {
    /// 所有已拦截请求的有序副本，由外层Mutex独占保护。
    private struct State { var requests: [URLRequest] = [] }
    private let state = Mutex(State())
    private let bodies: [String]
    private let firstStatus: Int
    private let timesOutFirst: Bool
    /// bodies按请求序号返回，firstStatus/timesOutFirst只影响第一请求，便于验证显式第二次读取恢复。
    init(bodies: [String], firstStatus: Int, timesOutFirst: Bool) {
        self.bodies = bodies; self.firstStatus = firstStatus; self.timesOutFirst = timesOutFirst
    }

    /// 返回已记录请求的线程安全快照，不暴露可变状态。
    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    /// request来自真实URLSession；返回固定状态/字节或合成超时，不访问网络。
    func response(_ request: URLRequest) throws -> (Int, Data) {
        let index = state.withLock { value in let count = value.requests.count; value.requests.append(request); return count }
        guard bodies.indices.contains(index) else { throw URLError(.badServerResponse) }
        if index == 0, timesOutFirst {
            throw URLError(.timedOut)
        }
        return (index == 0 ? firstStatus : 200, Data(bodies[index].utf8))
    }
}

/// 每个host的处理器仅属于本suite构造的session；未登记host也直接报错，绝不透传真实HTTP。
private final nonisolated class ViewerFreshProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = Mutex<[String: ViewerFreshTransport]>([:])
    /// 拦截此session全部请求；未知host也不能落到真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留实际方法/路径/鉴权供独立断言。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 本fixture同步返回，没有延后任务需要清理；生产URLSession取消仍由会话拥有。
    override func stopLoading() {}
    /// 按随机host解析本地响应并交回真实session；缺fixture/越界等均报告错误，不发送HTTP。
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else { throw URLError(.badURL) }
            let (status, data) = try handler.response(request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

/// 只建立确定的测试时序；故意不因Task取消自行完成，验证生产状态机独立拒绝旧返回。
private actor ViewerRefreshPauseGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var closed = false
    /// 记录一个待恢复点；已释放的闸门直接完成，不读取测试线程中的状态。
    func pause() async {
        if closed {
            return
        }; await withCheckedContinuation { paused = $0; observer?.resume(); observer = nil }
    }

    /// 等待生产读取真正到达边界；错误路径release也唤醒观察者，避免测试因断言前失败而永久等待。
    func reached() async {
        if paused != nil || closed {
            return
        }; await withCheckedContinuation { observer = $0 }
    }

    /// 一次性结束暂停和观察者；取消任务仍由生产requestID/cancellation检查决定能否发布。
    func release() {
        closed = true; paused?.resume(); paused = nil; observer?.resume(); observer = nil
    }
}
