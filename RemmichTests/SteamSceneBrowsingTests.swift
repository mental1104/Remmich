#if DEBUG
    import Foundation
    import Synchronization
    import Testing
    @testable import Remmich

    /// 实际Steam Store→原搜索Store→repo→SDK/URLSession与Scene facade；全部媒体、身份与响应均合成。
    @Suite("Steam scene browsing HTTP")
    @MainActor struct SteamSceneBrowsingTests {
        /// 跨页缺成员时不折叠，下一页凑齐后才采用后端完整组；伙伴/原生stack/日期和Viewer原始集合均保留。
        @Test func loadsRealSteamPagesAndFreezesAllOriginalViewerMembers() async throws {
            let fixture = await SteamSceneHTTPFixture([
                steamExchange("search/metadata", steamPage([steamPhoto(steamA, date: "2026-11-03", stacked: true), steamPhoto(steamD, owner: steamOther, date: "2026-11-02")], cursor: "opaque/+next=")),
                steamExchange("fork/scene-stacks/query", steamGroups([]), status: 201),
                steamExchange("search/metadata", steamPage([steamPhoto(steamB), steamPhoto(steamC), steamPhoto(steamA, date: "2026-11-03", stacked: true)])),
                steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201),
                steamExchange("search/metadata", steamPage([])),
            ]); defer { fixture.close() }
            let store = SteamSceneStore()
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.hasLoaded && store.hasMore && store.assets.map(\.id) == [steamA, steamD])
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamD])
            await store.loadMore(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(!store.hasMore && store.error == nil && store.assets.map(\.id) == [steamA, steamD, steamB, steamC])
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamD, steamC])
            #expect(store.assets.first?.stack?.id == steamNativeStack)
            #expect(store.assets.first?.stack?.assetCount == 2)
            store.toggle(steamGroup)
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamB, steamD, steamC])
            #expect(store.tiles(groupingEnabled: false).map(\.id) == [steamA, steamD, steamB, steamC])
            let selection = try #require(SteamSceneSelection(assetID: steamB, assets: store.assets))
            let originals = store.assets
            #expect(selection.route.initialAssets == originals)
            let viewer = AssetViewerSession(route: selection.route, bucketIDs: selection.timeline.bucketSummaries.map(\.id),
                                            loadBucket: { await selection.timeline.rangeCoverAssets(in: $0) })
            await viewer.start()
            #expect(Set(viewer.assets.map(\.id)) == Set(originals.map(\.id)) && viewer.selectedAssetID == steamB)
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.hasLoaded && store.assets.isEmpty && store.error == nil)
            await viewer.select(steamA)
            #expect(viewer.selectedAssetID == steamA && Set(viewer.assets.map(\.id)) == Set(originals.map(\.id)))
            #expect(viewer.assets.allSatisfy { asset in originals.contains { $0.id == asset.id && $0.capturedAt == asset.capturedAt && $0.stack == asset.stack } })
            let requests = await fixture.script.requests()
            #expect(requests.count == 5)
            try fixture.assertSearch(requests[0]); try fixture.assertSearch(requests[2], cursor: "opaque/+next="); try fixture.assertSearch(requests[4])
            try fixture.assertScene(requests[1], ids: [steamA]); try fixture.assertScene(requests[3], ids: [steamA, steamB, steamC])
        }

        /// 空首屏仍带原始cursor时允许真实续页；最终空列表不探测空Scene请求，也不自动发下一页。
        @Test(arguments: [false, true])
        func distinguishesConfirmedEmptyFromAnEmptyContinuationPage(_ continues: Bool) async throws {
            var replies = [steamExchange("search/metadata", steamPage([], cursor: continues ? "next" : nil))]
            if continues {
                replies += [steamExchange("search/metadata", steamPage([steamPhoto(steamA), steamPhoto(steamB)])),
                            steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201)]
            }
            let fixture = await SteamSceneHTTPFixture(replies); defer { fixture.close() }
            let store = SteamSceneStore()
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.assets.isEmpty && store.hasLoaded && store.error == nil && store.hasMore == continues)
            #expect(await fixture.script.requests().count == 1)
            if continues {
                await store.loadMore(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
                #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA] && !store.hasMore)
                let requests = await fixture.script.requests()
                #expect(requests.count == 3); try fixture.assertSearch(requests[1], cursor: "next")
            }
        }

        /// 明确扩展缺失/未就绪与HTTP/坏成员不同；所有情况保留真实搜索照片，不切掉组的筛选外成员。
        @Test(arguments: ["404", "unavailable", "403", "503", "excluded-member", "bad-cover"])
        func failedOrIncompleteSceneEvidenceNeverHidesScreenshots(_ kind: String) async {
            let status = Int(kind) ?? 201
            let group = kind == "excluded-member" ? [steamA, steamC] : [steamA, steamB]
            let reply = kind == "unavailable" ? #"{"available":false,"groups":[]}"#
                : steamGroups([group], cover: kind == "bad-cover" ? steamC : steamA)
            let fixture = await SteamSceneHTTPFixture([
                steamExchange("search/metadata", steamPage([steamPhoto(steamA), steamPhoto(steamB)])),
                steamExchange("fork/scene-stacks/query", reply, status: status),
            ]); defer { fixture.close() }
            let store = SteamSceneStore()
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.hasLoaded && store.assets.map(\.id) == [steamA, steamB] && !store.busy)
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamB])
            if kind == "404" {
                guard case .unsupported? = store.availability else { Issue.record("Missing extension must stay unsupported"); return }
                #expect(store.error == nil)
            } else if kind == "unavailable" {
                guard case .unavailable? = store.availability else { Issue.record("Unavailable evidence must remain distinct"); return }
                #expect(store.error == nil)
            } else {
                #expect(store.error != nil && store.availability == nil)
            }
            #expect(await fixture.script.requests().count == 2)
        }

        /// 续页失败不消耗游标，先撤销旧折叠；用户明确重试后查询累计集合，不重放未知写入或隐藏原片。
        @Test func retriesTheSameRealCursorAndRetiresOldFoldEvidence() async throws {
            let fixture = await SteamSceneHTTPFixture([
                steamExchange("search/metadata", steamPage([steamPhoto(steamA), steamPhoto(steamB)], cursor: "same-next")),
                steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201),
                steamExchange("search/metadata", "{}", status: 503),
                steamExchange("search/metadata", steamPage([steamPhoto(steamC)])),
                steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201),
            ]); defer { fixture.close() }
            let store = SteamSceneStore()
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.tiles(groupingEnabled: true).count == 1)
            await store.loadMore(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.error != nil && store.hasMore && store.assets.map(\.id) == [steamA, steamB])
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamB])
            await store.loadMore(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(store.error == nil && !store.hasMore && store.assets.map(\.id) == [steamA, steamB, steamC])
            #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamA, steamC])
            let requests = await fixture.script.requests(); #expect(requests.count == 5)
            try fixture.assertSearch(requests[2], cursor: "same-next"); try fixture.assertSearch(requests[3], cursor: "same-next")
        }

        /// 实际metadata或Scene请求挂起后取消/换号/换端点；旧响应退场后仍不能发布旧照片/分组或发新请求。
        @Test(.timeLimit(.minutes(1)), arguments: ["search", "scene"], ["cancel", "account", "route"])
        func retiresActualInflightHTTPAtBothStages(_ stage: String, _ reason: String) async throws {
            var replies = [steamExchange("search/metadata", steamPage([steamPhoto(steamA), steamPhoto(steamB)]), held: stage == "search")]
            if stage == "scene" {
                replies.append(steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201, held: true))
            }
            let fixture = await SteamSceneHTTPFixture(replies); defer { fixture.close() }
            let store = SteamSceneStore()
            let old = Task {
                await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
                await fixture.script.operationFinished()
            }
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld(), "Actual old HTTP must reach the held response")
                if reason == "cancel" {
                    store.cancelLoading()
                } else {
                    let account = steamSession(fixture.endpoint, user: reason == "account" ? steamOther : steamOwner)
                    await fixture.repository.configure(session: account, activeEndpoint: reason == "route" ? fixture.endpoint.appending(path: "new-route") : fixture.endpoint)
                    store.invalidate()
                }
                await fixture.script.release(); await old.value; await fixture.script.waitForHeldResponderExit()
                #expect(!store.busy && store.error == nil && store.availability == nil)
                let expected = reason == "cancel" && stage == "scene" ? [steamA, steamB] : []
                #expect(store.assets.map(\.id) == expected)
                #expect(store.requiresReload == (reason == "cancel"))
                #expect(await fixture.script.requests().count == (stage == "search" ? 1 : 2))
            } onCancel: { old.cancel(); Task { await fixture.script.stop() } }
            await fixture.script.stop()
        }

        /// 新Reload取消真实旧请求；不合作旧成功退场时，不能覆盖已经确认的新照片与空组。
        @Test(.timeLimit(.minutes(1)), arguments: ["search", "scene"])
        func replacementOwnsBothSearchAndScenePublication(_ stage: String) async throws {
            var replies = [steamExchange("search/metadata", steamPage([steamPhoto(steamA), steamPhoto(steamB)]), held: stage == "search")]
            if stage == "scene" {
                replies.append(steamExchange("fork/scene-stacks/query", steamGroups([[steamA, steamB]]), status: 201, held: true))
            }
            replies += [steamExchange("search/metadata", steamPage([steamPhoto(steamC)])),
                        steamExchange("fork/scene-stacks/query", steamGroups([]), status: 201)]
            let fixture = await SteamSceneHTTPFixture(replies); defer { fixture.close() }
            let store = SteamSceneStore()
            let old = Task { await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner); await fixture.script.operationFinished() }
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld(), "Old read must enter actual HTTP before Reload")
                await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
                #expect(store.assets.map(\.id) == [steamC] && store.hasLoaded && !store.busy)
                await fixture.script.release(); await old.value; await fixture.script.waitForHeldResponderExit()
                #expect(store.assets.map(\.id) == [steamC] && store.error == nil && !store.busy)
                #expect(store.tiles(groupingEnabled: true).map(\.id) == [steamC])
                #expect(await fixture.script.requests().count == (stage == "search" ? 3 : 4))
            } onCancel: { old.cancel(); Task { await fixture.script.stop() } }
            await fixture.script.stop()
        }

        /// 服务器拒绝实际Steam筛选时保持可见失败，不回落为全部照片、空成功或客户端尺寸/GPU计算。
        @Test func doesNotFallbackWhenTheRealSteamFilterIsRejected() async {
            let fixture = await SteamSceneHTTPFixture([steamExchange("search/metadata", "{}", status: 400)]); defer { fixture.close() }
            let store = SteamSceneStore()
            await store.reload(source: fixture.repository, scenes: fixture.repository, ownerID: steamOwner)
            #expect(!store.hasLoaded && store.assets.isEmpty && store.error != nil && store.requiresReload)
            #expect(await fixture.script.requests().count == 1)
        }
    }

    private nonisolated let steamOwner = "11111111-1111-4111-8111-111111111111"
    private nonisolated let steamOther = "22222222-2222-4222-8222-222222222222"
    private nonisolated let steamA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private nonisolated let steamB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private nonisolated let steamC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private nonisolated let steamD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private nonisolated let steamNativeStack = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private nonisolated let steamGroup = "Steam:opaque/Case-Sensitive"

    /// endpoint/user均合成；令牌只用于独占URLProtocol预期，不读取持久会话或Keychain。
    private nonisolated func steamSession(_ endpoint: URL, user: String = steamOwner) -> AccountSession {
        .init(apiURL: endpoint, accessToken: "checksum-owner", userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
              serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
    }

    /// id/owner/date决定独立官方资产JSON与真实拍摄日；stacked只提供完整原生stack DTO，不转换Scene关系。
    private nonisolated func steamPhoto(_ id: String, owner: String = steamOwner, date: String = "2026-11-01", stacked: Bool = false) -> String {
        let stack = stacked ? #", "stack":{"id":"\#(steamNativeStack)","primaryAssetId":"\#(id)","assetCount":2}"# : ""
        return #"{"id":"\#(id)","originalPath":"/synthetic/steam.jpg","checksum":"synthetic","createdAt":"2026-11-01T00:00:00Z","duration":null,"width":2560,"height":1440,"thumbhash":null,"fileCreatedAt":"\#(date)T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"isTrashed":false,"localDateTime":"\#(date)T00:00:00Z","originalFileName":"synthetic.jpg","ownerId":"\#(owner)","type":"IMAGE","updatedAt":"2026-11-01T00:00:00Z","visibility":"timeline"\#(stack)}"#
    }

    /// values为原始独立资产JSON，cursor原样写入响应；没有伪造总数或自动分页行为。
    private nonisolated func steamPage(_ values: [String], cursor: String? = nil) -> String {
        let token = cursor.map { #""\#($0)""# } ?? "null"
        return #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":\#(values.count),"items":[\#(values.joined(separator: ","))],"facets":[],"nextCursor":\#(token),"nextPage":null}}"#
    }

    /// groups是服务端完整成员数组，cover可故意无效供拒绝场景；不取客户端交集或计算分组。
    private nonisolated func steamGroups(_ groups: [[String]], cover: String = steamA) -> String {
        let json = groups.map { members in
            #"{"id":"\#(steamGroup)","coverId":"\#(cover)","members":[\#(members.map { #""\#($0)""# }.joined(separator: ","))]}"#
        }.joined(separator: ",")
        return #"{"available":true,"groups":[\#(json)]}"#
    }

    /// path/status/json/held是固定有限HTTP剧本；只允许公开读取POST，鉴权沿用合成测试身份。
    private nonisolated func steamExchange(_ path: String, _ json: String, status: Int = 200, held: Bool = false) -> ChecksumLookupExchange {
        .init(method: "POST", path: path, status: status, json: json, held: held)
    }

    /// 同一受限URLSession供真实metadata SDK与Scene loader；未知请求全部失败，绝不回落真实网络。
    @MainActor private final class SteamSceneHTTPFixture {
        let endpoint: URL
        let script: ChecksumLookupHTTPScript
        let repository: ImmichTimelineRepository
        private let network: URLSession

        /// exchanges为独立HTTP字节剧本；DEBUG hook逐字复用正式搜索候选，Release构造保持原样。
        init(_ exchanges: [ChecksumLookupExchange]) async {
            endpoint = URL(string: "https://steam-\(UUID().uuidString.lowercased()).invalid/proxy/api")!
            script = ChecksumLookupHTTPScript(exchanges)
            SteamSceneURLProtocol.install(script, endpoint: endpoint)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SteamSceneURLProtocol.self]; configuration.httpShouldSetCookies = false
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 10
            let network = URLSession(configuration: configuration, delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
            self.network = network
            repository = ImmichTimelineRepository(sceneStackLoader: { request, operation in
                guard operation == "forkSceneStacksQuery" else { throw URLError(.unsupportedURL) }
                let (data, response) = try await network.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, response)
            })
            await repository.configureSearchUITest(session: steamSession(endpoint), networkSession: network)
        }

        /// request是实际SDK请求，cursor必须完整保留；独立完整JSON断言禁止丢Steam分类/类型/原排序/可见性。
        func assertSearch(_ request: ChecksumLookupRequest, cursor: String? = nil) throws {
            #expect(request.url == endpoint.appending(path: "search/metadata") && request.method == "POST")
            let body = try #require(request.body)
            let actual = try JSONSerialization.jsonObject(with: body) as? NSDictionary
            let json = #"{"filter":{"isSteamScreenshot":{"eq":true},"type":{"eq":"IMAGE"},"visibility":{"eq":"timeline"},"trashedAt":{"eq":null}},"orderBy":{"direction":"desc","field":"fileCreatedAt"},"size":60,"withExif":true}"#
            let raw = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .mutableContainers)
            let expected = try #require(raw as? NSMutableDictionary)
            if let cursor {
                expected["cursor"] = cursor
            }
            #expect(actual == expected && actual != nil)
        }

        /// ids只包含累计已加载且本人可见的Steam结果，伙伴保留显示但不能送给本人的Scene证据接口。
        func assertScene(_ request: ChecksumLookupRequest, ids: [String]) throws {
            #expect(request.url == endpoint.appending(path: "fork/scene-stacks/query") && request.method == "POST")
            let body = try #require(request.body)
            let actual = try JSONSerialization.jsonObject(with: body) as? NSDictionary
            #expect(actual == ["ids": ids] as NSDictionary)
        }

        /// 结束只取消本例网络/HTTP门和host；不配置或查询退休后生成的默认客户端。
        func close() {
            network.invalidateAndCancel(); SteamSceneURLProtocol.remove(endpoint: endpoint)
            Task { await script.stop(); await repository.clear() }
        }
    }

    /// 复用既有实际HTTP剧本/门，仅新增会话内协议适配，不全局注册URLProtocol或改变共享fixture。
    private final nonisolated class SteamSceneURLProtocol: URLProtocol, @unchecked Sendable {
        /// 合成host对应的既有HTTP剧本与API根，跨Task只传Sendable引用和值。
        private struct Entry: Sendable { let script: ChecksumLookupHTTPScript; let endpoint: URL }
        /// 每请求停止标记与真实响应任务，Mutex保证stopLoading与任务安装交错时仍能取消。
        private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
        private static let scripts = Mutex<[String: Entry]>([:])
        private let loading = Mutex(Loading())

        /// script/endpoint仅登记随机合成host；其它所有host仍被拦截并明确失败。
        static func install(_ script: ChecksumLookupHTTPScript, endpoint: URL) {
            scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
        }

        /// 移除本例登记，不影响其他并发测试或默认网络。
        static func remove(endpoint: URL) {
            _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
        }

        /// 会话内接管全部请求，未知host不能访问socket。
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        /// 保留实际请求，不由夹具修复路径/认证/JSON。
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        /// 捕获实际Sendable字节后返回固定HTTP，取消后禁止成功回调；门退场使用真实请求ID。
        override func startLoading() {
            do {
                let captured = try ChecksumLookupRequest(request)
                guard let entry = Self.scripts.withLock({ $0[captured.url.host ?? ""] }) else { throw URLError(.badURL) }
                let task = Task { @Sendable [weak self, entry, captured] in
                    defer { Task { await entry.script.responderExited(captured.id) } }
                    do {
                        let exchange = try await entry.script.response(captured, endpoint: entry.endpoint)
                        guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                        let response = try #require(HTTPURLResponse(url: captured.url, statusCode: exchange.status, httpVersion: nil,
                                                                    headerFields: ["Content-Type": "application/json"]))
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: Data(exchange.json.utf8)); client?.urlProtocolDidFinishLoading(self)
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

        /// 真实URLSession取消只退休本请求；测试finally负责释放不合作响应门。
        override func stopLoading() {
            let task = loading.withLock { $0.stopped = true; return $0.task }; task?.cancel()
        }
    }
#endif
