import SwiftUI

/// Library可达的独立只读场景页；保留原照片快照与原生查看器，不改变主时间线/索引/官方stack。
struct LibrarySceneStacksView: View {
    let source: any SceneStackProviding
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    @State private var store = SceneStackLibraryStore()
    @State private var reader: (any SceneStackReading)?
    @State private var operation: Task<Void, Never>?
    @State private var loadedOwner: UUID?
    @State private var groupingEnabled = true
    @State private var selection: Selection?
    @Namespace private var viewerNamespace

    /// 查看器固定点击时完整月快照，折叠/展开或后续刷新不改变其照片/日期/官方stack范围。
    private struct Selection: Identifiable {
        let id = UUID()
        let route: AssetViewerRoute
        let timeline: PhotosTimelineStore
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                LibraryPageHeader(title: "Scene groups") {
                    Button("Reload", action: beginReload).disabled(store.busy)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: media.management.generation) {
                if loadedOwner != media.management.generation {
                    operation?.cancel(); store.invalidate(); reader = nil; selection = nil; groupingEnabled = true
                    loadedOwner = media.management.generation
                }
                if !store.hasLoaded, store.error == nil {
                    await reload()
                }
            }
            .onChange(of: media.management.generation) { _, _ in
                operation?.cancel(); operation = nil; reader = nil; loadedOwner = nil; selection = nil; store.invalidate()
            }
            .onChange(of: media.management.revision) { _, _ in store.retireEvidence(); beginReload() }
            .onDisappear { operation?.cancel(); operation = nil }
            .fullScreenCover(item: $selection) { selected in
                AssetViewerView(route: selected.route, store: selected.timeline, media: media, assetDetails: assetDetails,
                                opensFromSource: false, namespace: viewerNamespace, close: { selection = nil }, visibilityChanged: { _ in })
            }
            .accessibilityIdentifier("library-scene-stacks-root")
    }

    /// 列表表达式独立于生命周期/Viewer修饰链，控制SwiftUI类型推断范围。
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                status
                LazyVGrid(columns: [.init(.adaptive(minimum: 110, maximum: 180), spacing: 12)], spacing: 12) {
                    ForEach(store.tiles(groupingEnabled: groupingEnabled)) { tile in
                        sceneTile(tile)
                    }
                }
            }.padding(16)
        }.refreshable { await reload() }
    }

    /// 月份来自真实标准桶，不把全媒体桶count冒充照片数；显示数量始终取完整已加载IMAGE快照。
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scene grouping is a read-only view on this page. Original photos and photo stacks are retained.")
                .font(.caption).foregroundStyle(.secondary)
            if !store.months.isEmpty {
                Picker("Month", selection: Binding(get: {
                    store.months.contains(where: { $0.id == store.selectedMonth }) ? store.selectedMonth?.rawValue ?? "" : ""
                }, set: selectMonth)) {
                    Text("Select month").tag("")
                    ForEach(store.months) { month in
                        if let date = month.id.displayDate {
                            Text(date, format: .dateTime.year().month(.wide)).tag(month.id.rawValue)
                        } else {
                            Text(month.id.rawValue).tag(month.id.rawValue)
                        }
                    }
                }.pickerStyle(.menu).disabled(store.busy)
            }
            Toggle("Scene grouping on this page", isOn: $groupingEnabled)
            Text("\(store.assets.count) loaded photos").font(.caption).foregroundStyle(.secondary)
            if case let .available(groups)? = store.availability {
                Text("\(groups.count) scene groups").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 不支持、证据不可用、真实错误与空月份分别解释；任何失败都保持完整照片，不给无效组隐藏权。
    @ViewBuilder private var status: some View {
        if store.busy {
            ProgressView("Loading photos and scene evidence")
        }
        if let error = store.error {
            Text(L10n.string(error)).foregroundStyle(.red).accessibilityIdentifier("scene-stacks-error")
        }
        switch store.availability {
        case .unsupported?: Text("This server does not provide scene grouping. All photos remain visible.").foregroundStyle(.secondary)
        case .unavailable?: Text("Scene evidence is unavailable. All photos remain visible.").foregroundStyle(.secondary)
        case .notRequested?: Text(L10n.string(store.months.isEmpty ? "No timeline months" : "No photos in this month.")).foregroundStyle(.secondary)
        case let .available(groups)? where groups.isEmpty: Text("No complete scene groups for these loaded photos.").foregroundStyle(.secondary)
        case nil where !store.busy && store.error == nil && !store.assets.isEmpty:
            Text("Scene grouping has not been checked. Reload to query evidence.").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    /// tile保留真实原片摘要；封面首次点击只展开，展开后可进原生viewer，独立按钮可收起整组。
    private func sceneTile(_ tile: SceneStackTile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let group = tile.group, !store.expanded.contains(group.id) {
                    store.toggle(group.id)
                } else {
                    open(tile.asset)
                }
            } label: {
                LibraryAssetCover(assetID: tile.asset.id, revision: tile.asset.thumbnailRevision, media: media)
                    .aspectRatio(1, contentMode: .fit).clipped()
            }
            .buttonStyle(.plain).disabled(store.busy)
            .accessibilityLabel(L10n.string(tile.group == nil ? "Open photo" : "Open scene group"))
            .accessibilityIdentifier("scene-photo-\(tile.id)")
            Text(tile.asset.capturedAt, format: .dateTime.month().day().hour().minute()).font(.caption2)
            if let group = tile.group {
                Button { store.toggle(group.id) } label: {
                    Label("\(group.memberIDs.count) · \(store.expanded.contains(group.id) ? "Collapse" : "Expand")", systemImage: "rectangle.stack")
                        .font(.caption)
                }.buttonStyle(.borderless).disabled(store.busy)
            }
        }
    }

    /// 手动Reload任务由当前页面持有；离开或换号撤销，不生成持久后台请求。
    private func beginReload() {
        operation?.cancel(); operation = Task { await reload() }
    }

    /// 每次Reload取得绑定原仓库当前代际的facade；factory本身迟到也不能写入新账户UI。
    private func reload() async {
        let owner = media.management.generation
        do {
            let fresh = try await source.sceneStackReader()
            try Task.checkCancellation()
            guard owner == media.management.generation else { return }
            reader = fresh; loadedOwner = owner
            await store.reload(reader: fresh)
        } catch {
            guard owner == media.management.generation, !Task.isCancelled, !(error is CancellationError),
                  (error as? TimelineReadError) != .staleGeneration else { return }
            store.readerUnavailable()
        }
    }

    /// raw来自真实月份Picker；使用原facade，换号/端点或无读取器时不沿用旧月份。
    private func selectMonth(_ raw: String) {
        guard let reader, loadedOwner == media.management.generation else { return }
        operation?.cancel(); operation = Task { await store.select(.init(rawValue: raw), reader: reader) }
    }

    /// asset为当前完整月快照中的照片，viewer快照包括所有折叠成员，不写入canonical Index。
    private func open(_ asset: TimelineAssetSummary) {
        guard loadedOwner == media.management.generation else { return }
        let originals = store.assets
        let snapshot = NativeSearchSnapshot(assets: originals)
        let timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: originals.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: originals], groupedCatalogs: .init(), isComplete: true))
        selection = Selection(route: .init(selectedAsset: asset, initialAssets: originals,
                                           origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Scene photos")), timeline: timeline)
    }
}
