import Foundation
import ImmichAPI
import Testing
@testable import Remmich

/// 真实服务器证据必须满足完整性；本页投影不得改写照片、日期或官方stack，也不向canonical Index写入。
@Suite("Scene stack validation and projection")
struct SceneStackValidationTests {
    /// 封面/成员/UUID/范围/组身份任何不可信都拒绝整个响应，不隐藏一部分照片。
    @Test(arguments: ["id", "cover", "missing-cover", "foreign", "duplicate", "overlap", "group-id", "single"])
    func rejectsMalformedGroups(_ mode: String) {
        var groups = [sceneGroup([sceneA, sceneB])]
        switch mode {
        case "id": groups = [.init(id: "", coverID: sceneA, memberIDs: [sceneA, sceneB])]
        case "cover": groups = [.init(id: sceneGroupID, coverID: "invalid", memberIDs: [sceneA, sceneB])]
        case "missing-cover": groups = [.init(id: sceneGroupID, coverID: sceneC, memberIDs: [sceneA, sceneB])]
        case "foreign": groups = [sceneGroup([sceneA, sceneD])]
        case "duplicate": groups = [sceneGroup([sceneA, sceneA])]
        case "overlap": groups += [.init(id: sceneOtherGroupID, coverID: sceneB, memberIDs: [sceneB, sceneC])]
        case "group-id": groups += [.init(id: sceneGroupID, coverID: sceneC, memberIDs: [sceneC, sceneD])]
        default: groups = [sceneGroup([sceneA])]
        }
        let requested = mode == "group-id" ? [sceneA, sceneB, sceneC, sceneD] : [sceneA, sceneB, sceneC]
        #expect(throws: SceneStackError.invalidGroups) { _ = try SceneStackValidator.validate(groups, assetIDs: requested) }
    }

    /// groupID只是区分大小写的不透明展示键，不能强制当asset UUID或路径。
    @Test func retainsOpaqueGroupIdentity() throws {
        let value = SceneStackGroup(id: "scene:v2/AbC", coverID: sceneA, memberIDs: [sceneA, sceneB])
        let result = try SceneStackValidator.validate([value], assetIDs: [sceneA, sceneB])
        #expect(result.first?.id == "scene:v2/AbC")
    }

    /// 展开成员紧跟封面、保留原桶顺序与日期/原生stack；关闭分组完整恢复原顺序，不改摘要。
    @Test func projectionRetainsOriginalDataAndCanFullyUnfold() throws {
        let originals = [sceneAsset(sceneC), sceneAsset(sceneD), sceneAsset(sceneA, stacked: true), sceneAsset(sceneB)]
        let group = sceneGroup([sceneB, sceneA, sceneC])
        let valid = try SceneStackValidator.validate([group], assetIDs: originals.map(\.id))
        let collapsed = SceneStackValidator.project(assets: originals, groups: valid, expanded: [])
        #expect(collapsed.map(\.id) == [sceneD, sceneA])
        let expanded = SceneStackValidator.project(assets: originals, groups: valid, expanded: [sceneGroupID])
        #expect(expanded.map(\.id) == [sceneD, sceneA, sceneC, sceneB])
        #expect(expanded.first { $0.id == sceneA }?.asset.stack == originals[2].stack)
        #expect(Set(expanded.map(\.asset)) == Set(originals))
        #expect(SceneStackValidator.project(assets: originals, groups: [], expanded: []).map(\.asset) == originals)
    }
}

/// 实际Store读取/失败/代际路径，网络字节在下方repo测试与独立SDK测试中验证。
@Suite("Scene stack library state")
@MainActor struct SceneStackLibraryStoreTests {
    /// 分组HTTP错误不能丢失刚读完的任何原照片；错误与空成功分开。
    @Test func groupingFailureKeepsAllOriginalPhotos() async {
        let originals = [sceneAsset(sceneA), sceneAsset(sceneB)]
        let reader = SceneStateReader(batches: [originals], outcomes: [.failure(.network)])
        let store = SceneStackLibraryStore()
        await store.reload(reader: reader)
        #expect(store.assets == originals && store.error != nil && !store.busy)
        #expect(store.tiles(groupingEnabled: true).map(\.asset) == originals)
    }

