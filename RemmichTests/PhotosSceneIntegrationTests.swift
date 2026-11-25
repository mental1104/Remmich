import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Remmich

/// 真实原始目录与几何共同验收：场景只能改变显示，不能改变日期、选择或Viewer所用的原索引。
@Suite("Photos scene geometry", .serialized)
struct PhotosSceneGeometryTests {
    /// square/natural均跨日沿原桶顺序展开；scale仅选择细网格，粗日期目录和所有原摘要保持原样。
    @Test(arguments: [TimelineSemanticScale.square, .natural])
    func expandedMembersKeepOriginalIndexesAndDates(scale: TimelineSemanticScale) throws {
        let assets = photosSceneAssets(240)
        let catalog = TimelineSemanticCatalog(assets: assets)
        let original = TimelineSemanticProjection.complete(catalog: catalog, scale: scale, size: photosSceneSize, isPhone: true, dark: true)
        let collapsed = photosScenePlan(assets, expanded: false)
        let expanded = photosScenePlan(assets, expanded: true, revision: 2)
        let folded = TimelineSceneGeometry.apply(to: original, scenes: .init(plan: collapsed, catalog: catalog), size: photosSceneSize, isPhone: true, dark: true)
        let open = TimelineSceneGeometry.apply(to: original, scenes: .init(plan: expanded, catalog: catalog), size: photosSceneSize, isPhone: true, dark: true)
        let cells = open.items.filter { !$0.isHeader }
        let position = try #require(cells.firstIndex { $0.id == assets[80].id })
        #expect(Array(cells[position ..< position + 3]).map(\.id) == [assets[80].id, assets[180].id, assets[20].id])
        #expect(Set(cells.map(\.id)) == Set(assets.map(\.id)))
        #expect(cells.count == assets.count && folded.items.filter { !$0.isHeader }.count == assets.count - 2)
        for cell in cells {
            #expect(cell.assetRange == cell.nodeIndex ..< cell.nodeIndex + 1)
            #expect(catalog.assets[cell.nodeIndex].id == cell.id)
            #expect(catalog.assets[cell.nodeIndex] == assets[cell.nodeIndex])
        }
        let dateHeaders = Set(original.items.filter(\.isHeader).map(\.id))
        #expect(Set(open.items.filter(\.isHeader).map(\.id)).isSubset(of: dateHeaders))
        #expect(catalog.assets == assets)
        let dates = TimelineSemanticProjection.complete(catalog: catalog, scale: .day, size: photosSceneSize, isPhone: true, dark: true)
        let sameDates = TimelineSceneGeometry.apply(to: dates, scenes: .init(plan: expanded, catalog: catalog), size: photosSceneSize, isPhone: true, dark: true)
        #expect(sameDates.items.map(\.frame) == dates.items.map(\.frame))
        #expect(sameDates.items.map(\.assetRange) == dates.items.map(\.assetRange))
    }

    /// 原窗口命中同月时保留全月，展开成员的非单调索引不会被分页丢掉；组成员都在同一个5000请求内。
    @Test func sceneWindowAndHiddenDateTargetUseOriginalCatalog() {
        let assets = photosSceneAssets(6000, interval: 60)
        let catalog = TimelineSemanticCatalog(assets: assets)
        let group = SceneStackGroup(id: "scene:large/month", coverID: assets[5000].id, memberIDs: [assets[5900].id, assets[5000].id, assets[1200].id])
        let plan = TimelineScenePlan(revision: 1, evidence: [.init(snapshot: .init(id: photosSceneMonth, revision: 1, assets: Array(assets.reversed())), groups: [group])], expanded: [group.id])
        let scenes = ResolvedTimelineScenes(plan: plan, catalog: catalog)
        let geometry = TimelineSceneGeometry.apply(to: photosSceneGeometry(catalog), scenes: scenes, size: photosSceneSize, isPhone: true, dark: true)
        let window = geometry.window(catalog: catalog, focusAssetIndex: 5000, size: photosSceneSize, isPhone: true, requestedRange: 4990 ..< 5010, scenes: scenes)
        #expect(window.nodeRange == 0 ..< 6000)
        #expect(Set(window.items.filter { !$0.isHeader }.map(\.id)) == Set(assets.map(\.id)))
        #expect(scenes.visibleAnchor(for: 1200) == 1200)
        let closed = TimelineScenePlan(revision: 2, evidence: plan.evidence, expanded: [])
        #expect(ResolvedTimelineScenes(plan: closed, catalog: catalog).visibleAnchor(for: 1200) == 5000)
        #expect(catalog.index(containing: 1200, scale: .day) != catalog.index(containing: 5000, scale: .day))
    }

