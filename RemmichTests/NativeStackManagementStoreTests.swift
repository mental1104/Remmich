import Foundation
import Testing
@testable import Remmich

/// Store时序与分页边界；协议字节由独立URLSession契约测试覆盖，不冒充真机UI验收。
@Suite("Native stack management state")
@MainActor struct NativeStackManagementStoreTests {
    /// 不明写入后锁定其他操作，显式Reload只GET，不重放创建。
    @Test func unknownWriteRequiresExplicitReload() async {
        let source = StackStoreSource(reads: [[], []], failWrite: true)
        let store = NativeStackManagementStore()
        await store.reload(source: source)
        await store.perform(.create(assetIDs: ["first", "second"], addingTo: nil), source: source)
        #expect(store.needsReload && store.error == NativeStackError.unconfirmed.errorDescription)
        await store.perform(.create(assetIDs: ["third", "fourth"], addingTo: nil), source: source)
        #expect(await source.writeCount == 1)
        #expect(await source.readCount == 1)
        await store.reload(source: source)
        #expect(!store.needsReload && store.error == nil)
        #expect(await source.writeCount == 1)
    }

    /// 写入已确认但刷新失败单独提示，后续Reload不会再次创建。
    @Test func acceptedWriteDoesNotReplayWhenRefreshFails() async {
        let source = StackStoreSource(reads: [[], []], failSecondRead: true)
        let store = NativeStackManagementStore()
        await store.reload(source: source)
        await store.perform(.create(assetIDs: ["first", "second"], addingTo: nil), source: source)
        #expect(store.needsReload && store.error?.contains("server accepted") == true)
        await store.reload(source: source)
        #expect(!store.needsReload && store.notice == nil)
        #expect(await source.writeCount == 1)
    }

    /// 旧列表最后返回不能覆盖已成功的新上下文。
    @Test(.timeLimit(.minutes(1))) func rejectsLateListFromOldContext() async {
        let source = StackStoreSource(reads: [[storeStack("old")], [storeStack("new")]], holdFirstRead: true)
        defer { Task { await source.stop() } }
        let store = NativeStackManagementStore()
        let pending = Task { await store.reload(source: source) }
        await source.waitForGate()
        store.invalidate()
        await store.reload(source: source)
        await source.release()
        await pending.value
        #expect(store.stacks.map(\.id) == ["new"] && !store.needsReload)
    }

    /// 已撤销的写回执不能再发旧账号刷新或显示成功。
    @Test(.timeLimit(.minutes(1))) func rejectsLateWriteWithoutStartingRefresh() async {
        let source = StackStoreSource(reads: [[], [storeStack("new")]], holdWrite: true)
        defer { Task { await source.stop() } }
        let store = NativeStackManagementStore()
        await store.reload(source: source)
        let pending = Task { await store.perform(.dissolve(storeStack("old")), source: source) }
        await source.waitForGate()
        store.invalidate()
        await store.reload(source: source)
        await source.release()
        await pending.value
        #expect(store.stacks.map(\.id) == ["new"] && store.notice == nil)
        #expect(await source.readCount == 2)
    }

    /// 过滤后空页仍保留cursor，下一页去重且不按显示数量重建游标。
    @Test func candidateEmptyPagePreservesCursorAndDeduplicates() async {
        let source = StackStoreSource(reads: [], pages: [
            .init(assets: [storeAsset("known")], continuation: .cursor("next")),
            .init(assets: [storeAsset("new"), storeAsset("new")], continuation: nil),
        ])
        let store = NativeStackCandidateStore()
        await store.loadMore(source: source, excluding: ["known"])
        #expect(store.hasLoaded && store.assets.isEmpty && store.continuation == .cursor("next"))
        await store.loadMore(source: source, excluding: ["known"])
        #expect(store.assets.map(\.id) == ["new"] && store.continuation == nil)
        #expect(await source.tokens == [nil, .cursor("next")])
    }