    /// 不支持、不可用和合法无组成功均保持照片，但各自状态可供界面明确解释。
    @Test(arguments: ["unsupported", "unavailable", "empty"])
    func keepsAvailabilityStatesDistinct(_ mode: String) async {
        let result: SceneStackAvailability = switch mode { case "unsupported": .unsupported; case "unavailable": .unavailable; default: .available([]) }
        let reader = SceneStateReader(batches: [[sceneAsset(sceneA)]], outcomes: [.success(result)])
        let store = SceneStackLibraryStore()
        await store.reload(reader: reader)
        #expect(store.error == nil && store.assets.count == 1)
        switch (mode, store.availability) {
        case ("unsupported", .unsupported?), ("unavailable", .unavailable?), ("empty", .available?): break
        default: Issue.record("Availability states must remain distinct")
        }
    }

    /// 空月不查询分组，不根据空ids探针宣称已ready。
    @Test func emptyMonthDoesNotProbeAvailability() async {
        let reader = SceneStateReader(batches: [[]], outcomes: [])
        let store = SceneStackLibraryStore()
        await store.reload(reader: reader)
        #expect(await reader.groupCount == 0)
        if case .notRequested? = store.availability {} else {
            Issue.record("Empty month remains unqueried")
        }
    }

    /// 即使来源返回坏组，Store仍在发布前校验，不能把没有封面的组变成隐藏权。
    @Test func malformedGroupFallsBackToFullSource() async {
        let reader = SceneStateReader(batches: [[sceneAsset(sceneA), sceneAsset(sceneB)]], outcomes: [.success(.available([.init(id: sceneGroupID, coverID: sceneC, memberIDs: [sceneA, sceneB])]))])
        let store = SceneStackLibraryStore()
        await store.reload(reader: reader)
        #expect(store.error != nil && store.tiles(groupingEnabled: true).map(\.id) == [sceneA, sceneB])
    }

    /// facade建立失败立即撤销旧在途分组发布权；不等待旧网络结束才解锁Reload，也不丢原片。
    @Test func readerFailureUnlocksAndRejectsPendingEvidence() async {
        let reader = SceneStateReader(batches: [[sceneAsset(sceneA), sceneAsset(sceneB)]],
                                      outcomes: [.success(.available([sceneGroup([sceneA, sceneB])]))], holdFirstGroup: true)
        let store = SceneStackLibraryStore()
        let pending = Task { await store.reload(reader: reader); await reader.finished() }
        guard await reader.waitForGate() else { await pending.value; Issue.record("Grouping must enter gate"); return }
        store.readerUnavailable()
        #expect(!store.busy && store.error != nil)
        await reader.release()
        await pending.value
        #expect(store.tiles(groupingEnabled: true).map(\.id) == [sceneA, sceneB] && store.error != nil)
    }

    /// 管理变更与新facade到达之间也不得发布旧组；真实在途读取退休后仍保留完整旧月供浏览。
    @Test func managementChangeRetiresEvidenceBeforeFreshReaderArrives() async {
        let originals = [sceneAsset(sceneA), sceneAsset(sceneB)]
        let reader = SceneStateReader(batches: [originals, originals],
                                      outcomes: [.success(.available([sceneGroup([sceneA, sceneB])])), .success(.available([]))], holdFirstGroup: true)
        let store = SceneStackLibraryStore()
        let pending = Task { await store.reload(reader: reader); await reader.finished() }
        guard await reader.waitForGate() else { await pending.value; Issue.record("Grouping must enter gate"); return }
        // 尚未创建或发起新Reload，明确复现同步管理通知与异步facade工厂之间的窗口。
        store.retireEvidence()
        #expect(!store.busy && store.availability == nil && store.assets == originals)
        await reader.release(); await pending.value
        #expect(store.availability == nil && store.error == nil && !store.busy)
        #expect(store.tiles(groupingEnabled: true).map(\.asset) == originals)
        #expect(await reader.groupCount == 1)
        await store.reload(reader: reader)
        #expect(store.availability?.groups.isEmpty == true && store.error == nil && !store.busy)
        #expect(await reader.groupCount == 2)
    }

