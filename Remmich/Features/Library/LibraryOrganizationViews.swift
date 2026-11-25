import SwiftUI

/// 原生随机照片页；每批只来自官方随机入口，刷新不会在查看器浏览中途替换当前快照。
struct LibraryRandomPhotosView: View {
    let source: any OrganizationReading
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    @State private var store = RandomPhotosStore()
    @State private var selection: Selection?
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadedOwner: UUID?
    @Namespace private var viewerNamespace

    /// 固定点击时的随机批次；后续抽样或账户变化不能修改已打开查看器的读取范围。
    private struct Selection: Identifiable {
        let id = UUID()
        let route: AssetViewerRoute
        let timeline: PhotosTimelineStore
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("A random batch of up to 60 visible photos. Shuffle again for a new batch.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                        .accessibilityIdentifier("random-photos-error")
                    Button("Retry", action: beginRefresh)
                        .disabled(store.isLoading)
                }
                if store.hasLoaded, store.assets.isEmpty, store.error == nil, !store.isLoading {
                    ContentUnavailableView("No photos", systemImage: "shuffle",
                                           description: Text("No visible photos were returned for this batch."))
                        .accessibilityIdentifier("random-photos-empty")
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100, maximum: 180), spacing: 2)], spacing: 2) {
                    ForEach(store.assets) { asset in
                        Button { open(asset) } label: {
                            LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
                                .aspectRatio(1, contentMode: .fit).clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open photo")
                        .accessibilityIdentifier("random-photo-\(asset.id)")
                    }
                }
                if store.isLoading {
                    ProgressView("Loading random photos")
                }
                if !store.assets.isEmpty {
                    Text("Loaded \(store.assets.count) photos").font(.caption)
                }
            }.padding(.vertical)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LibraryPageHeader(title: "Random photos") {
                Button(action: beginRefresh) {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Shuffle again")
                .accessibilityIdentifier("random-photos-shuffle")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refresh(source: source) }
        .task(id: media.management.generation) {
            let owner = media.management.generation
            if loadedOwner != owner {
                store.invalidate()
                selection = nil
                loadedOwner = owner
            }
            // 查看器关闭重新出现时保留当前批次；只有用户明确Shuffle或新账号才重新抽样。
            if !store.hasLoaded, store.error == nil {
                await store.refresh(source: source)
            }
        }
        .onChange(of: media.management.generation) { _, _ in refreshTask?.cancel(); loadedOwner = nil; store.invalidate(); selection = nil }
        .onDisappear { refreshTask?.cancel(); refreshTask = nil }
        .fullScreenCover(item: $selection) { selected in
            AssetViewerView(route: selected.route, store: selected.timeline, media: media, assetDetails: assetDetails,
                            opensFromSource: false, namespace: viewerNamespace, close: { selection = nil },
                            visibilityChanged: { _ in })
        }
        .accessibilityIdentifier("random-photos-root")
    }

    /// 按钮读取由本页持有Task，离开页面或切换身份时取消；不创建持久随机请求或隐形后台刷新。
    private func beginRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await store.refresh(source: source) }
    }

    /// asset为当前批次中实际点击项；沿用原生查看器和冻结结果读取器，不写入持久时间线索引。
    private func open(_ asset: TimelineAssetSummary) {
        let snapshot = NativeSearchSnapshot(assets: store.assets)
        let timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: store.assets.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: store.assets], groupedCatalogs: .init(), isComplete: true))
        selection = Selection(route: .init(selectedAsset: asset, initialAssets: store.assets,
                                           origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Random photos")), timeline: timeline)
    }
}

/// 待整理入口展示本人指定分组相簿，打开后沿用原生按月加载时间线；不把无相簿照片当成待整理。
struct LibraryPendingAlbumsView: View {
    let source: ImmichTimelineRepository
    let ownerID: String
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let context: LibraryCollectionNavigation
    @State private var store = PendingAlbumsStore()
    @State private var reloadTask: Task<Void, Never>?
    @Namespace private var albumNamespace

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Albums you own in the server group:").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: PendingAlbumSelection.groupName).font(.caption)
                if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                        .accessibilityIdentifier("pending-albums-error")
                    Button("Retry", action: beginReload).disabled(store.isLoading)
                }
                if store.supported == false {
                    ContentUnavailableView("Pending groups unavailable", systemImage: "folder.badge.questionmark",
                                           description: Text("This server does not provide album groups. Standard albums remain available."))
                        .accessibilityIdentifier("pending-albums-unsupported")
                } else if store.hasLoaded, store.albums.isEmpty, store.error == nil, !store.isLoading {
                    ContentUnavailableView("No pending albums", systemImage: "tray",
                                           description: Text("No albums you own belong to this group."))
                        .accessibilityIdentifier("pending-albums-empty")
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 150, maximum: 260), spacing: 14)], spacing: 14) {
                    ForEach(store.albums) { album in
                        LibraryCardLink(id: album.id, namespace: albumNamespace) {
                            LibraryCollectionTimeline(title: album.title, source: source,
                                                      query: PendingAlbumSelection.timelineQuery(for: album),
                                                      media: media, assetDetails: assetDetails,
                                                      tabSelectionState: context.tabSelectionState,
                                                      viewerPresentations: context.viewerPresentations,
                                                      tabBarTop: context.tabBarTop)
                                .id(media.management.generation)
                        } label: {
                            LibraryCollectionCard(title: album.title, count: album.assetCount,
                                                  symbol: "rectangle.stack", appearance: .glass) { EmptyView() }
                        }
                        .accessibilityIdentifier("pending-album-\(album.id)")
                    }
                }.padding(.horizontal, 16)
                if store.isLoading {
                    ProgressView("Loading pending albums")
                }
            }.padding(.vertical)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LibraryPageHeader(title: "Pending albums") {
                Button(action: beginReload) {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .disabled(store.isLoading)
                .accessibilityLabel("Reload pending albums")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await reload() }
        .task(id: media.management.generation) {
            store.invalidate()
            await reload()
        }
        .onChange(of: media.management.generation) { _, _ in reloadTask?.cancel(); store.invalidate() }
        .onDisappear { reloadTask?.cancel(); reloadTask = nil }
        .accessibilityIdentifier("pending-albums-root")
    }

    /// 当前会话ownerID不从相簿内容猜测；原始API错误交给独立状态机安全展示。
    private func reload() async {
        await store.load(source: source, ownerID: ownerID)
    }

    /// 按钮重载绑定本页生命周期，返回Library或进入相簿时取消尚未完成的目录读取。
    private func beginReload() {
        reloadTask?.cancel()
        reloadTask = Task { await reload() }
    }
}
