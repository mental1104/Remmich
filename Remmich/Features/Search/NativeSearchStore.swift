import Foundation
import ImmichAPI
import Observation

/// 当前页媒体与原始续页令牌，不将返回数量当作全局总数。
nonisolated struct NativeSearchPage: Sendable {
    let assets: [TimelineAssetSummary]
    let nextCursor: String?
}

/// 只读搜索边界；query是固定条件，cursor为上次响应令牌，错误不得伪装为空结果。
nonisolated protocol NativeSearchReading: Sendable {
    func metadataSearch(_ query: ImmichMetadataSearch, cursor: String?) async throws -> NativeSearchPage
}

extension ImmichTimelineRepository: NativeSearchReading {}

/// 管理查询及分页的发布权；外部账户变化必须invalidate，迟到响应不改变新状态。
@MainActor @Observable
final class NativeSearchStore {
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasSearched = false
    private(set) var nextCursor: String?
    private var generation = UUID()
    private var query = ImmichMetadataSearch()
    private var consumedCursors: Set<String> = []

    /// 清除本查询/账户的结果与续页状态，已经在途的响应失去发布权。
    func invalidate() {
        generation = UUID()
        assets = []
        error = nil
        nextCursor = nil
        consumedCursors = []
        isLoading = false
        hasSearched = false
    }

    /// query为新条件，source为当前账号读取器；取消不弹错误，失败保留重试入口。
    func search(_ query: ImmichMetadataSearch, source: any NativeSearchReading) async {
        invalidate()
        self.query = query
        await load(cursor: nil, source: source)
    }

    /// 读取下一页或重试失败首屏；source不变，一次最多一个在途分页。
    func loadMore(source: any NativeSearchReading) async {
        guard !isLoading, !hasSearched || nextCursor != nil else { return }
        await load(cursor: nextCursor, source: source)
    }

    /// cursor为本次页位置；成功去重追加，失败不推进游标，取消或失效不发布。
    private func load(cursor: String?, source: any NativeSearchReading) async {
        let owner = generation
        isLoading = true
        error = nil
        defer {
            if owner == generation {
                isLoading = false
            }
        }
        do {
            let page = try await source.metadataSearch(query, cursor: cursor)
            try Task.checkCancellation()
            guard owner == generation else { return }
            if let next = page.nextCursor, next == cursor || consumedCursors.contains(next) {
                error = "The server repeated a search cursor. Search again to continue."
                nextCursor = nil
                hasSearched = true
                return
            }
            var ids = Set(assets.map(\.id))
            assets += page.assets.filter { ids.insert($0.id).inserted }
            if let cursor {
                consumedCursors.insert(cursor)
            }
            nextCursor = page.nextCursor
            hasSearched = true
        } catch {
            guard owner == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            // 不泄露原始响应与查询内容，失败页允许用户重试。
            self.error = "Search could not be loaded. Check connection, permissions, and server version."
        }
    }
}

/// 查看器固定使用点击时已加载的结果，不重新搜索或写入持久索引。
nonisolated struct NativeSearchSnapshot: TimelineReading {
    let assets: [TimelineAssetSummary]
    static let bucket = TimelineBucketID(rawValue: "1970-01-01")

    /// query不修改快照；单个临时桶仅供查看器遍历，不表示照片拍摄日期。
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        [.init(id: Self.bucket, assetCount: assets.count)]
    }

    /// bucketID须为快照桶，query不重新过滤；返回已有搜索顺序。
    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        bucketID == Self.bucket ? assets : []
    }

    /// 搜索结果不产生回忆。
    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