    /// 旧组请求在途，新账号成功后旧有效组最后返回也不能隐藏新账号照片。
    @Test func rejectsLateGroupingAfterInvalidation() async {
        let reader = SceneStateReader(batches: [[sceneAsset(sceneA), sceneAsset(sceneB)], [sceneAsset(sceneC)]],
                                      outcomes: [.success(.available([sceneGroup([sceneA, sceneB])])), .success(.available([]))], holdFirstGroup: true)
        let store = SceneStackLibraryStore()
        let pending = Task { await store.reload(reader: reader); await reader.finished() }
        guard await reader.waitForGate() else { await pending.value; Issue.record("Grouping must enter gate"); return }
        store.invalidate()
        await store.reload(reader: reader)
        await reader.release()
        await pending.value
        #expect(store.assets.map(\.id) == [sceneC] && store.tiles(groupingEnabled: true).map(\.id) == [sceneC])
    }
}

/// 实际repo/facade/SDK/认证/JSON/HTTP状态与请求计数，使用有限原始HTTP字节而非替换业务实现。
@Suite("Scene stack repository HTTP contracts")
struct SceneStackRepositoryTests {
    /// 主Photos可含共享/视频原片；仅本人timeline IMAGE进入真实POST，其他原摘要仍归主catalog所有。
    @Test func mainTimelineQueriesOnlyEligibleOwnPhotosAndKeepsOriginals() async throws {
        let fixture = SceneHTTPFixture(replies: [.init()])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        let originals = [sceneAsset(sceneA), sceneAsset(sceneB, owner: sceneD), sceneAsset(sceneC, kind: .video)]
        _ = try await reader.groupsForTimeline(originals)
        let requests = await fixture.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        #expect(body["ids"] == [sceneA])
        #expect(request.httpMethod == "POST" && request.url?.path == "/prefix/api/fork/scene-stacks/query")
        #expect(originals.map(\.id) == [sceneA, sceneB, sceneC])
        _ = try await reader.groupsForTimeline(Array(originals.dropFirst()))
        #expect(await fixture.requests.count == 1)
        await repo.clear()
    }

    /// 标准月份与完整桶都是fresh GET，过滤视频只发生在本页，之后严格POST201且保留原生stack。
    @Test func readsFreshMonthsAndCompletePhotosBeforeQuery() async throws {
        let fixture = try SceneHTTPFixture(replies: [.init(status: 200, json: #"[{"timeBucket":"2026-11-01","count":3}]"#),
                                                     .init(status: 200, json: sceneBucketJSON()), .init()])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        let months = try await reader.months()
        #expect(months.first?.assetCount == 3)
        let photos = try await reader.assets(in: sceneMonth)
        #expect(photos.map(\.id) == [sceneA, sceneC] && photos.first?.stack?.assetCount == 2)
        _ = try await reader.groups(for: photos)
        let requests = await fixture.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic" })
        for request in requests.prefix(2) {
            let items = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains { $0.name == "withPartners" && $0.value == "false" })
            #expect(items.contains { $0.name == "withStacked" && $0.value == "true" })
        }
        await repo.clear()
    }

