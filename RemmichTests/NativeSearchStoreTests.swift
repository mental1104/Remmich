import Foundation
import Testing
@testable import Remmich

/// 只用合成媒体验证分页发布权、去重、失败恢复、失效清除及同账号查询交错。
@Suite("Native search state")
struct NativeSearchStoreTests {
    /// 安全的SDK错误保留状态区别，不把鉴权失败或非法条件伪装成空结果。
    @Test(arguments: [NativeSearchError.unauthorized, .forbidden, .invalidQuery, .unsupportedExtension])
    @MainActor func distinguishesAuthenticationPermissionAndRequestErrors(_ error: NativeSearchError) async {
        let store = NativeSearchStore()
        await store.search(.init(), source: ErrorSource(error: error))
        #expect(store.error == error.errorDescription)
        #expect(!store.hasSearched)
        #expect(store.assets.isEmpty)
    }

    /// 重复资源只保留首次顺序，失败页重试沿用原游标。
    @Test @MainActor func paginationRetainsCursorOnFailureAndDeduplicates() async {
        let source = PagedSource()
        let store = NativeSearchStore()
        await store.search(.init(), source: source)
        #expect(store.assets.map(\.id) == ["first"])
        #expect(store.continuation == .cursor("next"))
        await store.loadMore(source: source)
        #expect(store.error != nil)
        #expect(store.continuation == .cursor("next"))
        await store.loadMore(source: source)
        #expect(store.assets.map(\.id) == ["first", "second"])
        #expect(store.continuation == nil)
        #expect(store.error == nil)
    }

    /// 源不配合取消时，账户/查询失效也必须丢弃迟到响应。
    @Test @MainActor func invalidationRejectsLateResponse() async {
        let source = DelayedSource()
        let store = NativeSearchStore()
        let request = Task { await store.search(.init(), source: source) }
        await source.waitForRequest()
        store.invalidate()
        await source.complete()
        await request.value
        #expect(store.assets.isEmpty)
        #expect(!store.hasSearched)
        #expect(!store.isLoading)
    }

    /// task取消时，迟到的正常响应也不能变成搜索成功。
    @Test @MainActor func cancellationDoesNotPublishOrShowFailure() async {
        let source = DelayedSource()
        let store = NativeSearchStore()
        let request = Task { await store.search(.init(), source: source) }
        await source.waitForRequest()
        request.cancel()
        await source.complete()
        await request.value
        #expect(store.assets.isEmpty)
        #expect(store.error == nil)
        #expect(!store.isLoading)
    }

    /// 同一账号的A首屏确实在途后正常发起完整查询B；A有效响应最后返回，也不能覆盖B的媒体/游标/错误。
    @Test @MainActor func newQueryKeepsItsResultsWhenThePreviousFirstPageArrivesLast() async {
        let queries = raceQueries()
        let source = QueryRaceSource(first: queries.first, second: queries.second, delayNextPage: false)
        let store = NativeSearchStore()
        let first = Task { await store.search(queries.first, source: source) }
        await source.waitForDelayedRequest()
        #expect(store.isLoading && store.assets.isEmpty)

        // 使用正常search切换条件，不调用invalidate、取消A或伪造账户变化。
        await store.search(queries.second, source: source)
        #expect(store.assets.map(\.id) == ["query-b-first"])
        #expect(store.continuation == .forkCursor("b-next"))
        #expect(store.error == nil && store.hasSearched && !store.isLoading)
        await source.releaseDelayedResponse()
        await first.value
        #expect(store.assets.map(\.id) == ["query-b-first"])
        #expect(store.continuation == .forkCursor("b-next"))
        #expect(store.error == nil && store.hasSearched && !store.isLoading)

        // B继续分页仍须发送B的完整条件和Fork令牌，不能继承A的metadata位置。
        await store.loadMore(source: source)
        #expect(store.assets.map(\.id) == ["query-b-first", "query-b-second"])
        #expect(store.continuation == .forkCursor("b-final"))
        #expect(store.error == nil && !store.isLoading)
        #expect(await source.requestCount == 3)
    }

    /// A旧续页在途时B首屏完成；A的有效后页最后到达不能混入媒体、推进B游标或消耗B后页。
    @Test @MainActor func newQueryKeepsItsCursorWhenThePreviousContinuationArrivesLast() async {
        let queries = raceQueries()
        let source = QueryRaceSource(first: queries.first, second: queries.second, delayNextPage: true)
        let store = NativeSearchStore()
        await store.search(queries.first, source: source)
        #expect(store.assets.map(\.id) == ["query-a-first"])
        #expect(store.continuation == .cursor("a-next"))
        let continuation = Task { await store.loadMore(source: source) }
        await source.waitForDelayedRequest()
        #expect(store.isLoading)

        await store.search(queries.second, source: source)
        #expect(store.assets.map(\.id) == ["query-b-first"])
        #expect(store.continuation == .forkCursor("b-next"))
        #expect(store.error == nil && store.hasSearched && !store.isLoading)
        await source.releaseDelayedResponse()
        await continuation.value
        #expect(store.assets.map(\.id) == ["query-b-first"])
        #expect(store.continuation == .forkCursor("b-next"))
        #expect(store.error == nil && store.hasSearched && !store.isLoading)

        await store.loadMore(source: source)
        #expect(store.assets.map(\.id) == ["query-b-first", "query-b-second"])
        #expect(store.continuation == .forkCursor("b-final"))
        #expect(store.error == nil && !store.isLoading)
        #expect(await source.requestCount == 4)
    }
}

