import Foundation
import Observation

/// 仅查看器消费直读DTO；领域读取模型仍保持Foundation-only，离线契约编译无需引入整个UI/时间线。
nonisolated extension AssetViewerFreshAsset {
    /// existing是同一静态照片；返回服务器真实显示版本，保留捕获排序/原片语义，拒绝身份/媒体/不可见状态不匹配。
    func replacing(_ existing: TimelineAssetSummary) throws -> TimelineAssetSummary {
        guard id == existing.id, ownerId == existing.ownerID, type == "IMAGE", existing.mediaKind == .image,
              livePhotoVideoId == nil, existing.livePhotoVideoID == nil, !isTrashed, ["timeline", "archive"].contains(visibility)
        else { throw AssetViewerFreshReadError.invalid }
        let ratio: Double = if let width, let height, width > 0, height > 0 {
            Double(width) / Double(height)
        } else {
            existing.aspectRatio
        }
        // 前置白名单只接受这两种可见性；索引文件的private初始化器不属于查看器可调用契约。
        let freshVisibility: TimelineVisibility = visibility == "archive" ? .archive : .timeline
        return try .init(id: existing.id, ownerID: existing.ownerID, capturedAt: existing.capturedAt, uploadedAt: existing.uploadedAt,
                         localOffsetHours: existing.localOffsetHours, mediaKind: existing.mediaKind, durationMilliseconds: existing.durationMilliseconds,
                         aspectRatio: ratio, isFavorite: isFavorite, visibility: freshVisibility, livePhotoVideoID: existing.livePhotoVideoID,
                         stack: existing.stack, projectionType: existing.projectionType, thumbhash: thumbhash, thumbnailRevision: revision(),
                         usesUploadDate: existing.usesUploadDate, place: existing.place)
    }
}

nonisolated enum AssetViewerOrigin: Hashable, Sendable {
    case timeline(bucketID: TimelineBucketID, contentName: String)
    case scoped(route: PhotosRangeRoute, contentName: String)
    case memory(AssetViewerMemoryContext)
}

nonisolated struct AssetViewerMemoryContext: Hashable, Sendable {
    let id: String
    let memoryAt: Date
    let sourceYear: Int
    var availableOn: Date?

    var title: String {
        let currentYear = Calendar.autoupdatingCurrent.component(.year, from: availableOn ?? .now)
        let years = max(1, currentYear - sourceYear)
        return years == 1 ? "1 year ago" : "\(years.formatted()) years ago"
    }
}

/// 默认沿用拍摄日期顺序；独立服务端抽样等固定结果可明确保留自身顺序，不改变照片拍摄时间。
nonisolated enum AssetViewerOrdering: Hashable, Sendable {
    case chronological
    case sourceOrder
}

nonisolated struct AssetViewerRoute: Hashable, Identifiable, Sendable {
    let selectedAsset: TimelineAssetSummary
    let initialAssets: [TimelineAssetSummary]
    let origin: AssetViewerOrigin
    var ordering: AssetViewerOrdering = .chronological

    var id: String {
        "\(origin.idComponent)|\(selectedAsset.id)"
    }
}

private extension AssetViewerOrigin {
    nonisolated var idComponent: String {
        switch self {
        case let .timeline(bucketID, contentName):
            "timeline|\(contentName)|\(bucketID.rawValue)"
        case let .scoped(route, contentName):
            "scoped|\(contentName)|\(String(describing: route))"
        case let .memory(context):
            "memory|\(context.id)"
        }
    }
}

@MainActor
@Observable
final class AssetViewerSession {
    typealias BucketLoader = @MainActor (TimelineBucketID) async -> [TimelineAssetSummary]

    private(set) var assets: [TimelineAssetSummary]
    private(set) var sourceAssets: [TimelineAssetSummary]
    private(set) var isLoadingNeighbor = false
    private(set) var unavailableMessage: String?
    var selectedAssetID: String

    private(set) var origin: AssetViewerOrigin
    private var ordering: AssetViewerOrdering

    private let bucketIDs: [TimelineBucketID]
    private let loadBucket: BucketLoader?
    private var loadedBucketIDs: Set<TimelineBucketID> = []
    private var bucketByAssetID: [String: TimelineBucketID] = [:]
    private var refreshedAssets: [String: TimelineAssetSummary] = [:]

    var isVideoPlayback: Bool {
        selectedAsset?.mediaKind == .video
    }

    var allowsHorizontalPaging: Bool {
        !isVideoPlayback
    }

    init(
        route: AssetViewerRoute,
        bucketIDs: [TimelineBucketID] = [],
        loadBucket: BucketLoader? = nil
    ) {
        origin = route.origin
        ordering = route.ordering
        selectedAssetID = route.selectedAsset.id
        let sourceAssets = Self.orderedUnique(route.initialAssets + [route.selectedAsset], ordering: route.ordering)
        self.sourceAssets = sourceAssets
        assets = Self.viewerProjection(
            sourceAssets: sourceAssets,
            selectedAsset: route.selectedAsset,
            ordering: route.ordering
        )
        self.bucketIDs = bucketIDs
        self.loadBucket = loadBucket

        if case let .timeline(bucketID, _) = route.origin {
            bucketByAssetID[route.selectedAsset.id] = bucketID
        }
    }

    var selectedAsset: TimelineAssetSummary? {
        assets.first { $0.id == selectedAssetID }
    }

