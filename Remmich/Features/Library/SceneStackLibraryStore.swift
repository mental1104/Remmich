import Foundation
import Observation

/// 独立场景页持有完整照片快照，分组失败只撤销投影，不丢原片；所有迟到结果受页面代际限制。
@MainActor @Observable
final class SceneStackLibraryStore {
    private(set) var months: [TimelineBucketSummary] = []
    private(set) var selectedMonth: TimelineBucketID?
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var availability: SceneStackAvailability?
    private(set) var expanded = Set<String>()
    private(set) var busy = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private var generation = UUID()

    /// 换号/端点撤销旧列表、照片、组、展开与错误，不能沿用上一账户的分组证据。
    func invalidate() {
        generation = UUID(); months = []; selectedMonth = nil; assets = []; availability = nil
        expanded = []; busy = false; hasLoaded = false; error = nil
    }

    /// 管理变更先退休旧读取并展开原片，不能等异步facade工厂返回后才撤销旧请求的发布权。
    /// 保留原照片与月份；后续页面Reload重新读取当前证据，本方法不启动请求或写服务器。
    func retireEvidence() {
        generation = UUID(); busy = false; unfoldAll()
    }

    /// 仅清理本轮投影；调用方负责是否退休读取，beginRequest不可再次改变已捕获的代际。
    private func unfoldAll() {
        availability = nil; expanded = []
    }

    /// facade建立失败时只显示固定安全文本，不把无路由/权限失败伪装成空月份。
    func readerUnavailable() {
        generation = UUID(); busy = false; unfoldAll()
        error = "Scene photos could not be loaded. Check connection and permissions, then Reload."
    }

    /// reader绑定原仓库身份；每次Reload真实读取月份与当前月，保留未完成查询前已知原照片供查看。
    func reload(reader: any SceneStackReading) async {
        let owner = beginRequest()
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            let fresh = try await reader.months()
            try Task.checkCancellation()
            guard owner == generation else { return }
            guard Set(fresh.map(\.id)).count == fresh.count, fresh.allSatisfy({ !$0.id.rawValue.isEmpty && $0.assetCount >= 0 }) else { throw SceneStackError.invalidGroups }
            months = fresh; hasLoaded = true
            guard let month = fresh.first(where: { $0.id == selectedMonth }) ?? fresh.first else {
                selectedMonth = nil; assets = []; availability = .notRequested
                return
            }
            try await load(month.id, reader: reader, owner: owner)
        } catch { publishFailure(error, owner: owner) }
    }

    /// month必须来自当前真实月份；新月失败保留之前月的真实照片与选择，不把旧照片改标为新月。
    func select(_ month: TimelineBucketID, reader: any SceneStackReading) async {
        guard months.contains(where: { $0.id == month }) else { return }
        let owner = beginRequest()
        defer {
            if owner == generation {
                busy = false
            }
        }
        do { try await load(month, reader: reader, owner: owner) }
        catch { publishFailure(error, owner: owner) }
    }

    /// enabled只改变本页外层显示，关闭立即恢复原顺序；不写服务器或索引，也不改变原生stack。
    func tiles(groupingEnabled: Bool) -> [SceneStackTile] {
        SceneStackValidator.project(assets: assets, groups: groupingEnabled ? availability?.groups ?? [] : [], expanded: expanded)
    }

    /// id必须为本次有效组；展开只保存页面状态，不调用官方unstack或构造写请求。
    func toggle(_ id: String) {
        guard availability?.groups.contains(where: { $0.id == id }) == true else { return }
        if !expanded.insert(id).inserted {
            expanded.remove(id)
        }
    }

    /// 先撤销旧分组显示，再发新读取；并行选月/Reload的旧响应不能恢复旧投影。
    private func beginRequest() -> UUID {
        generation = UUID(); busy = true; error = nil; unfoldAll()
        return generation
    }

    /// 完整原照片先发布，分组之后再原子发布；任一块/响应坏掉时仍保留完整本月照片。
    private func load(_ month: TimelineBucketID, reader: any SceneStackReading, owner: UUID) async throws {
        let originals = try await reader.assets(in: month)
        try Task.checkCancellation()
        guard owner == generation else { return }
        guard originals.allSatisfy({ $0.mediaKind == .image && $0.visibility == .timeline }),
              Set(originals.map { $0.id.lowercased() }).count == originals.count else { throw SceneStackError.invalidGroups }
        selectedMonth = month; assets = originals; hasLoaded = true
        if originals.isEmpty {
            availability = .notRequested; return
        }
        let result = try await reader.groups(for: originals)
        try Task.checkCancellation()
        guard owner == generation else { return }
        // 非空月已经调用groups，不能被来源误标为未查询/空月。
        if case .notRequested = result {
            throw SceneStackError.invalidGroups
        }
        if case let .available(groups) = result {
            availability = try .available(SceneStackValidator.validate(groups, assetIDs: originals.map(\.id)))
        } else {
            availability = result
        }
    }

    /// error/owner只允许当前非取消操作发布固定文案；保留全部当前照片，不吞掉HTTP失败当空组。
    private func publishFailure(_ error: Error, owner: UUID) {
        guard owner == generation, !Task.isCancelled, !(error is CancellationError),
              (error as? TimelineReadError) != .staleGeneration else { return }
        unfoldAll()
        self.error = "Scene groups could not be verified. All loaded photos remain visible. Check permissions and connection, then Reload."
    }
}
