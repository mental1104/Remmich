import SwiftUI

/// 真实相簿成员的原生选择与批量管理页；所有动作先固定选择并确认，逐项保留回执。
struct BatchAssetManagementView: View {
    let album: BatchAlbumReference
    let ownedAlbums: [BatchAlbumReference]
    let factory: ManagementTimelineFactory
    let media: MediaLibraryController
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var scope: BatchAssetScope = .active
    @State private var store = BatchAssetManagementStore()
    @State private var pending: BatchAssetPlan?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(album.title).font(.headline)
                    Picker("Album items", selection: $scope) {
                        ForEach(BatchAssetScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(store.isWorking)
                    readControls
                    if let error = store.error {
                        Text(L10n.string(error)).foregroundStyle(.secondary)
                    }
                    if store.isWorking {
                        ProgressView(store.isStopping ? "Stopping" : "Applying selection")
                        Button("Stop sending remaining items", role: .destructive) { store.cancel() }
                            .disabled(store.isStopping)
                    }
                    if !store.hasFreshData, !store.isLoading, !store.results.isEmpty {
                        Text("Reload album photos to check the result before another operation.")
                            .font(.callout)
                    }
                    if store.hasFreshData {
                        actionControls
                    }
                    if store.assets.isEmpty, !store.isLoading {
                        ContentUnavailableView("No album items", systemImage: "photo.on.rectangle",
                                               description: Text("Reload or choose another album scope."))
                    }
                    assetGrid
                    if store.canLoadMore {
                        Button("Load more album photos") { _ = store.loadMore(manager: controller) }
                            .disabled(store.isLoading || store.isWorking)
                    }
                    if store.isLoading {
                        ProgressView("Loading album photos")
                    }
                    resultSummary
                }
                .padding()
            }
            .navigationTitle("Manage album photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(store.isWorking)
                }
            }
            .task(id: scope) { await reload() }
            .onChange(of: controller.generation) { _, _ in store.invalidate(); pending = nil; dismiss() }
            .onChange(of: scenePhase) {
                _, value in if value != .active {
                    store.cancel()
                }
            }
            .onDisappear { store.invalidate() }
            .confirmationDialog(pending?.action.title ?? "Apply selection?", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible, presenting: pending) { plan in
                Button(plan.action.title, role: plan.action.isDestructive ? .destructive : nil) {
                    _ = store.start(plan, manager: controller)
                }
                Button("Cancel", role: .cancel) {}
            } message: { plan in
                Text("Apply this action to \(plan.assets.count) selected items? Changes are visible in all clients. Items are handled separately; an unknown result stops the remaining requests. Photos are never permanently deleted.")
            }
        }
        .interactiveDismissDisabled(store.isWorking)
        .accessibilityIdentifier("batch-album-management")
    }

    /// 重载创建新的当前账号读源；此处不会直接复用持久索引队列中的完成响应。
    private func reload() async {
        guard let request = store.reload(album: album, scope: scope, factory: factory, manager: controller) else { return }
        await request.value
    }

    /// 只全选当前已加载的资源，清楚展示选择数量，不把未读取的整个相簿纳入写入。
    private var readControls: some View {
        HStack {
            Button("Reload") { Task { await reload() } }
                .disabled(store.isLoading || store.isWorking || controller.busy)
            Spacer()
            Text("\(store.selectedIDs.count) selected / \(store.assets.count) loaded").font(.caption)
            Menu("Selection") {
                Button("Select loaded items") { store.selectLoaded() }
                Button("Clear selection") { store.clearSelection() }
            }.disabled(!store.hasFreshData || store.isWorking)
        }
    }

    /// 动作只来自明确选择；封面限定单个正常成员，权限最终由现有服务端API裁决。
    private var actionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu("Actions for selected items") {
                if scope == .active {
                    Button("Favorite") { confirm(.favorite(true)) }
                    Button("Remove favorites") { confirm(.favorite(false)) }
                    Button("Archive") { confirm(.archived(true)) }
                    Button("Move back to timeline") { confirm(.archived(false)) }
                    Menu("Add to album") {
                        ForEach(ownedAlbums, id: \.id) { destination in
                            Button(destination.title) { confirm(.addToAlbum(destination)) }
                        }
                    }
                    Button("Remove from this album", role: .destructive) { confirm(.removeFromAlbum(album)) }
                    Button("Move to trash", role: .destructive) { confirm(.trash) }
                } else {
                    Button("Restore from trash") { confirm(.restore) }
                }
            }
            .disabled(store.selectedIDs.isEmpty || store.isLoading || store.isWorking || controller.busy)
            if scope == .active {
                Button("Use selected item as album cover") { confirm(.albumCover(album)) }
                    .disabled(store.selectedIDs.count != 1 || store.isLoading || store.isWorking || controller.busy)
                Text("Choose one current album member for its cover. Photo property changes require ownership; album permissions are checked by the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 使用已加载真实资产身份和缩略图版本，不猜测文件路径，不引入演示照片。
    private var assetGrid: some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 105, maximum: 180), spacing: 8)], spacing: 8) {
            ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
                Button {
                    store.select(asset.id, enabled: !store.selectedIDs.contains(asset.id))
                } label: {
                    ZStack(alignment: .topTrailing) {
                        LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
                            .aspectRatio(1, contentMode: .fit).clipped()
                            .overlay(alignment: .bottomLeading) { propertyBadges(asset).padding(5) }
                        Image(systemName: store.selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(store.selectedIDs.contains(asset.id) ? Color.accentColor : Color.white, Color.black.opacity(0.5))
                            .padding(6)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select item \(index + 1)")
                .accessibilityValue(selectionDescription(asset))
                .disabled(!store.hasFreshData || store.isWorking)
            }
        }
    }

    /// asset为本次真实读回的状态；重载后显示收藏/归档/视频标记，方便核对不确定写入。
    @ViewBuilder private func propertyBadges(_ asset: TimelineAssetSummary) -> some View {
        if asset.isFavorite || asset.visibility == .archive || asset.mediaKind == .video {
            HStack(spacing: 5) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
                if asset.visibility == .archive {
                    Image(systemName: "archivebox.fill")
                }
                if asset.mediaKind == .video {
                    Image(systemName: "video.fill")
                }
            }
            .font(.caption).foregroundStyle(.white).padding(5)
            .background(.black.opacity(0.6), in: Capsule())
            .accessibilityHidden(true)
        }
    }

    /// asset是已加载快照；返回选择状态及读回属性，不靠已发送意图推断服务器结果。
    private func selectionDescription(_ asset: TimelineAssetSummary) -> String {
        var parts = [store.selectedIDs.contains(asset.id) ? "Selected" : "Not selected"]
        if asset.isFavorite {
            parts.append("Favorite")
        }
        if asset.visibility == .archive {
            parts.append("Archived")
        }
        if asset.mediaKind == .video {
            parts.append("Video")
        }
        return parts.joined(separator: ", ")
    }

    /// 逐项回执保留成功/拒绝/未知和未发送的区别，停止后不把剩余选择伪装为失败或成功。
    @ViewBuilder private var resultSummary: some View {
        if !store.results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.operationTitle ?? "Last operation").font(.headline)
                Text("\(store.results.filter { $0.state == .succeeded }.count) confirmed / \(store.results.count) selected")
                    .font(.subheadline)
                ForEach(Array(store.results.enumerated()), id: \.element.id) { index, result in
                    HStack(alignment: .top, spacing: 10) {
                        LibraryAssetCover(assetID: result.id, revision: result.asset.thumbnailRevision, media: media)
                            .frame(width: 48, height: 48).clipped()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Selected item \(index + 1)").font(.caption)
                            Text(L10n.string(result.state.message)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// action在弹窗打开时固定完整选择，确认期间重载/换号后旧计划会被Store拒绝。
    private func confirm(_ action: BatchAssetAction) {
        do { pending = try store.prepare(action, manager: controller) }
        catch { store.showError(error.localizedDescription) }
    }
}
