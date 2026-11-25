import SwiftUI

/// 单张资源的显式管理入口；元数据页独立fresh预检，媒体控制器只向可视编辑页提供未编辑预览。
struct AssetManagementView: View {
    let assetID: String
    let controller: LibraryManagementController
    let media: MediaLibraryController?
    let previewRevision: Date?
    let changed: () -> Void
    let editsChanged: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var asset: ManagedAsset?
    @State private var albums: [ManagedAlbum] = []
    @State private var membership: Set<String> = []
    @State private var caption = ""
    @State private var albumName = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var loading = true
    @State private var confirmsTrash = false
    @State private var confirmsReset = false
    @State private var editing = false
    @State private var managingMetadata = false
    @State private var managingTags = false

    /// assetID/controller保留原管理契约，media/revision来自查看器；editsChanged可区分需有限读取派生版本的编辑。
    /// 缺省媒体仍可管理但不盲保存可视编辑，缺省专用回调继续使用changed，保留原有管理宿主兼容。
    init(assetID: String, controller: LibraryManagementController, media: MediaLibraryController? = nil,
         previewRevision: Date? = nil, editsChanged: (() -> Void)? = nil, changed: @escaping () -> Void)
    {
        self.assetID = assetID
        self.controller = controller
        self.media = media
        self.previewRevision = previewRevision
        self.changed = changed
        self.editsChanged = editsChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView("读取服务器状态…")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let notice {
                    Section { Text(notice).foregroundStyle(.secondary) }
                }
                if let asset {
                    Section("照片管理") {
                        LabeledContent("文件", value: asset.originalFileName)
                        if asset.ownerId == controller.client?.userID {
                            Button("Date, location and rating") { managingMetadata = true }
                                .disabled(asset.isTrashed)
                            Button("Tags") { managingTags = true }
                                .disabled(asset.isTrashed)
                            Button(asset.isFavorite ? "取消收藏" : "收藏") {
                                run { try await $0.update(assetID, favorite: !asset.isFavorite) }
                            }
                            Button(asset.visibility == "archive" ? "移回时间线" : "归档") {
                                run { try await $0.update(assetID, visibility: asset.visibility == "archive" ? "timeline" : "archive") }
                            }
                            TextField("照片描述", text: $caption, axis: .vertical)
                            Button("保存描述") { run { try await $0.update(assetID, description: caption) } }
                            if asset.type == "IMAGE", asset.livePhotoVideoId == nil {
                                Button("无损编辑：旋转、镜像和裁剪") { editing = true }
                                Button("移除全部编辑，恢复原图") { confirmsReset = true }
                            }
                            if asset.isTrashed {
                                Button("从回收站恢复") { run { try await $0.restore(assetID) } }
                            } else {
                                Button("移入回收站", role: .destructive) { confirmsTrash = true }
                            }
                        } else {
                            Text("共享照片的写入操作由所有者权限控制。此处不提供修改。")
                        }
                    }
                    Section("加入相簿") {
                        ForEach(albums) { album in
                            if membership.contains(album.id) {
                                Button("从 \(album.albumName) 移除") { run { try await $0.performAlbumManagement(.remove(id: album.id, assetID: assetID)) } }
                            } else {
                                Button("加入 \(album.albumName)") { run { try await $0.performAlbumManagement(.add(id: album.id, assetID: assetID)) } }
                            }
                        }
                        TextField("新相簿名称", text: $albumName)
                        Button("创建相簿并加入此照片") {
                            let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                            run { _ = try await $0.createAlbum(name: name, assetID: assetID) }
                        }
                        .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .disabled(controller.busy)
            .navigationTitle("编辑与管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(controller.busy) } }
            .interactiveDismissDisabled(controller.busy)
            .task(id: controller.generation) { await load() }
            .onChange(of: controller.generation) { _, _ in dismiss() }
            .confirmationDialog("移入服务器回收站？", isPresented: $confirmsTrash, titleVisibility: .visible) {
                Button("移入回收站", role: .destructive) { run { try await $0.trash(assetID) } }
            } message: {
                Text("会影响所有客户端。回收站按服务器保留期限清理；这里不执行永久删除，也不删除手机原片。")
            }
            .confirmationDialog("清除已有的全部编辑？", isPresented: $confirmsReset, titleVisibility: .visible) {
                Button("恢复原图", role: .destructive) { run(isEditChange: true) { try await $0.resetEdits(assetID) } }
            } message: { Text("保留原始文件，移除服务器上的旋转、镜像和裁剪参数。") }
            .sheet(isPresented: $editing) {
                if let asset {
                    AssetEditingView(asset: asset, controller: controller, media: media, previewRevision: previewRevision) {
                        if let editsChanged {
                            editsChanged()
                        } else {
                            changed()
                        }
                        Task { await load() }
                    }
                }
            }
        }
        // 元数据页自行门控写入；挂在未禁用的NavigationStack上，确保保存中仍可点击停止等待。
        .sheet(isPresented: $managingMetadata, onDismiss: { Task { await load() } }) {
            AssetMetadataView(assetID: assetID, controller: controller, changed: changed)
        }
        .sheet(isPresented: $managingTags, onDismiss: { Task { await load() } }) {
            AssetTagManagementView(assetID: assetID, controller: controller, changed: changed)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = controller.client else { error = LibraryWriteError.unavailable.localizedDescription; return }
        let owner = controller.generation
        do {
            let fresh = try await client.asset(assetID)
            let availableAlbums = try await client.albums()
            let containing = try await client.albums(containing: assetID)
            guard owner == controller.generation, !Task.isCancelled else { return }
            asset = fresh
            caption = fresh.exifInfo?.description ?? ""
            albums = availableAlbums.filter { $0.access.allows(.assets, userID: client.userID) }
            membership = Set(containing.map(\.id))
            error = nil
        } catch {
            guard owner == controller.generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// isEditChange只区分需有限观察派生图的编辑，action仍走原有显式写通道；无专用回调时兼容旧changed入口。
    private func run(isEditChange: Bool = false, _ action: @escaping @Sendable (LibraryMutationClient) async throws -> Void) {
        error = nil
        notice = nil
        Task {
            do {
                try await controller.perform(action)
                if isEditChange, let editsChanged {
                    editsChanged()
                } else {
                    changed()
                }
                notice = "服务器已确认操作成功。"
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }
}
