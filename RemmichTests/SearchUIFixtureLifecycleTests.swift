#if DEBUG
    import Foundation
    import Testing
    @testable import Remmich

    /// 实际DEBUG读取器必须给出可观察的进入屏障，并在忽略取消的迟到响应下保留真实Store发布隔离。
    @Suite("Search UI fixture lifecycle")
    @MainActor struct SearchUIFixtureLifecycleTests {
        /// started回调内释放比continuation安装更早；该信号必须保留，不能挂起或伪造一个完成页。
        @Test func releaseDuringStartedCallbackIsNotLost() async throws {
            let probe = SearchFixtureProbe(releaseDuringReport: true)
            let reader = SearchUIFixtureReader(account: "alpha") { [weak probe] _, state in await probe?.report(state) }
            probe.reader = reader
            var query = NativeSearchQuery(); query.text = "late"
            let result = try await reader.search(query, continuation: nil)
            #expect(probe.states == ["started late", "completed late"])
            #expect(result.assets.map(\.id) == ["search-alpha-9"])
            #expect(result.continuation == nil)
        }

        /// 先等真实读取器报告late已进入，再取消旧Store任务并读beta；旧完成值不能替换beta结果。
        @Test func explicitLateGatePreservesRealStoreAccountIsolation() async {
            let probe = SearchFixtureProbe()
            let alpha = SearchUIFixtureReader(account: "alpha") { [weak probe] _, state in await probe?.report(state) }
            probe.reader = alpha
            let beta = SearchUIFixtureReader(account: "beta") { _, _ in }
            let store = NativeSearchStore()
            var late = NativeSearchQuery(); late.text = "late"
            let request = late
            let pending = Task { await store.search(request, source: alpha) }
            let watcher = Task { await pending.value; probe.finished() }
            guard await probe.waitForStarted() else { await watcher.value; Issue.record("Late reader must actually enter its gate"); return }
            #expect(probe.states == ["started late"])
            #expect(store.isLoading && store.assets.isEmpty)
            pending.cancel(); store.invalidate()
            var next = NativeSearchQuery(); next.text = "synthetic"
            await store.search(next, source: beta)
            #expect(store.assets.map(\.id) == ["search-beta-1", "search-beta-2"])
            await alpha.finishLateRequest(); await watcher.value
            #expect(probe.states == ["started late", "completed late"])
            #expect(store.assets.map(\.id) == ["search-beta-1", "search-beta-2"])
            #expect(!store.isLoading && store.error == nil)
        }
    }

    /// 主线程记录真实report，支持明确早释放和无sleep进入屏障，不替换被测读取器/Store逻辑。
    @MainActor private final class SearchFixtureProbe {
        var reader: SearchUIFixtureReader?
        private(set) var states: [String] = []
        private let releaseDuringReport: Bool
        private var waiter: CheckedContinuation<Bool, Never>?
        private var completed = false

        /// releaseDuringReport仅用于精确控制早释放边界；false保留真实挂起等待。
        init(releaseDuringReport: Bool = false) {
            self.releaseDuringReport = releaseDuringReport
        }

        /// state来自实际读取器；在started调用仍未返回时释放，证明不会丢失提前到达的release。
        func report(_ state: String) async {
            states.append(state)
            guard state == "started late" else { return }
            if releaseDuringReport {
                await reader?.finishLateRequest()
            }
            waiter?.resume(returning: true); waiter = nil
        }

        /// 若原读取提前结束也返回false，避免无限gate等待掩盖源码错误。
        func waitForStarted() async -> Bool {
            if states.contains("started late") {
                return true
            }
            if completed {
                return false
            }
            return await withCheckedContinuation { waiter = $0 }
        }

        /// 实际Store任务结束后解除未达到gate的等待者，测试仍必须报告失败。
        func finished() {
            completed = true; waiter?.resume(returning: false); waiter = nil
        }
    }
#endif
