import Foundation
import Observation

/// 只有完整读取的真实月份才能成为折叠证据；revision来自原Photos Store，assets保持原始桶顺序与摘要。
nonisolated struct PhotosSceneMonthSnapshot: Sendable {
    let id: TimelineBucketID
    let revision: UInt64
    let assets: [TimelineAssetSummary]
}

/// 一个月份当前已验证的组，不持久化到Index；完整源快照用于防止目录部分加载或更新后复活旧折叠。
nonisolated struct PhotosSceneMonthEvidence: Sendable {
    let snapshot: PhotosSceneMonthSnapshot
    let groups: [SceneStackGroup]
}

/// 一次不可变几何输入；保留源快照、展开状态和版本，catalog/Viewer的原始索引从不被替换。
nonisolated struct TimelineScenePlan: Sendable {
    let revision: UInt64
    let evidence: [PhotosSceneMonthEvidence]
    let expanded: Set<String>
}

/// 主Photos的只读场景状态；只查当前可见的完整月份，账号/目录/请求变化撤销旧发布，不进行全库预扫。
@MainActor @Observable
final class PhotosSceneState {
    private(set) var enabled = true
    private(set) var revision: UInt64 = 0
    private(set) var metadataRevision: UInt64?
    private(set) var checking = false
    private(set) var status = "Scene grouping has not been checked."
    private(set) var plan: TimelineScenePlan?
    @ObservationIgnored private var accepted: [TimelineBucketID: PhotosSceneMonthEvidence] = [:]
    @ObservationIgnored private var expanded = Set<String>()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestKey: RequestKey?
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var acceptedOwner: UUID?
    @ObservationIgnored private(set) var visibleAssetIDs = Set<String>()

    /// 固定失败类别通过菜单与徽标显示；不会把错误当作空组或让旧计划继续隐藏照片。
    var hasFailure: Bool {
        blocked
    }

    /// 原始目录或账号版本不匹配时立即禁用旧几何，不能等待异步查询/观察回调才防止旧组隐藏。
    func renderPlan(owner: UUID, revision: UInt64) -> TimelineScenePlan? {
        enabled && acceptedOwner == owner && metadataRevision == revision ? plan : nil
    }

    /// 真实可见ID只作调度游标，不触发SwiftUI逐帧重绘，也不写入Index/存储。
    func rememberVisible(_ ids: Set<String>) {
        visibleAssetIDs = ids
    }

    /// 请求键只用身份/原目录版本/可见月份，滚动同一月份不会重复查询或比较全库数组。
    private struct RequestKey: Equatable {
        let owner: UUID
        let revision: UInt64
        let months: [TimelineBucketID]
    }

    /// 换号/端点时清空所有资产相关证据；开关仅为本次账号浏览上下文，不沿用其他账户设置。
    func invalidate() {
        cancelPending(); enabled = true; metadataRevision = nil; acceptedOwner = nil; accepted = [:]; expanded = []; blocked = false
        visibleAssetIDs = []; checking = false; status = "Scene grouping has not been checked."; publish()
    }

