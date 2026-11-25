import Foundation
import Observation

/// 官方堆叠列表管理：前台fresh成功后才可写，失败或不明回执锁住写操作，显式Reload不重放写入。
@MainActor @Observable
final class NativeStackManagementStore {
    private(set) var stacks: [ManagedNativeStack] = []
    private(set) var busy = false
    private(set) var needsReload = true
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var revision = 0
    private(set) var mutationRevision = 0
    private var generation = UUID()

    /// 页面关闭或换账号/端点时清空全部选择来源；迟到列表和写回执没有发布权。
    func invalidate() {
        generation = UUID(); stacks = []; busy = false; needsReload = true
        hasLoaded = false; error = nil; notice = nil
    }

    /// source为原账号仓库；仅完整成功数组才能替换状态，空数组与网络/权限失败分开。
    func reload(source: any NativeStackManaging) async {
        guard !busy else { return }
        let owner = generation
        busy = true; needsReload = true; error = nil; notice = nil
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            let fresh = try await source.managementStacks()
            try Task.checkCancellation()
            guard owner == generation else { return }
            adopt(fresh)
        } catch {
            guard canPublish(error, owner: owner) else { return }
            self.error = "Photo stacks could not be loaded. Check permissions and connection, then Reload."
        }
    }

    /// change为确认时固定的动作；只调用一次写操作，后续fresh失败也不能自动重发。
    func perform(_ change: NativeStackChange, source: any NativeStackManaging) async {
        guard !busy, !needsReload else { return }
        let owner = generation
        busy = true; needsReload = true; error = nil; notice = nil
        var accepted = false
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            try await source.changeNativeStack(change)
            try Task.checkCancellation()
            guard owner == generation else { return }
            accepted = true; mutationRevision += 1
            let fresh = try await source.managementStacks()
            try Task.checkCancellation()
            guard owner == generation else { return }
            adopt(fresh)
            notice = "Server change confirmed and photo stacks reloaded."
        } catch {
            guard canPublish(error, owner: owner) else { return }
            // 超时/解码失败也可能已修改服务器，通知既有浏览刷新，但仍需用户Reload并重新确认。
            if !accepted {
                mutationRevision += 1
            }
            self.error = accepted ? "The server accepted the change, but stacks could not be reloaded. Reload before another change."
                : (error as? NativeStackError)?.errorDescription
                ?? (error as? LibraryWriteError)?.errorDescription
                ?? "The change could not be confirmed. It may have changed server records. Reload before another change."
        }
    }

    /// fresh是完整当前账号列表；revision使旧详情和确认选择退出，避免操作过期stack ID。
    private func adopt(_ fresh: [ManagedNativeStack]) {
        stacks = fresh; needsReload = false; hasLoaded = true; revision += 1
    }

    /// 取消与旧仓库代际静默退出，不能将旧账户失败信息发布到新页面。
    private func canPublish(_ error: Error, owner: UUID) -> Bool {
        owner == generation && !Task.isCancelled && !(error is CancellationError)
            && (error as? TimelineReadError) != .staleGeneration
    }
}

/// 新建/追加共用的真实照片选择分页；保留官方cursor，空过滤页仍可继续，不把首屏当全库。
@MainActor @Observable
final class NativeStackCandidateStore {
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var continuation: NativeSearchContinuation?
    private(set) var busy = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private var generation = UUID()
    private var consumed = Set<NativeSearchContinuation>()

    /// 退出选图或换号后清除旧资源及游标，不允许迟到页重现。
    func invalidate() {
        generation = UUID(); assets = []; continuation = nil; busy = false; hasLoaded = false; error = nil; consumed = []
    }

    /// source提供真实metadata页；existing是当前快照内已知成员，不能被重复选择或静默合并。
    func loadMore(source: any NativeStackManaging, excluding existing: Set<String>) async {
        guard !busy, !hasLoaded || continuation != nil else { return }
        let owner = generation
        let token = continuation
        busy = true; error = nil
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            let page = try await source.stackCandidates(continuation: token)
            try Task.checkCancellation()
            guard owner == generation else { return }
            guard page.continuation != token || page.continuation == nil,
                  page.continuation.map({ !consumed.contains($0) }) ?? true else { throw TimelineReadError.invalidResponse }
            if let token {
                consumed.insert(token)
            }
            var seen = Set(assets.map(\.id))
            assets += page.assets.filter { $0.stack == nil && !existing.contains($0.id) && seen.insert($0.id).inserted }
            continuation = page.continuation; hasLoaded = true
        } catch {
            guard owner == generation, !Task.isCancelled, !(error is CancellationError),
                  (error as? TimelineReadError) != .staleGeneration else { return }
            self.error = "Photos could not be loaded. Retry this page or close and Reload stacks."
        }
    }
}