    /// 证据依赖的任何原摘要缺失或发生变化，整月退回原顺序，不能对半个catalog应用隐藏。
    @Test(arguments: [false, true])
    func changedOrIncompleteSourceCannotHideAssets(missing: Bool) {
        let assets = photosSceneAssets(240)
        let plan = photosScenePlan(assets, expanded: false)
        let current = missing ? Array(assets.dropFirst()) : photosSceneAssets(240, interval: 601)
        let catalog = TimelineSemanticCatalog(assets: current)
        let original = photosSceneGeometry(catalog)
        let resolved = ResolvedTimelineScenes(plan: plan, catalog: catalog)
        let result = TimelineSceneGeometry.apply(to: original, scenes: resolved, size: photosSceneSize, isPhone: true, dark: true)
        #expect(resolved.covers.isEmpty)
        #expect(result.items.map(\.id) == original.items.map(\.id))
        #expect(result.items.map(\.frame) == original.items.map(\.frame))
    }

    /// 实际UICollectionView反复折叠/展开保持封面屏幕Y；原始隐藏目标可跳转，选择模式恢复所有原片。
    @Test @MainActor func controllerAnchorsCoverAndUsesOriginalSelectionAndViewerNeighbors() throws {
        let assets = photosSceneAssets(240)
        let catalog = TimelineSemanticCatalog(assets: assets)
        let runtime = TimelineSemanticRuntime()
        let controller = TimelineSemanticCollectionController()
        runtime.controller = controller
        defer { controller.stop() }
        var toggles: [String] = []
        var selected: TimelineAssetSummary?
        var neighbors: [TimelineAssetSummary] = []
        var input = TimelineSemanticCollectionView(catalog: catalog, revision: 1, scale: .square,
                                                   media: MediaLibraryController(), namespace: nil, bottomClearance: 96, topClearance: 64,
                                                   runtime: runtime, latestRequest: 0, isActive: true,
                                                   scenePlan: photosScenePlan(assets, expanded: false),
                                                   toggleScene: { toggles.append($0); return true },
                                                   hiddenThumbnailID: nil, hiddenLivePhotoID: nil,
                                                   selectAsset: { selected = $0; neighbors = $1 }, selectGroup: { _, _ in },
                                                   scaleChanged: { _ in }, scrolled: { _, _, _ in }, visibleAssetsChanged: { _, _, _ in }, refresh: {})
        controller.update(input)
        controller.view.frame = CGRect(origin: .zero, size: photosSceneSize)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let source = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<Int, String>)
        let cover = assets[80].id
        collection.contentOffset.y = try photosSceneFrame(cover, collection: collection, source: source).midY - 350
        collection.layoutIfNeeded()
        let screenY = try photosSceneFrame(cover, collection: collection, source: source).midY - collection.contentOffset.y
        for iteration in 0 ..< 4 {
            #expect(controller.toggleSceneGroup(at: cover))
            input.scenePlan = photosScenePlan(assets, expanded: iteration % 2 == 0, revision: UInt64(iteration + 2))
            controller.update(input); collection.layoutIfNeeded()
            let currentY = try photosSceneFrame(cover, collection: collection, source: source).midY - collection.contentOffset.y
            #expect(abs(currentY - screenY) < 1)
        }
        #expect(toggles.count == 4)
        runtime.prepareRootReturn(assetID: assets[20].id)
        controller.update(input); collection.layoutIfNeeded()
        let targetY = try photosSceneFrame(cover, collection: collection, source: source).midY - collection.contentOffset.y
        #expect(abs(targetY - collection.bounds.height * 0.5) < 1)
        input.scenePlan = photosScenePlan(assets, expanded: true, revision: 8)
        controller.update(input); collection.layoutIfNeeded()
        controller.activateAsset(assets[20].id)
        #expect(selected == assets[20])
        #expect(neighbors == Array(assets[0 ..< 101].reversed()))
        input.assetSelectionActive = true
        controller.update(input); collection.layoutIfNeeded()
        #expect(Set(source.snapshot().itemIdentifiers.filter { catalog.assetIndexes[$0] != nil }) == Set(assets.map(\.id)))
        controller.activateAsset(cover)
        #expect(selected == assets[80] && toggles.count == 4)
        input.assetSelectionActive = false; input.scenePlan = photosScenePlan(assets, expanded: false, revision: 9)
        controller.update(input); collection.layoutIfNeeded()
        #expect(!source.snapshot().itemIdentifiers.contains(assets[20].id))
    }
}

