import Foundation
import Testing
@testable import Remmich

/// 只用合成媒体验证分页发布权、去重、失败恢复和跨账户清除。
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
