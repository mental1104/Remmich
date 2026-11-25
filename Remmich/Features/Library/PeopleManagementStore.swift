import Foundation
import Observation

/// 人物管理独立状态；先fresh加载才能写，任何不明写入结果都会锁住后续写入，直到明确Reload。
@MainActor @Observable
final class PeopleManagementStore {
    private(set) var people: [ManagedPerson] = []
    private(set) var busy = false
    private(set) var needsReload = true
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var revision = 0
    private(set) var mutationRevision = 0
    private var generation = UUID()

    /// 页面退出或账号/端点切换撤销所有迟到发布；不保留跨账号姓名、隐藏状态或确认选择。
    func invalidate() {
        generation = UUID()
        people = []
        busy = false
        needsReload = true
        hasLoaded = false
        error = nil
        notice = nil
    }

    /// source为原仓库；只在完整fresh列表成功时替换，失败保留旧列表并禁止写入。
    func reload(source: any PeopleManaging) async {
        guard !busy else { return }
        let owner = generation
        busy = true
        needsReload = true
        error = nil
        notice = nil
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            let fresh = try await source.managementPeople()
            try Task.checkCancellation()
            guard owner == generation else { return }
            adopt(fresh)
        } catch {
            guard canPublish(error, owner: owner) else { return }
            self.error = "People could not be loaded. Check permissions and connection, then Reload."
        }
    }

    /// expected/name由用户确认；fresh完整列表须匹配新姓名及原隐藏状态，不以PUT回执代替最终读后核对。
    func rename(_ expected: ManagedPerson, name: String, source: any PeopleManaging) async {
        let confirmed = ManagedPerson(id: expected.id, name: name, isHidden: expected.isHidden)
        await perform(source: source, confirming: confirmed) { try await source.renamePerson(expected, name: name) }
    }

    /// expected为当前记录；fresh列表须同时确认新隐藏状态及原姓名，隐藏人物仍由withHidden完整读取。
    func setHidden(_ expected: ManagedPerson, hidden: Bool, source: any PeopleManaging) async {
        let confirmed = ManagedPerson(id: expected.id, name: expected.name, isHidden: hidden)
        await perform(source: source, confirming: confirmed) { try await source.setPersonHidden(expected, hidden: hidden) }
    }

    /// 两个明确选择的人物只提交一次；POST失败/部分结果之后必须重新读取和重新确认方向。
    func merge(target: ManagedPerson, sourcePerson: ManagedPerson, source: any PeopleManaging) async {
        await perform(source: source) { try await source.mergePeople(target: target, source: sourcePerson) }
    }

    /// operation只由三种显式动作提供；expected固定改名/隐藏的确认字段，nil保留既有合并行为。
    /// accepted仅表示原写通道已校验回执；fresh读取失败或字段不符时仍需Reload，任何情况都不重放写入。
    private func perform(source: any PeopleManaging, confirming expected: ManagedPerson? = nil,
                         operation: @Sendable () async throws -> Void) async
    {
        guard !busy, !needsReload else { return }
        let owner = generation
        busy = true
        needsReload = true
        error = nil
        notice = nil
        var accepted = false
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            try await operation()
            try Task.checkCancellation()
            guard owner == generation else { return }
            accepted = true
            mutationRevision += 1
            let fresh = try await source.managementPeople()
            try Task.checkCancellation()
            guard owner == generation else { return }
            if let expected {
                // 200回执后可能出现旧/不同列表；目标缺失、重复或任一可编辑字段不符均不能发布成功。
                let matches = fresh.filter { $0.id.lowercased() == expected.id.lowercased() }
                guard matches.count == 1, expected.matchesEditableFields(matches[0]) else { throw PeopleManagementError.unconfirmedPerson }
            }
            adopt(fresh)
            notice = "Server change confirmed and people reloaded."
        } catch {
            guard canPublish(error, owner: owner) else { return }
            // 可能部分写入或响应丢失时也通知既有索引刷新；这不代表成功，也不会重放写请求。
            if !accepted {
                mutationRevision += 1
            }
            self.error = (error as? PeopleManagementError)?.errorDescription
                ?? (accepted ? "The server accepted the change, but people could not be reloaded. Reload before another change."
                    : (error as? LibraryWriteError)?.errorDescription
                    ?? "The operation could not be confirmed. It may have changed server records. Reload before another change.")
        }
    }

    /// fresh只能来自完整读取；revision通知原生浏览和详情退出，即使新列表内容恰好未改变。
    private func adopt(_ fresh: [ManagedPerson]) {
        people = fresh
        needsReload = false
        hasLoaded = true
        revision += 1
    }

    /// error/owner共同决定是否还能发布；取消或旧仓库代际不显示旧账户错误。
    private func canPublish(_ error: Error, owner: UUID) -> Bool {
        owner == generation && !Task.isCancelled && !(error is CancellationError)
            && (error as? TimelineReadError) != .staleGeneration
    }
}