/// 只接受完整快照或真实完整bucket读取，不从首屏伪计数推断月份完整。
@Suite("Photos scene completeness")
@MainActor struct PhotosSceneCompletenessTests {
    /// 完整flag与opening窗口各自独立约束，即便摘要数量恰好相等也不能假装完整。
    @Test(arguments: [false, true], [false, true])
    func bootstrapRequiresAcceptedCompleteMonth(complete: Bool, opening: Bool) {
        let assets = photosSceneAssets(6)
        let store = PhotosTimelineStore(reader: PhotosSceneTimelineReader(assets: assets))
        store.bootstrap(.init(generation: 1, summaries: [.init(id: photosSceneMonth, assetCount: assets.count)],
                              assetsByBucket: [photosSceneMonth: assets], groupedCatalogs: .init(), isComplete: complete), openingWindow: opening)
        let snapshots = store.sceneSnapshots(visibleAssetIDs: [assets[2].id])
        #expect(snapshots.count == (complete && !opening ? 1 : 0))
        if let snapshot = snapshots.first {
            #expect(snapshot.assets == assets && snapshot.revision > 0)
        }
        #expect(store.sceneSnapshots(visibleAssetIDs: ["missing"]).isEmpty)
    }

    /// 首屏部分快照不准折叠，随后真实GET完整桶才授予当前月资格。
    @Test func realBucketReadPromotesOnlyThatMonth() async {
        let assets = photosSceneAssets(6)
        let reader = PhotosSceneTimelineReader(assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        store.bootstrap(.init(generation: 1, summaries: [.init(id: photosSceneMonth, assetCount: assets.count)],
                              assetsByBucket: [photosSceneMonth: Array(assets.prefix(2))], groupedCatalogs: .init(), isComplete: false))
        #expect(store.sceneSnapshots(visibleAssetIDs: [assets[0].id]).isEmpty)
        await store.loadBucket(photosSceneMonth, force: true)
        #expect(await reader.assetReads == 1)
        #expect(store.sceneSnapshots(visibleAssetIDs: [assets[0].id]).first?.assets == assets)
    }
}

/// 纯合成合法UUID，确保严格validator不是通过无效测试ID绕过。
private nonisolated func photosSceneID(_ index: Int) -> String {
    String(format: "99999999-9999-4999-8999-%012x", index + 1)
}

private nonisolated let photosSceneMonth = TimelineBucketID(rawValue: "2027-01-01")
private nonisolated let photosSceneSize = CGSize(width: 402, height: 874)
private nonisolated let photosSceneOwner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

/// count/interval生成稳定原始拍摄顺序；保留官方stack与拍摄时间，完全不读私人照片。
private nonisolated func photosSceneAssets(_ count: Int, interval: TimeInterval = 600) -> [TimelineAssetSummary] {
    (0 ..< count).map { index in
        let date = Date(timeIntervalSince1970: 1_798_761_600 + Double(index) * interval)
        return .init(id: photosSceneID(index), ownerID: photosSceneOwner, capturedAt: date, uploadedAt: date,
                     localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1.5,
                     isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
                     stack: index == 80 ? .init(id: "native-stack", assetCount: 2) : nil,
                     projectionType: nil, thumbhash: nil, thumbnailRevision: date)
    }
}

/// 输入为原catalog升序，证据保持真实HTTP桶的降序；组ID故意不是UUID。
private nonisolated func photosScenePlan(_ assets: [TimelineAssetSummary], expanded: Bool, revision: UInt64 = 1) -> TimelineScenePlan {
    let group = SceneStackGroup(id: "scene:fixture/group", coverID: assets[80].id, memberIDs: [assets[180].id, assets[80].id, assets[20].id])
    return .init(revision: revision, evidence: [.init(snapshot: .init(id: photosSceneMonth, revision: 1, assets: Array(assets.reversed())), groups: [group])], expanded: expanded ? [group.id] : [])
}

/// 只创建几何，不使用缩略图网络或新过滤catalog。
private nonisolated func photosSceneGeometry(_ catalog: TimelineSemanticCatalog) -> TimelineSemanticProjection {
    .complete(catalog: catalog, scale: .square, size: photosSceneSize, isPhone: true, dark: true)
}

/// 实际diffable datasource与UICollectionViewLayout共同决定目标坐标，不能用待测算法自行计算预期Y。
@MainActor private func photosSceneFrame(_ id: String, collection: UICollectionView, source: UICollectionViewDiffableDataSource<Int, String>) throws -> CGRect {
    let path = try #require(source.indexPath(for: id))
    let attributes = try #require(collection.collectionViewLayout.layoutAttributesForItem(at: path))
    return attributes.frame
}

/// 有限真实Store读取器，只替换数据来源，不替换完整性标记/分页/发布逻辑。
private actor PhotosSceneTimelineReader: TimelineReading {
    let assets: [TimelineAssetSummary]
    private(set) var assetReads = 0
    /// assets为本测试的唯一完整桶。
    init(assets: [TimelineAssetSummary]) {
        self.assets = assets
    }

    /// 原桶摘要真实声明完整长度。
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        [.init(id: photosSceneMonth, assetCount: assets.count)]
    }

    /// 真正经过Store.loadBucket才统计一次，不能在测试里直接设置complete标记。
    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        assetReads += 1; return assets
    }

    /// 本夹具不提供回忆，不影响月份完整性。
    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
