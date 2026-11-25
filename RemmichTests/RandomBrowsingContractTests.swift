#if DEBUG
    import Foundation
    import Synchronization
    import Testing
    @testable import Remmich

    /// 真正Store→原repo→生成SDK→受限URLSession字节链；不访问socket、私人媒体或持久GET队列。
    @Suite("Random browsing HTTP and viewer")
    @MainActor struct RandomBrowsingContractTests {
        /// 真实两次POST消费不同批次；点击快照经实际Viewer启动/选择后仍保持原抽样顺序和拍摄日期。
        @Test func refreshesOfficialBatchesAndFreezesTheOpenedViewer() async throws {
            let fixture = await RandomBrowsingFixture(replies: [
                .init(json: randomPhotosJSON([randomPhotoJSON(randomA, date: "2026-09-01"), randomPhotoJSON(randomB, date: "2026-11-01"), randomPhotoJSON(randomA.uppercased())])),
                .init(json: randomPhotosJSON([randomPhotoJSON(randomC)])),
            ])
            defer { fixture.close() }
            let store = RandomPhotosStore()
            await store.refresh(source: fixture.repository)
            #expect(store.assets.map(\.id) == [randomA, randomB] && store.hasLoaded && !store.isLoading)
            let selection = try #require(RandomPhotoSelection(assetID: randomB, assets: store.assets))
            #expect(selection.route.ordering == .sourceOrder)
            let viewer = AssetViewerSession(route: selection.route, bucketIDs: selection.timeline.bucketSummaries.map(\.id),
                                            loadBucket: { await selection.timeline.rangeCoverAssets(in: $0) })
            await viewer.start()
            #expect(viewer.assets.map(\.id) == [randomA, randomB] && viewer.selectedIndex == 1)
            await store.refresh(source: fixture.repository)
            await viewer.select(randomA)
            #expect(store.assets.map(\.id) == [randomC])
            #expect(viewer.assets.map(\.id) == [randomA, randomB] && viewer.selectedAssetID == randomA)
            #expect(selection.route.initialAssets == viewer.assets)
            #expect(viewer.assets[0].capturedAt < viewer.assets[1].capturedAt)
            #expect(RandomPhotoSelection(assetID: randomA, assets: store.assets) == nil)
            try await fixture.assertRequests(2)
        }

        /// 精确HTTP200/有效安全范围才替换；合法空、错误JSON、权限、服务失败不能混为同一个空批次。
        @Test(arguments: ["201", "401", "403", "404", "429", "500", "json", "video", "archive", "trash", "overflow"])
        func failedRefreshRetainsConfirmedBatchWithoutRetry(_ kind: String) async throws {
            let bad: RandomBrowsingReply
            if let status = Int(kind) {
                bad = .init(status: status, json: "{}")
            } else {
                let item = randomPhotoJSON(randomB, type: kind == "video" ? "VIDEO" : "IMAGE",
                                           visibility: kind == "archive" ? "archive" : "timeline", trashed: kind == "trash")
                bad = .init(json: kind == "json" ? "{" : randomPhotosJSON(kind == "overflow" ? Array(repeating: item, count: 61) : [item]))
            }
            let fixture = await RandomBrowsingFixture(replies: [.init(json: randomPhotosJSON([randomPhotoJSON(randomA)])), bad])
            defer { fixture.close() }
            let store = RandomPhotosStore()
            await store.refresh(source: fixture.repository)
            await store.refresh(source: fixture.repository)
            #expect(store.assets.map(\.id) == [randomA] && store.hasLoaded && !store.isLoading && store.error != nil)
            try await fixture.assertRequests(2)
        }

        /// 空数组是已确认的单批空结果；读完不触发分页、metadata搜索或隐形再次抽样。
        @Test func emptyResponseIsConfirmedWithoutAutomaticContinuation() async throws {
            let fixture = await RandomBrowsingFixture(replies: [.init(json: "[]")]); defer { fixture.close() }
            let store = RandomPhotosStore()
            await store.refresh(source: fixture.repository)
            #expect(store.assets.isEmpty && store.hasLoaded && !store.isLoading && store.error == nil && !store.wasCancelled)
            try await fixture.assertRequests(1)
        }

        /// 旧POST真正进入URLSession后重新抽样；底层取消和代际共同保证迟到成功/失败不覆盖新批次。
        @Test(.timeLimit(.minutes(1)), arguments: [200, 500])
        func newShuffleCancelsInflightReadAndOwnsTheResult(_ oldStatus: Int) async throws {
            let fixture = await RandomBrowsingFixture(replies: [
                .init(status: oldStatus, json: randomPhotosJSON([randomPhotoJSON(randomA)]), held: true),
                .init(json: randomPhotosJSON([randomPhotoJSON(randomB)])),
            ])
            defer { fixture.close() }
            let store = RandomPhotosStore()
            let old = Task { await store.refresh(source: fixture.repository); await fixture.http.operationFinished() }
            try await withTaskCancellationHandler {
                try #require(await fixture.http.waitForHeld(), "The old random POST must reach its real URLSession gate")
                await store.refresh(source: fixture.repository)
                #expect(store.assets.map(\.id) == [randomB] && !store.isLoading && store.error == nil)
                await fixture.http.release()
                await old.value
                await fixture.http.waitForResponderExit()
                await fixture.http.waitForHeldStop()
                #expect(store.assets.map(\.id) == [randomB] && !store.isLoading && store.error == nil)
                #expect(await fixture.http.heldRequestWasStopped)
                try await fixture.assertRequests(2)
            } onCancel: { Task { await fixture.http.stop() } }
            await fixture.http.stop()
        }

        /// actual在途POST后取消/停止/换账号/换端点；只观察旧请求，路由退休后绝不向默认会话发新查询。
        @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "stop", "account", "endpoint", "repo-account", "repo-endpoint"])
        func retiredReadCannotPublishOrClearNewContext(_ kind: String) async throws {
            let fixture = await RandomBrowsingFixture(replies: [
                .init(json: randomPhotosJSON([randomPhotoJSON(randomA)])),
                .init(json: randomPhotosJSON([randomPhotoJSON(randomB)]), held: true),
            ])
            defer { fixture.close() }
            let store = RandomPhotosStore()
            await store.refresh(source: fixture.repository)
            let task = Task { await store.refresh(source: fixture.repository); await fixture.http.operationFinished() }
            try await withTaskCancellationHandler {
                try #require(await fixture.http.waitForHeld(), "The retiring random POST must enter its real request gate")
                switch kind {
                case "cancel": task.cancel()
                case "stop": store.cancel()
                default:
                    var account = fixture.account
                    if kind.contains("account") {
                        account = randomBrowsingAccount(endpoint: fixture.account.apiURL, user: randomOtherOwner, token: "synthetic-other")
                    }
                    let endpoint = kind.contains("endpoint") ? account.apiURL.appending(path: "retired-route") : account.apiURL
                    await fixture.repository.configure(session: account, activeEndpoint: endpoint)
                    if !kind.hasPrefix("repo-") {
                        store.invalidate()
                    }
                }
                await fixture.http.release()
                await task.value
                await fixture.http.waitForResponderExit()
                #expect(store.assets.map(\.id) == (["account", "endpoint"].contains(kind) ? [] : [randomA]))
                #expect(!store.isLoading && store.error == nil && store.wasCancelled == (kind == "stop"))
                if ["account", "endpoint"].contains(kind) {
                    #expect(!store.hasLoaded)
                }
                try await fixture.assertRequests(2)
            } onCancel: { Task { await fixture.http.stop() } }
            await fixture.http.stop()
        }

        /// 默认日期排序仍应用于真正Session初始化/桶加载/邻居和图片投影；随机选择只把该顺序换成来源顺序。
        @Test(arguments: [AssetViewerOrdering.chronological, .sourceOrder])
        func viewerOrderingSurvivesActualBucketAndNeighborLoads(_ ordering: AssetViewerOrdering) async throws {
            let dates = ["2026-09-01", "2026-11-01", "2026-10-01", "2027-01-01"]
            let fixture = await RandomBrowsingFixture(replies: [.init(json: randomPhotosJSON(zip([randomA, randomB, randomC, randomD], dates).map { randomPhotoJSON($0.0, date: $0.1) }))])
            defer { fixture.close() }
            let store = RandomPhotosStore(); await store.refresh(source: fixture.repository)
            let values = store.assets
            try #require(values.count == 4)
            let bucket = NativeSearchSnapshot.bucket
            let neighbor = TimelineBucketID(rawValue: "1969-12-01")
            var loaded: [TimelineBucketID] = []
            let route = AssetViewerRoute(selectedAsset: values[0], initialAssets: [values[0], values[1], values[0]],
                                         origin: .timeline(bucketID: bucket, contentName: "Synthetic"), ordering: ordering)
            let viewer = AssetViewerSession(route: route, bucketIDs: [bucket, neighbor]) { requested in
                loaded.append(requested)
                return requested == bucket ? Array(values.prefix(3)) : [values[3]]
            }
            #expect(viewer.assets.map(\.id) == (ordering == .sourceOrder ? [randomA, randomB] : [randomB, randomA]))
            await viewer.start()
            #expect(viewer.assets.map(\.id) == (ordering == .sourceOrder ? [randomA, randomB, randomC] : [randomD, randomB, randomC, randomA]))
            // 默认日期顺序中原选中项是末尾，start自然预取邻桶；来源顺序在明确选到末尾后才需要邻桶。
            if ordering == .sourceOrder {
                await viewer.select(randomC)
            }
            #expect(loaded == [bucket, neighbor])
            #expect(viewer.assets.map(\.id) == (ordering == .sourceOrder ? [randomA, randomB, randomC, randomD] : [randomD, randomB, randomC, randomA]))
            #expect(viewer.selectedAssetID == (ordering == .sourceOrder ? randomC : randomA))
            #expect(viewer.assets.allSatisfy { value in values.contains { $0.id == value.id && $0.capturedAt == value.capturedAt } })
            let defaultRoute = AssetViewerRoute(selectedAsset: values[0], initialAssets: [values[0], values[1]], origin: route.origin)
            #expect(defaultRoute.ordering == .chronological)
            #expect(AssetViewerSession(route: defaultRoute).assets.map(\.id) == [randomB, randomA])
            try await fixture.assertRequests(1)
        }
    }

    private nonisolated let randomA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private nonisolated let randomB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private nonisolated let randomC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private nonisolated let randomD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private nonisolated let randomOwner = "11111111-1111-4111-8111-111111111111"
    private nonisolated let randomOtherOwner = "22222222-2222-4222-8222-222222222222"

    /// endpoint/user/token均是合成值；返回真实repo会话配置，不读取Keychain或服务器。
    private nonisolated func randomBrowsingAccount(endpoint: URL, user: String = randomOwner, token: String = "synthetic-random") -> AccountSession {
        .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
              serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
    }

    /// id/date/type/visibility/trashed明确控制独立官方JSON资料，不靠待测summary或请求生成预期响应。
    private nonisolated func randomPhotoJSON(_ id: String, date: String = "2026-10-01", type: String = "IMAGE", visibility: String = "timeline", trashed: Bool = false) -> String {
        #"{"id":"\#(id)","originalPath":"/synthetic/photo.jpg","checksum":"synthetic","createdAt":"2026-11-01T00:00:00Z","fileCreatedAt":"\#(date)T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"isTrashed":\#(trashed),"localDateTime":"\#(date)T00:00:00Z","originalFileName":"synthetic.jpg","ownerId":"\#(randomOwner)","type":"\#(type)","updatedAt":"2026-11-01T00:00:00Z","visibility":"\#(visibility)"}"#
    }

    /// values是完整合成官方资产JSON；仅连接数组，不重新排序或模拟业务筛选。
    private nonisolated func randomPhotosJSON(_ values: [String]) -> String {
        "[" + values.joined(separator: ",") + "]"
    }

    /// 本测试独占会话/host和真实repo；SDK注入沿用已有DEBUG搜索入口，Release构造不变。
    @MainActor private final class RandomBrowsingFixture {
        let repository = ImmichTimelineRepository()
        let http: RandomBrowsingHTTP
        let account: AccountSession
        private let network: URLSession

        /// replies为顺序HTTP脚本；默认阻断全部host，不允许未登记请求回落socket。
        init(replies: [RandomBrowsingReply]) async {
            let endpoint = URL(string: "https://random-\(UUID().uuidString.lowercased()).example.invalid/immich/api")!
            account = randomBrowsingAccount(endpoint: endpoint)
            http = RandomBrowsingHTTP(replies: replies)
            RandomBrowsingProtocol.install(http, host: endpoint.host!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RandomBrowsingProtocol.self]
            configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 10
            network = URLSession(configuration: configuration, delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
            await repository.configureSearchUITest(session: account, networkSession: network)
        }

        /// count为真实有限抽样数；核精确POST/前缀/身份/完整JSON与无分页/无媒体额外请求。
        func assertRequests(_ count: Int) async throws {
            let captured = await http.requests
            #expect(captured.count == count)
            let expected = try JSONSerialization.jsonObject(with: Data(#"{"filter":{"trashedAt":{"eq":null},"type":{"eq":"IMAGE"},"visibility":{"eq":"timeline"}},"size":60,"withExif":true}"#.utf8)) as? NSDictionary
            for request in captured {
                #expect(request.method == "POST" && request.url == account.apiURL.appending(path: "search/random"))
                #expect(request.authorization == "Bearer synthetic-random" && request.contentType?.hasPrefix("application/json") == true)
                let body = try JSONSerialization.jsonObject(with: request.body) as? NSDictionary
                #expect(body == expected && body != nil)
                #expect(request.url.query == nil && request.url.fragment == nil)
            }
        }

        /// 结束时取消独占URLSession并释放actor门；不改全局会话或其他测试注册。
        func close() {
            network.invalidateAndCancel()
            RandomBrowsingProtocol.remove(host: account.apiURL.host!)
            Task { await http.stop() }
        }
    }

    /// 从实际URLSession请求捕获不可变Sendable字节，限1MiB；既支持httpBody也支持SDK流。
    private nonisolated struct RandomBrowsingRequest: Sendable {
        let id = UUID()
        let method: String
        let url: URL
        let authorization: String?
        let contentType: String?
        let body: Data

        /// request保留SDK实际路径/认证/正文；流缺失或超量明确抛错，不替测试补齐数据。
        init(_ request: URLRequest) throws {
            method = try #require(request.httpMethod); url = try #require(request.url)
            authorization = request.value(forHTTPHeaderField: "Authorization"); contentType = request.value(forHTTPHeaderField: "Content-Type")
            if let body = request.httpBody {
                guard body.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                self.body = body; return
            }
            let stream = try #require(request.httpBodyStream)
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                guard data.count + count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
    }

    /// 仅HTTP状态/原始JSON及可选在途门；不读取Store状态或伪造用户成功动作。
    private nonisolated struct RandomBrowsingReply: Sendable {
        var status = 200
        let json: String
        var held = false
    }

    /// 顺序有限响应脚本；真实取消停协议回调，gate仍由测试释放以核迟到边界与资源清理。
    private actor RandomBrowsingHTTP {
        private var replies: [RandomBrowsingReply]
        private(set) var requests: [RandomBrowsingRequest] = []
        private var stoppedIDs: Set<UUID> = []
        private var heldRequestID: UUID?
        private var heldStop: CheckedContinuation<Void, Never>?
        private var gate: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Bool, Never>?
        private var responderExit: CheckedContinuation<Void, Never>?
        private var didReturn = false
        private var finished = false

        /// replies不得隐形补充；多余请求明确失败并唤醒等待者。
        init(replies: [RandomBrowsingReply]) {
            self.replies = replies
        }

        /// request为实际HTTP快照；消费一条预期响应，held仅暂停返回，不模拟SDK取消逻辑。
        func response(_ request: RandomBrowsingRequest) async throws -> RandomBrowsingReply {
            requests.append(request)
            guard !replies.isEmpty else { operationFinished(); throw URLError(.badServerResponse) }
            let reply = replies.removeFirst()
            if reply.held {
                heldRequestID = request.id
                await withCheckedContinuation { gate = $0; entered?.resume(returning: true); entered = nil }
                didReturn = true; responderExit?.resume(); responderExit = nil
            }
            return reply
        }

        /// id来自实际协议请求；只记录URLSession真正stopLoading，不将新请求结束当成旧请求取消。
        func stopped(_ id: UUID) {
            stoppedIDs.insert(id)
            if heldRequestID == id {
                heldStop?.resume(); heldStop = nil
            }
        }

        var heldRequestWasStopped: Bool {
            heldRequestID.map { stoppedIDs.contains($0) } ?? false
        }

        /// 等同一旧请求收到stop；URLSession完成与协议取消事件可能来自不同队列。
        func waitForHeldStop() async {
            guard !heldRequestWasStopped else { return }
            await withCheckedContinuation { heldStop = $0 }
        }

        /// 请求失败或操作提前结束时唤醒等待者，避免错误编码被挂起掩盖。
        func operationFinished() {
            finished = true; entered?.resume(returning: false); entered = nil
        }

        /// 返回是否已进入实际HTTP门；没有睡眠来猜测Task调度。
        func waitForHeld() async -> Bool {
            if gate != nil {
                return true
            }
            if finished {
                return false
            }
            return await withCheckedContinuation { entered = $0 }
        }

        /// 释放唯一旧响应；测试随后必须等真实响应器与调用Task都退出。
        func release() {
            gate?.resume(); gate = nil
        }

        /// 确保迟到响应器已经返回，不能只等被取消的URLSession Task就宣称旧响应被处理。
        func waitForResponderExit() async {
            guard !didReturn else { return }
            await withCheckedContinuation { responderExit = $0 }
        }

        /// 无论断言/取消是否成功都释放门闩与等待者；仅影响本测试actor。
        func stop() {
            operationFinished(); release(); responderExit?.resume(); responderExit = nil
            heldStop?.resume(); heldStop = nil
        }
    }

    /// 配置专用URLProtocol拦截全部请求；注册host以Mutex保护，不替换全局URLSession或访问真实网络。
    private final nonisolated class RandomBrowsingProtocol: URLProtocol, @unchecked Sendable {
        private static let fixtures = Mutex<[String: RandomBrowsingHTTP]>([:])
        private let state = Mutex<(stopped: Bool, task: Task<Void, Never>?, fixture: RandomBrowsingHTTP?, requestID: UUID?)>((false, nil, nil, nil))

        /// host仅属于本测试，fixture为有限脚本；并行测试不共享响应序列。
        static func install(_ fixture: RandomBrowsingHTTP, host: String) {
            fixtures.withLock { $0[host] = fixture }
        }

        /// 只移除当前测试host，其他会话不受影响。
        static func remove(host: String) {
            _ = fixtures.withLock { $0.removeValue(forKey: host) }
        }

        /// 配置会话的任何意外host也要拦截并失败，不允许socket回源。
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        /// 保留原始SDK请求供独立字节断言，不重写路径/JSON/身份。
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        /// 捕获Sendable快照后异步取得HTTP响应；真实stop或Task取消后禁止任何迟到成功/失败回调。
        override func startLoading() {
            do {
                let captured = try RandomBrowsingRequest(request)
                let fixture = try #require(Self.fixtures.withLock { $0[captured.url.host ?? ""] })
                // gate可能在Task创建后立刻进入；先登记身份，stopLoading即使抢先调度也能归属到旧请求。
                state.withLock { $0.fixture = fixture; $0.requestID = captured.id }
                let task = Task { @Sendable [weak self, captured, fixture] in
                    do {
                        let reply = try await fixture.response(captured)
                        guard let self, !Task.isCancelled, !self.state.withLock({ $0.stopped }) else { return }
                        let response = try #require(HTTPURLResponse(url: captured.url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
                        client?.urlProtocolDidFinishLoading(self)
                    } catch {
                        guard let self, !Task.isCancelled, !self.state.withLock({ $0.stopped }) else { return }
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
                state.withLock {
                    $0.task = task; if $0.stopped {
                        task.cancel()
                    }
                }
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        /// URLSession实际取消下层任务；不在锁中await，响应器gate仍由测试精确释放。
        override func stopLoading() {
            let context = state.withLock { value in value.stopped = true; value.task?.cancel(); return (value.fixture, value.requestID) }
            if let fixture = context.0, let id = context.1 {
                Task { await fixture.stopped(id) }
            }
        }
    }
#endif