/// 返回同账号的两个不同完整条件：A为metadata，B改用参考图和Fork分页；过滤值均为合成数据。
private nonisolated func raceQueries() -> (first: NativeSearchQuery, second: NativeSearchQuery) {
    var first = NativeSearchQuery()
    first.text = "synthetic-alpha.jpg"
    first.media = .image
    first.city = "Synthetic Alpha"
    first.country = "Synthetic Country"
    first.personIDs = ["11111111-1111-4111-8111-111111111111"]
    first.tags = .untagged
    first.deviceModels = ["Synthetic Camera A"]
    first.rating = .unrated
    first.orientation = .landscape
    first.hasAlbums = false
    first.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 100)]
    first.timeZone = .gmt
    first.takenAfter = Date(timeIntervalSince1970: 0)
    first.takenBefore = Date(timeIntervalSince1970: 0)
    var second = first
    second.useReferenceAsset("22222222-2222-4222-8222-222222222222")
    second.city = "Synthetic Beta"
    second.tags = .anyOf(["33333333-3333-4333-8333-333333333333"])
    second.deviceModels = ["Synthetic Camera B"]
    second.rating = .stars(0)
    second.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400)]
    return (first, second)
}

/// 只暂停A的指定页，B即时成功；同一个读取器严格核对完整条件/令牌，不改变任何账户状态。
private actor QueryRaceSource: NativeSearchReading {
    private let first: NativeSearchQuery
    private let second: NativeSearchQuery
    private let delayNextPage: Bool
    private var pending: CheckedContinuation<NativeSearchPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    /// first/second为A/B的完整快照，delayNextPage为true时先正常返回A首屏，仅暂停其metadata续页。
    init(first: NativeSearchQuery, second: NativeSearchQuery, delayNextPage: Bool) {
        self.first = first
        self.second = second
        self.delayNextPage = delayNextPage
    }

    /// query必须逐字段等于A或B；continuation必须属于相应查询，返回合法的合成首屏或续页。
    func search(_ query: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        requestCount += 1
        if query == first {
            if delayNextPage, continuation == nil {
                return .init(assets: [searchAsset("query-a-first")], continuation: .cursor("a-next"))
            }
            let expected: NativeSearchContinuation? = delayNextPage ? .cursor("a-next") : nil
            guard continuation == expected, pending == nil else {
                Issue.record("The obsolete query must reach exactly its expected delayed page")
                throw NativeSearchError.invalidQuery
            }
            return await withCheckedContinuation { continuation in
                pending = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        guard query == second else {
            Issue.record("Every request must retain its complete query snapshot")
            throw NativeSearchError.invalidQuery
        }
        switch continuation {
        case nil: return .init(assets: [searchAsset("query-b-first")], continuation: .forkCursor("b-next"))
        case .forkCursor("b-next")?: return .init(assets: [searchAsset("query-b-second")], continuation: .forkCursor("b-final"))
        default:
            Issue.record("The current query must keep its own Fork continuation")
            throw NativeSearchError.invalidQuery
        }
    }

    /// 等待A实际进入并暂停指定页，确保测试覆盖真实在途请求而非尚未启动的Task。
    func waitForDelayedRequest() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 在B完成后返回合法A页面和新的metadata游标；故意不取消A，发布权必须由store判断。
    func releaseDelayedResponse() {
        guard let pending else {
            Issue.record("The obsolete query response must be waiting before release")
            return
        }
        pending.resume(returning: .init(assets: [searchAsset(delayNextPage ? "query-a-second" : "query-a-first")],
                                        continuation: .cursor("a-late-next")))
        self.pending = nil
    }
}

/// error为合成SDK错误，只用于验证界面可见错误语义，不包含服务端原始响应。
private struct ErrorSource: NativeSearchReading {
    let error: NativeSearchError

    /// query与continuation不触发网络；原样抛出指定的可安全展示错误。
    func search(_: NativeSearchQuery, continuation _: NativeSearchContinuation?) async throws -> NativeSearchPage {
        throw error
    }
}

/// 创建无私人内容的资源；id是测试序列身份，不作真实HTTP请求。
private nonisolated func searchAsset(_ id: String) -> TimelineAssetSummary {
    let date = Date(timeIntervalSince1970: 0)
    return .init(id: id, ownerID: "synthetic", capturedAt: date, uploadedAt: date, localOffsetHours: 0,
                 mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false,
                 visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
                 thumbhash: nil, thumbnailRevision: date)
}

/// 首页成功、次页首次失败、重试成功，验证调用方的游标控制。
private actor PagedSource: NativeSearchReading {
    private var failedOnce = false

    /// query不参与合成数据生成；continuation必须始终使用首屏返回的next。
    func search(_: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        guard let continuation else { return .init(assets: [searchAsset("first")], continuation: .cursor("next")) }
        #expect(continuation == .cursor("next"))
        if !failedOnce {
            failedOnce = true
            throw URLError(.notConnectedToInternet)
        }
        return .init(assets: [searchAsset("first"), searchAsset("second")], continuation: nil)
    }
}

/// 模拟即使取消仍会返回的服务端，测试不依赖固定sleep或网络。
private actor DelayedSource: NativeSearchReading {
    private var response: CheckedContinuation<NativeSearchPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// query/continuation仅满足读取契约；保存响应continuation直到测试显式完成。
    func search(_: NativeSearchQuery, continuation _: NativeSearchContinuation?) async throws -> NativeSearchPage {
        await withCheckedContinuation { continuation in
            response = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// 等待请求实际进入fixture，避免调度竞态导致错误的“迟到响应”测试。
    func waitForRequest() async {
        if response != nil {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 释放合成响应；不检查取消，故意测试上层的防御性边界。
    func complete() {
        response?.resume(returning: .init(assets: [searchAsset("late")], continuation: nil))
        response = nil
    }
}