    /// 重复cursor显式报错且保留旧页，不无限加载同一页。
    @Test func rejectsRepeatedCandidateCursor() async {
        let source = StackStoreSource(reads: [], pages: [
            .init(assets: [storeAsset("one")], continuation: .cursor("same")),
            .init(assets: [storeAsset("two")], continuation: .cursor("same")),
        ])
        let store = NativeStackCandidateStore()
        await store.loadMore(source: source, excluding: [])
        await store.loadMore(source: source, excluding: [])
        #expect(store.assets.map(\.id) == ["one"] && store.error != nil)
        #expect(store.continuation == .cursor("same"))
    }
}

/// id只是状态标识，不用于任何网络调用。
private nonisolated func storeStack(_ id: String) -> ManagedNativeStack {
    .init(id: id, primaryAssetID: "primary", assets: [])
}

/// id为合成候选，完整摘要交给真实Store去重，不伪造照片字节或UI截图。
private nonisolated func storeAsset(_ id: String) -> TimelineAssetSummary {
    .init(id: id, ownerID: "synthetic", capturedAt: .distantPast, uploadedAt: .distantPast,
          localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
          isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
          projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
}

/// 只控制列表/分页返回与失败，不替换HTTP业务实现；gate固定旧结果返回的时序。
private actor StackStoreSource: NativeStackManaging {
    private var reads: [[ManagedNativeStack]]
    private var pages: [NativeSearchPage]
    private let failWrite: Bool
    private let failSecondRead: Bool
    private let holdFirstRead: Bool
    private let holdWrite: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    private(set) var writeCount = 0
    private(set) var readCount = 0
    private(set) var tokens: [NativeSearchContinuation?] = []

    /// reads/pages为有限按序结果；开关只控制明确失败或挂起阶段。
    init(reads: [[ManagedNativeStack]], pages: [NativeSearchPage] = [], failWrite: Bool = false,
         failSecondRead: Bool = false, holdFirstRead: Bool = false, holdWrite: Bool = false)
    {
        self.reads = reads; self.pages = pages; self.failWrite = failWrite
        self.failSecondRead = failSecondRead; self.holdFirstRead = holdFirstRead; self.holdWrite = holdWrite
    }

    /// 一次读取消耗一个完整列表，故障不消耗显式Reload的下一结果。
    func managementStacks() async throws -> [ManagedNativeStack] {
        readCount += 1
        if failSecondRead, readCount == 2 {
            throw URLError(.notConnectedToInternet)
        }
        guard !reads.isEmpty else { throw URLError(.badServerResponse) }
        let value = reads.removeFirst()
        if holdFirstRead, readCount == 1 {
            await hold()
        }
        return value
    }

    /// continuation完整记录，意外额外分页没有可用脚本。
    func stackCandidates(continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        tokens.append(continuation)
        guard !pages.isEmpty else { throw URLError(.badServerResponse) }
        return pages.removeFirst()
    }

    /// 记录真实Store写入次数，失败/挂起用于锁定与不重放测试。
    func changeNativeStack(_: NativeStackChange) async throws {
        writeCount += 1
        if holdWrite {
            await hold()
        }
        if failWrite {
            throw NativeStackError.unconfirmed
        }
    }

    /// gate安装后唤醒测试，让上下文变化先于旧回执。
    private func hold() async {
        guard !stopped else { return }
        await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }

    /// 等到真实调用已挂起，不靠sleep猜测时序。
    func waitForGate() async {
        if pending == nil, !stopped {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: { Task { await self.stop() } }
        }
    }

    /// 新上下文成功后释放旧结果，由Store自身守卫拒绝发布。
    func release() {
        pending?.resume(); pending = nil
    }

    /// 测试失败/超时清理阻止未来hold，同时释放进入观察和旧响应，不伪造新的业务结果。
    func stop() {
        stopped = true; release(); waiter?.resume(); waiter = nil
    }
}
