import Foundation
import Observation

/// Steam专页复用真实搜索游标和既有Scene验证；只折叠后端确认完整的已加载组，不计算游戏或GPU规则。
@MainActor @Observable
final class SteamSceneStore {
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var availability: SceneStackAvailability?
    private(set) var expanded = Set<String>()
    private(set) var busy = false
    private(set) var hasLoaded = false
    private(set) var requiresReload = false
    private(set) var error: String?
    private(set) var notice: String?
    private let search = NativeSearchStore()
    private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?

    /// 仅表示服务器仍给出真实续页；不把当前条数或Scene组数当全库总数。
    var hasMore: Bool {
        !requiresReload && search.continuation != nil
    }

    /// 新账号/路由必须清空照片、游标与展开状态；取消真实任务并撤销所有旧发布权。
    func invalidate() {
        generation = UUID(); operation?.cancel(); operation = nil; search.invalidate()
        assets = []; availability = nil; expanded = []; busy = false; hasLoaded = false
        requiresReload = false; error = nil; notice = nil
    }

    /// 用户取消或离开正在加载的页面，保留已确认原片并展开；显式Reload才能建立新的分页链。
    func cancelLoading() {
        guard busy else { return }
        generation = UUID(); operation?.cancel(); operation = nil; search.invalidate()
        availability = nil; expanded = []; busy = false; requiresReload = true; error = nil
        notice = "Loading canceled. Loaded screenshots are kept. Reload to continue."
    }

    /// source/scenes必须属于同一原账号仓库，ownerID来自当前会话；重新搜索替换结果，不沿用旧游标。
    func reload(source: any NativeSearchReading, scenes: any SceneStackProviding, ownerID: String) async {
        await run(replacing: true, source: source, scenes: scenes, ownerID: ownerID)
    }

    /// 仅消费原搜索Store提供的下一游标；失败保留当前照片，可显式重试，不无限追加或自动采样。
    func loadMore(source: any NativeSearchReading, scenes: any SceneStackProviding, ownerID: String) async {
        guard !busy, hasMore else { return }
        await run(replacing: false, source: source, scenes: scenes, ownerID: ownerID)
    }

    /// enabled只控制外层投影；关闭保持原始已加载数组，封面不变成官方stack或整组写操作。
    func tiles(groupingEnabled: Bool) -> [SceneStackTile] {
        SceneStackValidator.project(assets: assets, groups: groupingEnabled ? availability?.groups ?? [] : [], expanded: expanded)
    }

    /// id是服务端不透明组键；只改变页面展开状态，不生成游戏名称、相簿或任何写请求。
    func toggle(_ id: String) {
        guard availability?.groups.contains(where: { $0.id == id }) == true else { return }
        if !expanded.insert(id).inserted {
            expanded.remove(id)
        }
    }

    /// replacing选择首屏或续页；每轮退休旧任务与折叠证据，保留已确认原片直到真实新页成功。
    private func run(replacing: Bool, source: any NativeSearchReading, scenes: any SceneStackProviding, ownerID: String) async {
        operation?.cancel(); generation = UUID()
        let owner = generation
        busy = true; error = nil; notice = nil; availability = nil; expanded = []
        let task = Task { await self.load(replacing: replacing, source: source, scenes: scenes, ownerID: ownerID, owner: owner) }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if owner == generation {
            operation = nil; busy = false
        }
    }

    /// 先由原NativeSearchStore读取固定Steam条件，再查询完整已加载集合；不对服务端组做筛选交集。
    /// 当前筛选或下一页缺少任何成员时服务端不返回该组；跨5000块/坏组/失败也一律保留原照片。
    private func load(replacing: Bool, source: any NativeSearchReading, scenes: any SceneStackProviding, ownerID: String, owner: UUID) async {
        if replacing {
            var query = NativeSearchQuery(); query.media = .image; query.mediaCategory = .steamScreenshot
            await search.search(query, source: source)
        } else {
            await search.loadMore(source: source)
        }
        do {
            try Task.checkCancellation()
            guard owner == generation else { return }
            if let failure = search.error {
                requiresReload = replacing; error = failure; return
            }
            guard search.hasSearched, UUID(uuidString: ownerID) != nil,
                  search.assets.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.mediaKind == .image && $0.visibility == .timeline })
            else { requiresReload = true; throw SceneStackError.invalidGroups }
            var seen = Set<String>()
            let originals = search.assets.filter { seen.insert($0.id.lowercased()).inserted }
            assets = originals; hasLoaded = true; requiresReload = false
            guard originals.contains(where: { $0.ownerID.caseInsensitiveCompare(ownerID) == .orderedSame }) else {
                availability = .notRequested; return
            }
            let reader = try await scenes.sceneStackReader()
            try Task.checkCancellation()
            guard owner == generation else { return }
            let result = try await reader.groupsForTimeline(originals)
            try Task.checkCancellation()
            guard owner == generation else { return }
            if case .notRequested = result {
                throw SceneStackError.invalidGroups
            }
            if case let .available(groups) = result {
                availability = try .available(SceneStackValidator.validate(groups, assetIDs: originals.map(\.id)))
            } else {
                availability = result
            }
        } catch {
            guard owner == generation, !Task.isCancelled, !(error is CancellationError),
                  (error as? TimelineReadError) != .staleGeneration else { return }
            availability = nil; expanded = []
            self.error = "Scene groups could not be verified. Loaded screenshots remain visible. Reload to try again."
        }
    }
}

/// 查看器冻结完整已加载原始集合，包括当前折叠成员；分页/开关不能改变已打开的邻居与拍摄日期。
@MainActor struct SteamSceneSelection: Identifiable {
    let id = UUID()
    let route: AssetViewerRoute
    let timeline: PhotosTimelineStore

    /// assetID须属于当前快照；保留原生Viewer的默认日期顺序和Media/本地优先通道，不使用折叠tile数组。
    init?(assetID: String, assets: [TimelineAssetSummary]) {
        guard let asset = assets.first(where: { $0.id == assetID }) else { return nil }
        let snapshot = NativeSearchSnapshot(assets: assets)
        timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: assets.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: assets], groupedCatalogs: .init(), isComplete: true))
        route = .init(selectedAsset: asset, initialAssets: assets,
                      origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Steam screenshots"))
    }
}
