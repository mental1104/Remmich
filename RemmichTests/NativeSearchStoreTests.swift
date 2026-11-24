import Foundation
import ImmichAPI
import Testing
@testable import Remmich

/// 只用合成媒体验证分页发布权、去重、失败恢复和跨账户清除。
@Suite("Native search state")
struct NativeSearchStoreTests {
    /// 重复资源只保留首次顺序，失败页重试沿用原游标。
    @Test @MainActor func paginationRetainsCursorOnFailureAndDeduplicates() async {
        let source = PagedSource()
        let store = NativeSearchStore()
        await store.search(.init(), source: source)
        #expect(store.assets.map(\.id) == ["first"])
        #expect(store.nextCursor == "next")
        await store.loadMore(source: source)
        #expect(store.error != nil)
        #expect(store.nextCursor == "next")
        await store.loadMore(source: source)
        #expect(store.assets.map(\.id) == ["first", "second"])
        #expect(store.nextCursor == nil)
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

    /// query不参与合成数据生成；cursor必须始终使用首屏返回的next。
    func metadataSearch(_: ImmichMetadataSearch, cursor: String?) async throws -> NativeSearchPage {
        guard let cursor else { return .init(assets: [searchAsset("first")], nextCursor: "next") }
        #expect(cursor == "next")
        if !failedOnce {
            failedOnce = true
            throw URLError(.notConnectedToInternet)
        }
        return .init(assets: [searchAsset("first"), searchAsset("second")], nextCursor: nil)
    }
}

/// 模拟即使取消仍会返回的服务端，测试不依赖固定sleep或网络。
private actor DelayedSource: NativeSearchReading {
    private var response: CheckedContinuation<NativeSearchPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// query/cursor仅满足读取契约；保存响应continuation直到测试显式完成。
    func metadataSearch(_: ImmichMetadataSearch, cursor _: String?) async throws -> NativeSearchPage {
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
        response?.resume(returning: .init(assets: [searchAsset("late")], nextCursor: nil))
        response = nil
    }
}