    /// 5001张真实摘要按5000+1发请求；跨块组没有返回时完整保留，不猜测拼接半组。
    @Test func chunksWithoutInventingCrossChunkGroups() async throws {
        let fixture = SceneHTTPFixture(replies: [.init(), .init()])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        let originals = (0 ..< 5001).map { sceneAsset(sceneGeneratedID($0)) }
        let result = try await reader.groups(for: originals)
        if case let .available(groups) = result {
            #expect(groups.isEmpty)
        } else {
            Issue.record("Successful chunks should be available")
        }
        let requests = await fixture.requests
        var counts: [Int] = []
        for request in requests {
            let body = try #require(request.httpBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: [String]]
            try counts.append(#require(json?["ids"]).count)
        }
        #expect(counts == [5000, 1])
        await repo.clear()
    }

    /// 只有404/405/501表示未提供扩展，403/503及错误成功码必须抛失败，不假装无组。
    @Test(arguments: [404, 405, 501, 403, 503, 200])
    func differentiatesUnsupportedFromHttpFailure(_ status: Int) async throws {
        let fixture = SceneHTTPFixture(replies: [.init(status: status)])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        do {
            let result = try await reader.groups(for: [sceneAsset(sceneA)])
            #expect([404, 405, 501].contains(status))
            if case .unsupported = result {} else {
                Issue.record("Unsupported must remain explicit")
            }
        } catch { #expect(![404, 405, 501].contains(status)) }
        #expect(await fixture.requests.count == 1)
        await repo.clear()
    }

    /// 任一后续chunk失败时，已收到的第一组不能作为部分成功返回给隐藏投影。
    @Test func failsTheWholeGroupingWhenALaterChunkFails() async throws {
        let firstIDs = [sceneGeneratedID(0), sceneGeneratedID(1)]
        let first = #"{"available":true,"groups":[{"id":"\#(sceneGroupID)","coverId":"\#(firstIDs[0])","members":["\#(firstIDs[0])","\#(firstIDs[1])"]}]}"#
        let fixture = SceneHTTPFixture(replies: [.init(json: first), .init(status: 503)])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        do { _ = try await reader.groups(for: (0 ..< 5001).map { sceneAsset(sceneGeneratedID($0)) }); Issue.record("Partial groups must not return") }
        catch {}
        #expect(await fixture.requests.count == 2)
        await repo.clear()
    }

    /// 一块不可用/未部署即丢弃之前收到的组，不能保留部分折叠状态。
    @Test(arguments: ["unavailable", "unsupported"])
    func discardsEarlierGroupsWhenLaterChunkCannotProvideEvidence(_ mode: String) async throws {
        let firstIDs = [sceneGeneratedID(0), sceneGeneratedID(1)]
        let first = #"{"available":true,"groups":[{"id":"opaque-scene","coverId":"\#(firstIDs[0])","members":["\#(firstIDs[0])","\#(firstIDs[1])"]}]}"#
        let second = SceneHTTPReply(status: mode == "unsupported" ? 404 : 201, json: #"{"available":false,"groups":[]}"#)
        let fixture = SceneHTTPFixture(replies: [.init(json: first), second])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        let result = try await reader.groups(for: (0 ..< 5001).map { sceneAsset(sceneGeneratedID($0)) })
        #expect(result.groups.isEmpty)
        switch (mode, result) {
        case ("unavailable", .unavailable), ("unsupported", .unsupported): break
        default: Issue.record("Later unavailable chunk must discard all earlier groups")
        }
        #expect(await fixture.requests.count == 2)
        await repo.clear()
    }

    /// 服务端跨块返回半组也拒绝：只能使用当前请求完整范围，不能以全月ID集合绕过chunk边界。
    @Test func rejectsAGroupSpanningChunks() async throws {
        let first = sceneGeneratedID(0); let last = sceneGeneratedID(5000)
        let json = #"{"available":true,"groups":[{"id":"opaque-scene","coverId":"\#(first)","members":["\#(first)","\#(last)"]}]}"#
        let fixture = SceneHTTPFixture(replies: [.init(json: json)])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        await #expect(throws: SceneStackError.invalidGroups) {
            _ = try await reader.groups(for: (0 ..< 5001).map { sceneAsset(sceneGeneratedID($0)) })
        }
        #expect(await fixture.requests.count == 1)
        await repo.clear()
    }

    /// 原facade换号/端点/clear后所有读均在HTTP前失败，不能作为旧凭据clone继续读取。
    @Test(arguments: ["account", "route", "clear"])
    func oldFacadeCannotReadAgain(_ mode: String) async throws {
        let fixture = SceneHTTPFixture(replies: [])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        switch mode {
        case "account": await repo.configure(session: sceneSession(endpoint, user: sceneB), activeEndpoint: endpoint)
        case "route": await repo.updateRoute(sceneEndpoint())
        default: await repo.clear()
        }
        await #expect(throws: TimelineReadError.staleGeneration) { _ = try await reader.months() }
        await #expect(throws: TimelineReadError.staleGeneration) { _ = try await reader.assets(in: sceneMonth) }
        await #expect(throws: TimelineReadError.staleGeneration) { _ = try await reader.groups(for: []) }
        await #expect(throws: TimelineReadError.staleGeneration) { _ = try await reader.groupsForTimeline([]) }
        #expect(await fixture.requests.isEmpty)
        await repo.clear()
    }

    /// 第一块在途时按mode换号/换端点/clear，迟到201不得发第二块或发布旧组。
    @Test(arguments: ["account", "route", "clear"])
    func rejectsLateChunkBeforeStartingAnother(_ mode: String) async throws {
        let fixture = SceneHTTPFixture(replies: [.init(held: true)])
        let repo = sceneRepository(fixture)
        let endpoint = sceneEndpoint()
        await repo.configure(session: sceneSession(endpoint), activeEndpoint: endpoint)
        let reader = try await repo.sceneStackReader()
        let pending = Task {
            do { _ = try await reader.groups(for: (0 ..< 5001).map { sceneAsset(sceneGeneratedID($0)) }) }
            catch { await fixture.failGate(); throw error }
        }
        guard await fixture.waitForGate() else { try await pending.value; Issue.record("Scene HTTP must enter gate"); return }
        switch mode {
        case "account": await repo.configure(session: sceneSession(endpoint, user: sceneB), activeEndpoint: endpoint)
        case "route": await repo.updateRoute(sceneEndpoint())
        default: await repo.clear()
        }
        await fixture.release()
        await #expect(throws: TimelineReadError.staleGeneration) { try await pending.value }
        #expect(await fixture.requests.count == 1)
        await repo.clear()
    }
}

/// 所有ID是固定合成值；月份只用于公开SDK请求契约。
private nonisolated let sceneA = "11111111-1111-4111-8111-111111111111"
private nonisolated let sceneB = "22222222-2222-4222-8222-222222222222"
private nonisolated let sceneC = "33333333-3333-4333-8333-333333333333"
private nonisolated let sceneD = "44444444-4444-4444-8444-444444444444"
private nonisolated let sceneGroupID = "55555555-5555-4555-8555-555555555555"
private nonisolated let sceneOtherGroupID = "88888888-8888-4888-8888-888888888888"
private nonisolated let sceneUser = "66666666-6666-4666-8666-666666666666"
private nonisolated let sceneMonth = TimelineBucketID(rawValue: "2026-11-01")

/// ids完整描述组，封面固定为A；无任何真实相似度或照片数据。
private nonisolated func sceneGroup(_ ids: [String]) -> SceneStackGroup {
    .init(id: sceneGroupID, coverID: sceneA, memberIDs: ids)
}

/// id为合成UUID，stacked验证原生stack保留；owner/kind覆盖主Photos混合伙伴/视频范围。
private nonisolated func sceneAsset(_ id: String, stacked: Bool = false, owner: String = sceneUser, kind: TimelineMediaKind = .image) -> TimelineAssetSummary {
    .init(id: id, ownerID: owner, capturedAt: .distantPast, uploadedAt: .distantPast,
          localOffsetHours: 5.5, mediaKind: kind, durationMilliseconds: nil, aspectRatio: 1.5,
          isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
          stack: stacked ? .init(id: sceneOtherGroupID, assetCount: 2) : nil,
          projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
}

/// index产生唯一合法UUID，不使用随机时间或重复值来绕过5000分块断言。
private nonisolated func sceneGeneratedID(_ index: Int) -> String {
    let suffix = String(index + 1, radix: 16)
    return "77777777-7777-4777-8777-" + String(repeating: "0", count: 12 - suffix.count) + suffix
}

/// 每次工厂独占host，API前缀必须原样穿过中间件。
private nonisolated func sceneEndpoint() -> URL {
    URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/prefix/api")!
}

/// endpoint/user为合成身份，真实repo仍执行配置/代际控制。
private nonisolated func sceneSession(_ endpoint: URL, user: String = sceneUser) -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic", userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 仅注入真实HTTP字节来源，所有SDK路径/认证/序列化/状态及仓库逻辑照常执行。
private nonisolated func sceneRepository(_ fixture: SceneHTTPFixture) -> ImmichTimelineRepository {
    ImmichTimelineRepository(readLoader: { request, operation in
        #expect(operation == "getTimeBuckets" || operation == "getTimeBucket")
        return try await fixture.response(request)
    }, sceneStackLoader: { request, operation in
        #expect(operation == "forkSceneStacksQuery")
        return try await fixture.response(request)
    })
}

/// 对齐所有标准SDK桶列，含IMAGE/VIDEO/IMAGE与第一张的官方stack，而非简化掉未知字段。
private nonisolated func sceneBucketJSON() throws -> String {
    let null = NSNull()
    let json: [String: Any] = ["id": [sceneA, sceneB, sceneC], "ownerId": [sceneUser, sceneUser, sceneUser],
                               "createdAt": Array(repeating: "2026-11-24T00:00:01.000", count: 3),
                               "fileCreatedAt": Array(repeating: "2026-11-01T00:00:00.000", count: 3),
                               "duration": [null, null, null], "isFavorite": [false, false, false], "isImage": [true, false, true],
                               "isTrashed": [false, false, false], "livePhotoVideoId": [null, null, null],
                               "localOffsetHours": [0, 0, 0], "projectionType": [null, null, null], "ratio": [1.5, 1.5, 1.5],
                               "thumbhash": [null, null, null], "visibility": ["timeline", "timeline", "timeline"],
                               "stack": [[sceneOtherGroupID, "2"], null, null] as [Any]]
    return try String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)
}

/// Store有限失败标记，不冒充服务器HTTP状态。
private nonisolated enum SceneStateFailure: Error { case network }
/// Store状态测试只控制列表/原照/组结果与挂起时序，HTTP另由真实SDK测试负责。
private actor SceneStateReader: SceneStackReading {
    private var batches: [[TimelineAssetSummary]]
    private var outcomes: [Result<SceneStackAvailability, SceneStateFailure>]
    private let holdFirstGroup: Bool
    private(set) var groupCount = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false
    /// batches/outcomes按调用消费，holdFirstGroup在真实Store已读取原片后挂起证据结果。
    init(batches: [[TimelineAssetSummary]], outcomes: [Result<SceneStackAvailability, SceneStateFailure>], holdFirstGroup: Bool = false) {
        self.batches = batches; self.outcomes = outcomes; self.holdFirstGroup = holdFirstGroup
    }

    /// 返回唯一真实测试月份，列表没有虚假cursor。
    func months() async throws -> [TimelineBucketSummary] {
        [.init(id: sceneMonth, assetCount: 2)]
    }

    /// 每次读取消耗完整照片快照；缺脚本直接失败，不循环复用旧结果。
    func assets(in _: TimelineBucketID) async throws -> [TimelineAssetSummary] {
        guard !batches.isEmpty else { throw SceneStateFailure.network }
        return batches.removeFirst()
    }

    /// 先取本次结果再挂起，允许新上下文先读取下一结果，避免gate掩盖错误的消费顺序。
    func groups(for _: [TimelineAssetSummary]) async throws -> SceneStackAvailability {
        groupCount += 1
        guard !outcomes.isEmpty else { throw SceneStateFailure.network }
        let result = outcomes.removeFirst()
        if holdFirstGroup, groupCount == 1 {
            await withCheckedContinuation { pending = $0; waiter?.resume(returning: true); waiter = nil }
        }
        return try result.get()
    }

    /// 测试等待实际分组调用已在途，不用sleep推测。
    func waitForGate() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 若Store在gate前因真实错误结束，也唤醒测试；不以无限等待掩盖错误路径。
    func finished() {
        failed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 新状态成功后释放旧结果，由Store代际守卫拒绝。
    func release() {
        pending?.resume(); pending = nil
    }
}

/// 原始HTTP字节，可挂起真实SDK请求，但不替换业务返回值。
private nonisolated struct SceneHTTPReply: Sendable {
    var status = 201
    var json = #"{"available":true,"groups":[]}"#
    var held = false
}

/// 保存实际URLRequest并按序返回原始响应；缺脚本失败，gate可证明没有继续发下一块。
private actor SceneHTTPFixture {
    private var replies: [SceneHTTPReply]
    private(set) var requests: [URLRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false
    /// replies是有限HTTP脚本，GET/POST都消费一次，不能用本地缓存伪造fresh。
    init(replies: [SceneHTTPReply]) {
        self.replies = replies
    }

    /// request保留真实头/方法/查询/正文；返回独立状态/字节并可在边界处挂起。
    func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { failGate(); throw URLError(.badServerResponse) }
        let value = replies.removeFirst()
        if value.held {
            await withCheckedContinuation { pending = $0; waiter?.resume(returning: true); waiter = nil }
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: value.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(value.json.utf8), response)
    }

    /// 若真正请求/解码先失败仍唤醒等待者，不能以无限等待掩盖问题。
    func failGate() {
        failed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// true表示请求已到达gate，false要求测试检查原操作错误。
    func waitForGate() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 在换号后放回旧201，原repo负责拒绝发布并阻止第二个请求。
    func release() {
        pending?.resume(); pending = nil
    }
}