    /// 用户开关只撤销显示和请求，不写服务器；重新开启必须取得新证据，不能重放上次缓存隐藏权。
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        cancelPending(); enabled = value; accepted = [:]; expanded = []; blocked = false; checking = false
        status = value ? "Scene grouping has not been checked." : "Scene grouping is off. Original order is shown."
        publish()
    }

    /// 明确资产变更或Reload立即展开全部照片；随后正常可见月份调度才会再查证据。
    func reloadEvidence() {
        cancelPending(); accepted = [:]; expanded = []; blocked = false; checking = false
        status = "Scene grouping has not been checked."; publish()
    }

    /// 离开主Photos/打开Viewer时只停止未完成查询，已确认几何留给原生返回动画；迟到响应失去发布权。
    func pause() {
        cancelPending(); checking = false
    }

    /// snapshots只来自已加载完整月份；source为原repo，owner为当前界面账号代际，revision为当前原始目录版本。
    /// 同月滚动合并请求；真实失败后等待明确Reload或目录更新，不在后台循环重试。
    @discardableResult
    func schedule(snapshots: [PhotosSceneMonthSnapshot], source: any SceneStackProviding, owner: UUID, revision: UInt64) -> Task<Void, Never>? {
        guard enabled else { return nil }
        let sorted = snapshots.sorted { $0.id.rawValue < $1.id.rawValue }
        let key = RequestKey(owner: owner, revision: revision, months: sorted.map(\.id))
        guard key != requestKey else { return task }
        cancelPending(); requestKey = key
        let generation = generation
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            if acceptedOwner != owner || metadataRevision != revision {
                acceptedOwner = owner; metadataRevision = revision; accepted = [:]; expanded = []; blocked = false; publish()
            }
            guard !blocked else { return }
            guard !sorted.isEmpty else { checking = false; status = "Scene grouping waits for a complete loaded month."; return }
            checking = true
            status = "Checking scene evidence for loaded months."
            defer {
                if generation == self.generation {
                    checking = false
                }
            }
            do {
                let reader = try await source.sceneStackReader()
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                var values: [PhotosSceneMonthEvidence] = []
                var queried = false
                for snapshot in sorted {
                    let result = try await reader.groupsForTimeline(snapshot.assets)
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    switch result {
                    case .unsupported:
                        fail("This server does not provide scene grouping. Original order is shown."); return
                    case .unavailable:
                        fail("Scene evidence is unavailable. Original order is shown."); return
                    case .notRequested:
                        values.append(.init(snapshot: snapshot, groups: []))
                    case let .available(groups):
                        queried = true
                        let valid = try SceneStackValidator.validate(groups, assetIDs: snapshot.assets.map(\.id))
                        let byID = Dictionary(snapshot.assets.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                        guard valid.allSatisfy({ group in group.memberIDs.allSatisfy { id in
                            byID[id]?.mediaKind == .image && byID[id]?.visibility == .timeline
                        } }) else { throw SceneStackError.invalidGroups }
                        // 官方Web以原桶顺序排列展开成员，不使用manifest可能任意的成员次序。
                        let ordered = valid.map { group in
                            let members = Set(group.memberIDs)
                            return SceneStackGroup(id: group.id, coverID: group.coverID,
                                                   memberIDs: snapshot.assets.map { $0.id.lowercased() }.filter { members.contains($0) })
                        }
                        values.append(.init(snapshot: snapshot, groups: ordered))
                    }
                }
                guard generation == self.generation else { return }
                for value in values {
                    accepted[value.snapshot.id] = value
                }
                status = queried ? "Scene grouping is active for verified loaded months." : "No eligible own photos were queried in these months."
                publish()
            } catch {
                guard generation == self.generation, !Task.isCancelled, !(error is CancellationError),
                      (error as? TimelineReadError) != .staleGeneration else { return }
                fail("Scene groups could not be verified. Original order is shown. Reload to try again.")
            }
        }
        return task
    }

    /// id仅为已验证组的不透明键；不将封面变成多张照片的写入选择。
    @discardableResult
    func toggle(_ id: String) -> Bool {
        guard accepted.values.contains(where: { $0.groups.contains(where: { $0.id == id }) }) else { return false }
        if !expanded.insert(id).inserted {
            expanded.remove(id)
        }
        publish()
        return true
    }

    /// 原始Viewer可能访问折叠成员；返回前只展开其所属外层组，保证原照片可作为真实返回目标。
    func reveal(_ assetID: String) {
        let key = assetID.lowercased()
        for value in accepted.values {
            for group in value.groups where group.memberIDs.contains(key) {
                if expanded.insert(group.id).inserted {
                    publish()
                }
                return
            }
        }
    }

    /// 对当前可见月份形成原子不可变计划；跨月重复组/成员也全部拒绝，不给部分组显示隐藏权。
    private func publish() {
        revision &+= 1
        let evidence = accepted.values.sorted { $0.snapshot.id.rawValue < $1.snapshot.id.rawValue }
        let groups = evidence.flatMap(\.groups)
        guard enabled, !groups.isEmpty else { plan = nil; return }
        var used = Set<String>(); var ids = Set<String>()
        guard groups.allSatisfy({ group in
            guard ids.insert(group.id).inserted, used.isDisjoint(with: group.memberIDs) else { return false }
            used.formUnion(group.memberIDs); return true
        }) else { accepted = [:]; expanded = []; plan = nil; blocked = true; status = "Scene groups overlap. Original order is shown."; return }
        plan = .init(revision: revision, evidence: evidence, expanded: expanded)
    }

    /// 任何真实失败先撤销全部组，再等待明确重试；原始目录没有被本类型改变。
    private func fail(_ message: String) {
        accepted = [:]; expanded = []; blocked = true; status = message; publish()
    }

    /// 取消实际只读任务并撤销发布代际，避免下一轮和旧响应竞争；不清空已接受的原生目录。
    private func cancelPending() {
        generation = UUID(); task?.cancel(); task = nil; requestKey = nil
    }
}