    var selectedIndex: Int? {
        assets.firstIndex { $0.id == selectedAssetID }
    }

    func start() async {
        guard !isVideoPlayback,
              case let .timeline(bucketID, _) = origin
        else { return }
        await load(bucketID)
        await loadNeighborsIfNeeded()
    }

    func select(_ assetID: String) async {
        guard selectImmediately(assetID) else { return }
        await loadNeighborsIfNeeded()
    }

    func replaceMemoryRoute(_ route: AssetViewerRoute) {
        guard case .memory = origin,
              case .memory = route.origin
        else { return }
        origin = route.origin
        ordering = route.ordering
        sourceAssets = Self.orderedUnique(route.initialAssets + [route.selectedAsset], ordering: ordering)
        assets = Self.viewerProjection(
            sourceAssets: sourceAssets,
            selectedAsset: route.selectedAsset,
            ordering: ordering
        )
        selectedAssetID = route.selectedAsset.id
        isLoadingNeighbor = false
        unavailableMessage = nil
        loadedBucketIDs.removeAll()
        bucketByAssetID.removeAll()
        refreshedAssets.removeAll()
    }

    @discardableResult
    func selectImmediately(_ assetID: String) -> Bool {
        guard allowsHorizontalPaging || assetID == selectedAssetID, assets.contains(where: { $0.id == assetID }) else { return false }
        selectedAssetID = assetID
        return true
    }

    /// fresh为当前直读返回的真实summary；只替换同id/owner/媒体类型项，保持选中位置、原始排序与邻居加载状态。
    /// 返回false表示选择或来源已改变，旧刷新不得插入新资源或切换视频/Live Photo模式。
    @discardableResult
    func replaceSelectedAsset(_ fresh: TimelineAssetSummary) -> Bool {
        guard selectedAssetID == fresh.id, let existing = selectedAsset,
              existing.ownerID == fresh.ownerID, existing.mediaKind == .image, fresh.mediaKind == .image,
              existing.livePhotoVideoID == nil, fresh.livePhotoVideoID == nil,
              fresh.thumbnailRevision >= existing.thumbnailRevision else { return false }
        assets = assets.map { $0.id == fresh.id ? fresh : $0 }
        sourceAssets = sourceAssets.map { $0.id == fresh.id ? fresh : $0 }
        refreshedAssets[fresh.id] = fresh
        return true
    }

    func loadNeighborsIfNeeded() async {
        guard allowsHorizontalPaging,
              case .timeline = origin,
              let selectedIndex,
              !assets.isEmpty
        else { return }

        if selectedIndex <= 1, let selectedBucket = bucketByAssetID[selectedAssetID] {
            await loadAdjacent(to: selectedBucket, offset: -1)
        }
        if selectedIndex >= max(0, assets.count - 2),
           let selectedBucket = bucketByAssetID[selectedAssetID]
        {
            await loadAdjacent(to: selectedBucket, offset: 1)
        }
    }

    private func loadAdjacent(to bucketID: TimelineBucketID, offset: Int) async {
        guard let index = bucketIDs.firstIndex(of: bucketID) else { return }
        let adjacentIndex = index + offset
        guard bucketIDs.indices.contains(adjacentIndex) else { return }
        await load(bucketIDs[adjacentIndex])
    }

    private func load(_ bucketID: TimelineBucketID) async {
        guard !loadedBucketIDs.contains(bucketID), let loadBucket else { return }
        loadedBucketIDs.insert(bucketID)
        isLoadingNeighbor = true
        defer { isLoadingNeighbor = false }
        let loaded = await loadBucket(bucketID).map { candidate in
            guard let fresh = refreshedAssets[candidate.id], fresh.thumbnailRevision >= candidate.thumbnailRevision else { return candidate }
            return fresh
        }
        guard !Task.isCancelled else {
            loadedBucketIDs.remove(bucketID)
            return
        }

        if loaded.isEmpty {
            unavailableMessage = "Some nearby items could not be loaded."
        } else {
            unavailableMessage = nil
            for asset in loaded {
                bucketByAssetID[asset.id] = bucketID
            }
            sourceAssets = Self.orderedUnique(sourceAssets + loaded, ordering: ordering)
            guard let selectedAsset = sourceAssets.first(where: { $0.id == selectedAssetID }) else {
                return
            }
            assets = Self.viewerProjection(
                sourceAssets: sourceAssets,
                selectedAsset: selectedAsset,
                ordering: ordering
            )
        }
    }

    /// sourceAssets是当前读取范围，selectedAsset保留单视频语义；ordering仅控制静态照片结果的排列。
    nonisolated static func viewerProjection(
        sourceAssets: [TimelineAssetSummary],
        selectedAsset: TimelineAssetSummary,
        ordering: AssetViewerOrdering = .chronological
    ) -> [TimelineAssetSummary] {
        if selectedAsset.mediaKind == .video {
            return [selectedAsset]
        }
        return orderedUnique(sourceAssets + [selectedAsset], ordering: ordering)
            .filter { $0.mediaKind != .video }
    }

    /// values为一次或接续读取的资产；默认日期排序完全不变，sourceOrder稳定去重且不篡改原始日期。
    nonisolated static func orderedUnique(
        _ values: [TimelineAssetSummary],
        ordering: AssetViewerOrdering = .chronological
    ) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        let ordered = ordering == .chronological ? values.sorted { $1.isOrdered(before: $0) } : values
        return ordered.filter { seen.insert($0.id).inserted }
    }
}
