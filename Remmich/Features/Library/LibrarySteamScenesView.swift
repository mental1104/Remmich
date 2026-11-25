import SwiftUI

/// 可发现的Steam专页：真实来源筛选/原搜索游标和后端Scene证据，原图查看沿用Remmich与本地优先Media。
struct LibrarySteamScenesView: View {
    let source: ImmichTimelineRepository
    let ownerID: String
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    @State private var store = SteamSceneStore()
    @State private var groupingEnabled = true
    @State private var loadedOwner: UUID?
    @State private var operation: Task<Void, Never>?
    @State private var selection: SteamSceneSelection?
    @Namespace private var viewerNamespace

    /// 账号/端点代际同步改变时立刻停止渲染旧身份的缩略图，不等待异步task或onChange退场。
    private var currentTiles: [SceneStackTile] {
        loadedOwner == media.management.generation ? store.tiles(groupingEnabled: groupingEnabled) : []
    }

    /// 独立内容边界限制SwiftUI表达式复杂度；失败/取消/缺扩展不会被显示成成功空列表。
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Browse Steam screenshots using your server's category and scene rules. Scene covers use their real date and member count.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Scene grouping", isOn: $groupingEnabled)
                Text("\(store.assets.count) loaded screenshots").font(.caption)
                status
                LazyVGrid(columns: [.init(.adaptive(minimum: 110, maximum: 180), spacing: 12)], spacing: 12) {
                    ForEach(currentTiles) { tile in photo(tile) }
                }
                if store.hasMore {
                    Button("Load more") { run(replacing: false) }
                        .disabled(store.busy).accessibilityIdentifier("steam-scenes-load-more")
                }
                if store.busy {
                    Button("Cancel loading") { operation?.cancel(); operation = nil; store.cancelLoading() }
                        .accessibilityIdentifier("steam-scenes-cancel")
                }
            }.padding(16)
        }
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                LibraryPageHeader(title: "Steam screenshots") {
                    Button("Reload") { run(replacing: true) }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: media.management.generation) {
                if loadedOwner != media.management.generation {
                    operation?.cancel(); operation = nil; selection = nil; store.invalidate(); groupingEnabled = true
                    loadedOwner = media.management.generation
                }
                // 从Viewer返回保留当前页、游标和展开；取消/失败均等待显式Reload，不因重现页面自动重试。
                if !store.hasLoaded, !store.busy, !store.requiresReload, store.error == nil {
                    await store.reload(source: source, scenes: source, ownerID: ownerID)
                }
            }
            .onChange(of: media.management.revision) { _, _ in run(replacing: true) }
            .onChange(of: media.management.generation) { _, current in
                guard loadedOwner != current else { return }
                operation?.cancel(); operation = nil; loadedOwner = nil; selection = nil; store.invalidate()
            }
            .onDisappear { operation?.cancel(); operation = nil; store.cancelLoading() }
            .fullScreenCover(item: $selection) { selected in
                AssetViewerView(route: selected.route, store: selected.timeline, media: media, assetDetails: assetDetails,
                                opensFromSource: false, namespace: viewerNamespace, close: { selection = nil }, visibilityChanged: { _ in })
            }
            .accessibilityIdentifier("library-steam-scenes-root")
    }

    /// 分页未完成只表示有更多真实结果；缺成员组不能以当前交集代替，原片始终保留。
    @ViewBuilder private var status: some View {
        if store.busy {
            ProgressView("Loading screenshots and scene evidence")
        }
        if let error = store.error {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("steam-scenes-error")
        }
        if let notice = store.notice {
            Text(notice).foregroundStyle(.secondary)
        }
        if store.hasLoaded, store.assets.isEmpty, store.error == nil, !store.busy {
            Text("No Steam screenshots")
        }
        switch store.availability {
        case .unsupported?: Text("This server does not provide scene grouping. Screenshots remain visible.").foregroundStyle(.secondary)
        case .unavailable?: Text("Scene evidence is unavailable. Screenshots remain visible.").foregroundStyle(.secondary)
        case let .available(groups)?:
            Text("\(groups.count) complete scene groups in loaded screenshots").font(.caption)
            if store.hasMore {
                Text("Groups with unloaded or excluded members stay expanded.").font(.caption)
            }
        case .notRequested? where !store.assets.isEmpty:
            Text("No eligible own screenshots need a scene query.").font(.caption)
        default: EmptyView()
        }
    }

    /// 原片/封面/日期/数量均来自真实响应；首点封面展开，已展开或未分组照片进入原生Viewer。
    private func photo(_ tile: SceneStackTile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard loadedOwner == media.management.generation else { return }
                if let group = tile.group, !store.expanded.contains(group.id) {
                    store.toggle(group.id)
                } else {
                    selection = SteamSceneSelection(assetID: tile.asset.id, assets: store.assets)
                }
            } label: {
                LibraryAssetCover(assetID: tile.asset.id, revision: tile.asset.thumbnailRevision, media: media)
                    .aspectRatio(1, contentMode: .fit).clipped()
            }
            .buttonStyle(.plain).disabled(store.busy)
            .accessibilityLabel(tile.group == nil ? "Open screenshot" : "Open Steam scene group")
            .accessibilityIdentifier("steam-scene-photo-\(tile.id)")
            Text(tile.asset.capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption2)
            if let group = tile.group {
                Button { store.toggle(group.id) } label: {
                    Label("\(group.memberIDs.count) · \(store.expanded.contains(group.id) ? "Collapse" : "Expand")", systemImage: "rectangle.stack")
                        .font(.caption)
                }.buttonStyle(.borderless).disabled(store.busy)
            }
        }
    }

    /// replacing固定为重新搜索或下一页；任务属于当前页面/账号，离开时取消，不生成后台持久任务。
    private func run(replacing: Bool) {
        guard loadedOwner == media.management.generation else { store.invalidate(); return }
        operation?.cancel()
        operation = Task {
            if replacing {
                await store.reload(source: source, scenes: source, ownerID: ownerID)
            } else {
                await store.loadMore(source: source, scenes: source, ownerID: ownerID)
            }
        }
    }
}
