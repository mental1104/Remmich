import ImmichAPI
import SwiftUI

/// 真实搜索页，复用原生缩略图与查看器，不显示演示资源。
struct SearchView: View {
    let source: ImmichTimelineRepository?
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let showAccount: () -> Void
    @State private var query = ImmichMetadataSearch()
    @State private var store = NativeSearchStore()
    @State private var selection: Selection?
    @Namespace private var viewerNamespace

    /// 固定点击时的结果和查看器状态，不被后续分页改变。
    private struct Selection: Identifiable {
        let id = UUID()
        let route: AssetViewerRoute
        let timeline: PhotosTimelineStore
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Media", selection: $query.media) {
                    Text("All").tag(ImmichMetadataSearch.Media.all)
                    Text("Photos").tag(ImmichMetadataSearch.Media.image)
                    Text("Videos").tag(ImmichMetadataSearch.Media.video)
                }
                .pickerStyle(.segmented).padding(.horizontal)
                DisclosureGroup("Filters") {
                    VStack {
                        TextField("City", text: $query.city)
                        TextField("Camera make", text: $query.cameraMake)
                        TextField("Camera model", text: $query.cameraModel)
                    }.textFieldStyle(.roundedBorder)
                }.padding(.horizontal)
                if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task {
                        if let source {
                            await store.loadMore(source: source)
                        }
                    } }
                }
                if store.assets.isEmpty, !store.isLoading {
                    ContentUnavailableView(store.hasSearched ? "No results" : "Search your library",
                                           systemImage: "magnifyingglass",
                                           description: Text("Search file names or choose metadata filters."))
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100, maximum: 180), spacing: 2)], spacing: 2) {
                    ForEach(store.assets) { asset in
                        Button { open(asset) } label: {
                            LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
                                .aspectRatio(1, contentMode: .fit).clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.mediaKind == .video ? "Open video" : "Open photo")
                    }
                }
                if store.isLoading {
                    ProgressView("Searching")
                }
                if store.nextCursor != nil, !store.isLoading {
                    Button("Load more") { Task {
                        if let source {
                            await store.loadMore(source: source)
                        }
                    } }
                }
                if !store.assets.isEmpty {
                    Text("Loaded \(store.assets.count) items").font(.caption)
                }
            }.padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.text, prompt: "File names")
        .toolbar { AccountToolbarButton(action: showAccount) }
        .task(id: query) { await search() }
        .onChange(of: media.management.generation) { _, _ in
            store.invalidate()
            selection = nil
            query = .init()
        }
        .fullScreenCover(item: $selection) { selected in
            AssetViewerView(route: selected.route, store: selected.timeline, media: media, assetDetails: assetDetails,
                            opensFromSource: false, namespace: viewerNamespace, close: { selection = nil },
                            visibilityChanged: { _ in })
        }
        .accessibilityIdentifier("search-root")
    }

    /// 防抖后按当前条件搜索；输入变化取消等待，不显示网络失败。
    private func search() async {
        store.invalidate()
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.media != .all
            || !query.city.isEmpty || !query.cameraMake.isEmpty || !query.cameraModel.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard let source else { return }
            await store.search(query, source: source)
        } catch { /* 取消防抖无需显示错误。 */ }
    }

    /// asset为点击项；创建仅包含已加载结果的查看器快照，不修改主时间线。
    private func open(_ asset: TimelineAssetSummary) {
        let snapshot = NativeSearchSnapshot(assets: store.assets)
        let timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: store.assets.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: store.assets],
                                 groupedCatalogs: .init(), isComplete: true))
        selection = Selection(route: .init(selectedAsset: asset, initialAssets: store.assets,
                                           origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Search")), timeline: timeline)
    }
}
