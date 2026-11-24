import Foundation
import Testing
@testable import Remmich

/// 直接验证原生状态机的分页互斥和游标环路防护，传输与资产均为合成内存资料。
@Suite("Native search pagination guards")
struct NativeSearchPaginationGuardTests {
    /// 首屏后暂停真正的续页请求；第二次点击不能重复发送，释放后只能追加一次。
    @Test @MainActor func allowsOnlyOnePendingContinuation() async {
        let source = PendingPageSource()
        let store = NativeSearchStore()
        await store.search(.init(), source: source)
        let pending = Task { await store.loadMore(source: source) }
        await source.waitForContinuation()
        #expect(store.isLoading)
        await store.loadMore(source: source)
        #expect(await source.requestCount == 2)
        #expect(store.assets.map(\.id) == ["first"])
        await source.releaseContinuation()
        await pending.value
        #expect(!store.isLoading)
        #expect(store.assets.map(\.id) == ["first", "second"])
        #expect(store.continuation == nil)
        #expect(store.error == nil)
    }

    /// tokens为同一协议的两个合法令牌；服务端第三页绕回已消费令牌时必须停止并保留已确认结果。
    @Test(arguments: [
        [NativeSearchContinuation.cursor("a"), .cursor("b")],
        [.page(2), .page(3)],
        [.forkCursor("a"), .forkCursor("b")],
    ])
    @MainActor func stopsContinuationCycles(_ tokens: [NativeSearchContinuation]) async {
        let source = CyclingPageSource(tokens: tokens)
        let store = NativeSearchStore()
        await store.search(.init(), source: source)
        await store.loadMore(source: source)
        #expect(store.assets.map(\.id) == ["first", "second"])
        #expect(store.continuation == tokens[1])
        await store.loadMore(source: source)
        #expect(store.error == "The server repeated a search continuation. Search again to continue.")
        #expect(store.assets.map(\.id) == ["first", "second"])
        #expect(store.continuation == nil)
        #expect(store.hasSearched && !store.isLoading)
        await store.loadMore(source: source)
        #expect(await source.requestedContinuations == [nil, tokens[0], tokens[1]])
    }
}

/// id仅为状态断言身份，返回不包含私人EXIF或图片路径的合成资源。
private nonisolated func paginationAsset(_ id: String) -> TimelineAssetSummary {
    let date = Date(timeIntervalSince1970: 0)
    return .init(id: id, ownerID: "synthetic", capturedAt: date, uploadedAt: date, localOffsetHours: 0,
                 mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false,
                 visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
                 thumbhash: nil, thumbnailRevision: date)
}

/// 首屏立即返回，续页必须由测试释放；用请求握手证明互斥，而非靠固定等待猜测时序。
private actor PendingPageSource: NativeSearchReading {
    private(set) var requestCount = 0
    private var pending: CheckedContinuation<NativeSearchPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// query不读取网络；continuation须为首屏令牌，返回首屏或暂停中的终页。
    func search(_: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        requestCount += 1
        if continuation == nil {
            return .init(assets: [paginationAsset("first")], continuation: .cursor("next"))
        }
        #expect(continuation == .cursor("next"))
        // 若互斥回归，明确失败但不覆盖首个等待者，确保测试仍能释放原请求并结束。
        guard requestCount == 2 else {
            Issue.record("Only one continuation request may be pending")
            return .init(assets: [paginationAsset("must-not-publish")], continuation: nil)
        }
        return await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    /// 等待续页已真正进入读取器；没有sleep，调用顺序不会影响测试真实性。
    func waitForContinuation() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 只释放一个确定的终页，不在fixture中替业务状态机去重或修改其状态。
    func releaseContinuation() {
        pending?.resume(returning: .init(assets: [paginationAsset("second")], continuation: nil))
        pending = nil
    }
}

/// 三页依次返回A、B、A令牌；记录原始入参，让测试确认停止后没有新请求。
private actor CyclingPageSource: NativeSearchReading {
    private let tokens: [NativeSearchContinuation]
    private(set) var requestedContinuations: [NativeSearchContinuation?] = []

    /// tokens是同一协议的两个令牌，测试调用点保证恰有两项。
    init(tokens: [NativeSearchContinuation]) {
        self.tokens = tokens
    }

    /// query不改变合成序列，continuation记录调用方实际使用的页位置；第三页包含不应发布的资源。
    func search(_: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        requestedContinuations.append(continuation)
        switch requestedContinuations.count {
        case 1: return .init(assets: [paginationAsset("first")], continuation: tokens[0])
        case 2: return .init(assets: [paginationAsset("second")], continuation: tokens[1])
        default: return .init(assets: [paginationAsset("must-not-publish")], continuation: tokens[0])
        }
    }
}
