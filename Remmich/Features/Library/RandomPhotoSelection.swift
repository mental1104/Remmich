import Foundation

/// 用户点击时冻结一个随机批次；只给原生Viewer提供临时完整桶，不写入canonical索引或重排原始拍摄时间。
@MainActor struct RandomPhotoSelection: Identifiable {
    let id = UUID()
    let route: AssetViewerRoute
    let timeline: PhotosTimelineStore

    /// assetID必须仍在assets当前确认批次中；缺项返回nil。之后的抽样不会改变这份值快照与查看器读取器。
    init?(assetID: String, assets: [TimelineAssetSummary]) {
        guard let selected = assets.first(where: { $0.id == assetID }) else { return nil }
        let snapshot = NativeSearchSnapshot(assets: assets)
        timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: assets.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: assets], groupedCatalogs: .init(), isComplete: true))
        route = .init(selectedAsset: selected, initialAssets: assets,
                      origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Random photos"), ordering: .sourceOrder)
    }
}
