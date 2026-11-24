import SwiftUI

struct AssetManagementView: View {
    let assetID: String
    let controller: LibraryManagementController
    let changed: () -> Void
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
                                Button("从 \(album.albumName) 移除") { run { try await $0.remove(assetID, from: album.id) } }
                            } else {
                                Button("加入 \(album.albumName)") { run { try await $0.add(assetID, to: album.id) } }
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
                Button("恢复原图", role: .destructive) { run { try await $0.resetEdits(assetID) } }
            } message: { Text("保留原始文件，移除服务器上的旋转、镜像和裁剪参数。") }
            .sheet(isPresented: $editing) {
                if let asset {
                    AssetEditingView(asset: asset, controller: controller) {
                        changed()
                        Task { await load() }
                    }
                }
            }
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
            albums = availableAlbums.filter { $0.ownerId == client.userID }
            membership = Set(containing.map(\.id))
            error = nil
        } catch {
            guard owner == controller.generation else { return }
            self.error = error.localizedDescription
        }
    }

    private func run(_ action: @escaping @Sendable (LibraryMutationClient) async throws -> Void) {
        error = nil
        notice = nil
        Task {
            do {
                try await controller.perform(action)
                changed()
                notice = "服务器已确认操作成功。"
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct AssetEditingView: View {
    let asset: ManagedAsset
    let controller: LibraryManagementController
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var angle = 0
    @State private var horizontal = false
    @State private var vertical = false
    @State private var crop = false
    @State private var x = "0"
    @State private var y = "0"
    @State private var width = ""
    @State private var height = ""
    @State private var error: String?
    @State private var loaded = false
    @State private var existing = AssetEditList(edits: [])
    @State private var confirmsSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("编辑参数同步到官方客户端；原始文件保持完整。此界面用像素指定裁剪范围，没有实时图像预览。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section("旋转与镜像") {
                    Picker("顺时针旋转", selection: $angle) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }
                    Toggle("水平镜像", isOn: $horizontal)
                    Toggle("垂直镜像", isOn: $vertical)
                }
                Section("裁剪原图（先裁剪，再旋转、镜像）") {
                    Toggle("裁剪", isOn: $crop)
                    if crop {
                        TextField("左上角 X", text: $x).keyboardType(.numberPad)
                        TextField("左上角 Y", text: $y).keyboardType(.numberPad)
                        TextField("宽度", text: $width).keyboardType(.numberPad)
                        TextField("高度", text: $height).keyboardType(.numberPad)
                    }
                }
                Button("保存无损编辑") { confirmsSave = true }
                    .disabled(!loaded || controller.busy)
            }
            .navigationTitle("无损编辑")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await load() }
            .onChange(of: controller.generation) { _, _ in dismiss() }
            .confirmationDialog("替换这张照片的编辑参数？", isPresented: $confirmsSave, titleVisibility: .visible) {
                Button("保存") { Task { await save() } }
            } message: { Text("保存会更新服务器上的全部编辑参数，所有客户端可见；原图不会覆盖。") }
        }
        .interactiveDismissDisabled(controller.busy)
    }

    private func load() async {
        guard let client = controller.client else { return }
        let owner = controller.generation
        do {
            let list = try await client.edits(asset.id)
            guard owner == controller.generation, !Task.isCancelled else { return }
            existing = list
            for edit in list.edits {
                switch edit.action {
                case "rotate": angle = edit.parameters.angle ?? 0
                case "mirror":
                    if edit.parameters.axis == "horizontal" {
                        horizontal = true
                    }
                    if edit.parameters.axis == "vertical" {
                        vertical = true
                    }
                case "crop":
                    crop = true
                    x = String(edit.parameters.x ?? 0); y = String(edit.parameters.y ?? 0)
                    width = String(edit.parameters.width ?? 0); height = String(edit.parameters.height ?? 0)
                default: throw LibraryWriteError.malformedResponse
                }
            }
            if width.isEmpty {
                width = asset.exifInfo?.exifImageWidth.map(String.init) ?? ""
            }
            if height.isEmpty {
                height = asset.exifInfo?.exifImageHeight.map(String.init) ?? ""
            }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        var edits: [AssetEditList.Edit] = []
        if crop {
            guard let left = Int(x), let top = Int(y), let w = Int(width), let h = Int(height),
                  left >= 0, top >= 0, w > 0, h > 0,
                  let originalW = asset.exifInfo?.exifImageWidth, let originalH = asset.exifInfo?.exifImageHeight,
                  left <= originalW, top <= originalH, w <= originalW - left, h <= originalH - top
            else {
                error = "裁剪范围必须在原图像素边界内；无尺寸信息时不提交裁剪。"; return
            }
            edits.append(.init(action: "crop", parameters: .init(x: left, y: top, width: w, height: h)))
        }
        if angle != 0 {
            edits.append(.init(action: "rotate", parameters: .init(angle: angle)))
        }
        if horizontal {
            edits.append(.init(action: "mirror", parameters: .init(axis: "horizontal")))
        }
        if vertical {
            edits.append(.init(action: "mirror", parameters: .init(axis: "vertical")))
        }
        let payload = AssetEditList(edits: edits)
        let previous = existing.edits
        do {
            try await controller.perform { client in
                // 编辑页打开后若其他客户端修改过参数，先拒绝覆盖，要求重新打开。
                guard try await client.edits(asset.id).edits == previous else { throw LibraryWriteError.changedAccount }
                if payload.edits.isEmpty {
                    try await client.resetEdits(asset.id)
                } else {
                    try await client.saveEdits(asset.id, payload)
                }
            }
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
