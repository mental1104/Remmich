import Nuke
import SwiftUI
import UIKit

/// 以真实未编辑预览编辑官方参数；草稿仅在内存中，保存前重新核对源版本和其他客户端的编辑。
struct AssetEditingView: View {
    let asset: ManagedAsset
    let controller: LibraryManagementController
    let media: MediaLibraryController?
    let previewRevision: Date?
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: AssetEditDraft?
    @State private var initialDraft: AssetEditDraft?
    @State private var sourceImage: UIImage?
    @State private var sourceVersion: AssetEditSourceVersion?
    @State private var existing = AssetEditList(edits: [])
    @State private var loadedOwner: UUID?
    @State private var loading = true
    @State private var validSource = false
    @State private var forceReset = false
    @State private var showsOriginal = false
    @State private var cropFocusRequest = 0
    @State private var error: String?
    @State private var loadID = UUID()
    @State private var reloadID = 0
    @State private var verificationTask: Task<Void, Never>?
    @State private var confirmsSave = false
    @State private var confirmsDiscard = false
    @State private var confirmsReload = false

    /// 绑定资产、当前管理通道和媒体缓存；media/revision由原生查看器传入，缺少预览来源时不允许盲保存。
    init(asset: ManagedAsset, controller: LibraryManagementController, media: MediaLibraryController?,
         previewRevision: Date?, changed: @escaping () -> Void)
    {
        self.asset = asset
        self.controller = controller
        self.media = media
        self.previewRevision = previewRevision
        self.changed = changed
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("调整只保存为服务器编辑参数，所有客户端可见；不会覆盖原始照片。")
                            .font(.caption).foregroundStyle(.secondary)
                        if loading {
                            ProgressView("读取原图预览与编辑…")
                        }
                        if let error {
                            Text(error).foregroundStyle(.red).accessibilityIdentifier("asset-editor-error")
                            Button("重新读取") {
                                if hasChanges {
                                    confirmsReload = true
                                } else {
                                    reloadID += 1
                                }
                            }
                        }
                        if let sourceImage, let draft, validSource {
                            preview(sourceImage, draft: draft, size: geometry.size)
                            adjustmentControls(draft)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("无损编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if hasChanges {
                            confirmsDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction).disabled(controller.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { confirmsSave = true }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!canSave)
                        .accessibilityIdentifier("asset-editor-save")
                }
            }
            .task(id: LoadKey(assetID: asset.id, owner: controller.generation, reload: reloadID)) { await load() }
            .onChange(of: controller.generation) { _, _ in invalidate(); dismiss() }
            .onChange(of: previewRevision) { _, _ in
                loadID = UUID()
                loading = false
                verificationTask?.cancel()
                validSource = false
                sourceImage = nil
                error = AssetVisualEditingError.changedSource.localizedDescription
            }
            .onChange(of: scenePhase) { _, next in
                verificationTask?.cancel()
                if next == .active, validSource {
                    verificationTask = Task { await verifyCurrentSource() }
                }
            }
            .onDisappear { verificationTask?.cancel(); verificationTask = nil; loadID = UUID(); invalidate() }
            .confirmationDialog("替换这张照片的编辑参数？", isPresented: $confirmsSave, titleVisibility: .visible) {
                Button("保存无损编辑") { Task { await save() } }
            } message: { Text("原图保持完整。保存前会重新检查照片版本和编辑；失败后先重新读取，不自动重发。") }
            .confirmationDialog("放弃尚未保存的调整？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("放弃调整", role: .destructive) { dismiss() }
            }
            .confirmationDialog("重新读取并放弃当前草稿？", isPresented: $confirmsReload, titleVisibility: .visible) {
                Button("重新读取", role: .destructive) { reloadID += 1 }
            }
        }
        .interactiveDismissDisabled(controller.busy || hasChanges)
        .accessibilityIdentifier("asset-editor-root")
    }

    /// 读取任务身份包含资源、管理代际和显式重载计数；版本变更只禁用旧草稿，不静默丢弃用户调整。
    private nonisolated struct LoadKey: Hashable, Sendable { let assetID: String; let owner: UUID; let reload: Int }

    /// 只有真实像素已加载且仍属于当前账号的有效草稿才可交互。
    private var canEdit: Bool {
        validSource && !loading && !controller.busy && loadedOwner == controller.generation
    }

    /// 与载入时草稿比较；显式清除已有的无效果参数也算用户确认过的重置意图。
    private var hasChanges: Bool {
        forceReset || (draft != nil && draft != initialDraft)
    }

    /// 保存要求真实预览、当前代际和有效改动；仅有参数或失败旧预览不能提交。
    private var canSave: Bool {
        canEdit && sourceImage != nil && hasChanges
    }

    /// 键盘入口只属于当前活跃、有效且没有确认弹层的裁剪页，不让背后控件接管其他页面输入。
    private var canFocusCrop: Bool {
        canEdit && draft?.crop != nil && scenePhase == .active && !confirmsSave && !confirmsDiscard && !confirmsReload
    }

    /// image为同版本未编辑预览，draft为原图像素草稿；宽窗口并排取景和结果，小窗口上下排列。
    private func preview(_ image: UIImage, draft: AssetEditDraft, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("原图 / 结果", value: "\(draft.sourceSize.width)×\(draft.sourceSize.height) / \(draft.outputSize.width)×\(draft.outputSize.height)")
                .font(.caption).monospacedDigit()
            Picker("预览", selection: $showsOriginal) {
                Text("调整结果").tag(false)
                Text("原图对照").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("asset-editor-comparison")
            if draft.crop != nil {
                let horizontal = size.width >= 760 && !dynamicTypeSize.isAccessibilitySize
                let layout = horizontal ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                let canvasHeight = horizontal ? min(440, max(260, size.height * 0.6)) : min(340, max(220, size.height * 0.42))
                let resultHeight = horizontal ? canvasHeight : min(300, max(180, size.height * 0.32))
                // 只换布局策略，不换Canvas结构身份，窗口/Dynamic Type变化保留焦点、手势和当前草稿。
                layout {
                    cropCanvas(image, draft: draft).frame(maxWidth: .infinity).frame(height: canvasHeight)
                    resultPreview(image, draft: draft).frame(maxWidth: .infinity).frame(height: resultHeight)
                }
                Text("拖动选框或四角，双指捏合调整取景范围。左侧／上方选框使用原图坐标，先裁剪再应用旋转与镜像。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("点击选框后可用方向键移动；Shift 每次十像素，Option 调整宽高。也可展开精确像素调整。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                resultPreview(image, draft: draft).frame(height: min(500, max(240, size.height * 0.6)))
            }
        }
    }

    /// 只在已开启裁剪时绑定区域；旧手势在账号失效后不能重新写入草稿。
    private func cropCanvas(_ image: UIImage, draft: AssetEditDraft) -> some View {
        AssetEditCropCanvas(image: image, sourceSize: draft.sourceSize,
                            crop: Binding(get: { self.draft?.crop ?? .full(draft.sourceSize) }, set: { value in edit { $0.crop = value } }),
                            focusRequest: cropFocusRequest)
            .clipShape(RoundedRectangle(cornerRadius: 12)).disabled(!canFocusCrop)
    }

    /// 显示原图或当前结果；同一像素源用于对照，不请求另一份可能过期的已编辑缩略图。
    private func resultPreview(_ image: UIImage, draft: AssetEditDraft) -> some View {
        AssetEditResultPreview(image: image, draft: draft, showsOriginal: showsOriginal)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// draft为当前尺寸及区域；原生按钮支持指针，取消/保存提供键盘快捷键，Stepper允许精确一像素调整。
    private func adjustmentControls(_ draft: AssetEditDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [.init(.adaptive(minimum: 56, maximum: 72), spacing: 12)], alignment: .leading, spacing: 12) {
                Button("向左旋转", systemImage: "rotate.left") { edit { $0.transform = $0.transform.rotated(clockwise: 270) } }
                    .keyboardShortcut("[", modifiers: .command)
                Button("向右旋转", systemImage: "rotate.right") { edit { $0.transform = $0.transform.rotated(clockwise: 90) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("水平镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { edit { $0.transform = $0.transform.mirrored(horizontal: true) } }
                Button("垂直镜像", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { edit { $0.transform = $0.transform.mirrored(horizontal: false) } }
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
            Toggle("裁剪", isOn: Binding(get: { self.draft?.crop != nil }, set: { enabled in edit { $0.crop = enabled ? .full($0.sourceSize) : nil } }))
                .accessibilityIdentifier("asset-editor-crop-toggle")
            if let crop = draft.crop {
                Button("用键盘调整裁剪", systemImage: "keyboard") {
                    guard canFocusCrop else { return }
                    cropFocusRequest &+= 1
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .buttonStyle(.bordered).hoverEffect(.highlight)
                .disabled(!canFocusCrop)
                .accessibilityHint("Command-Option-K focuses the crop. Arrow keys move; Shift changes ten pixels; Option resizes.")
                DisclosureGroup("精确像素调整") {
                    VStack(spacing: 10) {
                        Stepper("X：\(crop.x)", value: cropBinding(.x), in: 0 ... (draft.sourceSize.width - crop.width))
                        Stepper("Y：\(crop.y)", value: cropBinding(.y), in: 0 ... (draft.sourceSize.height - crop.height))
                        Stepper("宽：\(crop.width)", value: cropBinding(.width), in: 1 ... (draft.sourceSize.width - crop.x))
                        Stepper("高：\(crop.height)", value: cropBinding(.height), in: 1 ... (draft.sourceSize.height - crop.y))
                        Button("恢复完整裁剪范围") { edit { $0.crop = .full($0.sourceSize) } }
                    }.monospacedDigit()
                }
            }
            Button("清除本页全部调整") {
                guard canEdit else { return }
                self.draft = AssetEditDraft(size: draft.sourceSize)
                forceReset = !existing.edits.isEmpty
            }
        }.disabled(!canEdit)
    }

    /// 精确像素输入可修改的四个分量，不把显示点数传入服务端参数。
    private enum CropField { case x, y, width, height }

    /// field选择一个像素分量；Stepper范围保证单次修改仍在边界内，最终构造再次校验。
    private func cropBinding(_ field: CropField) -> Binding<Int> {
        Binding(get: {
            guard let crop = draft?.crop else { return 0 }
            return switch field { case .x: crop.x; case .y: crop.y; case .width: crop.width; case .height: crop.height }
        }, set: { value in
            edit { draft in
                guard let crop = draft.crop else { return }
                draft.crop = AssetEditPixelCrop(x: field == .x ? value : crop.x, y: field == .y ? value : crop.y,
                                                width: field == .width ? value : crop.width, height: field == .height ? value : crop.height,
                                                in: draft.sourceSize) ?? crop
            }
        })
    }

    /// action仅改变本页值类型草稿；旧上下文、加载中或写入中拒绝手势，不触发网络或修改照片。
    private func edit(_ action: (inout AssetEditDraft) -> Void) {
        guard canEdit, var value = draft else { return }
        action(&value)
        draft = value
    }

    /// 固定当前账号、源版本和完整编辑，再获取同版本的未编辑有限预览；任一步失败都禁止盲保存。
    private func load() async {
        let requestID = UUID()
        loadID = requestID
        invalidate()
        loading = true
        error = nil
        let owner = controller.generation
        defer {
            if loadID == requestID {
                loading = false
            }
        }
        do {
            guard let client = controller.client, client.userID == asset.ownerId,
                  let media, let pipeline = media.pipeline else { throw AssetVisualEditingError.previewUnavailable }
            let fresh = try await client.asset(asset.id)
            let version = try Self.sourceVersion(fresh, userID: client.userID)
            let list = try await client.edits(asset.id)
            let value = try AssetEditDraft(size: version.size, list: list)
            try Task.checkCancellation()
            guard owner == controller.generation, requestID == loadID else { return }
            guard let request = media.uneditedEditorPreviewRequest(assetID: asset.id,
                                                                   revision: previewRevision ?? Date(timeIntervalSince1970: 0),
                                                                   sourceVersion: version.previewCacheVersion,
                                                                   targetPixels: .init(width: 2048, height: 2048)) else { throw AssetVisualEditingError.previewUnavailable }
            let response = try await pipeline.imageTask(with: request).response
            let image = try AssetEditPreviewImage.normalized(response.image, for: version.size)
            let confirmed = try await client.asset(asset.id)
            guard try Self.sourceVersion(confirmed, userID: client.userID) == version else { throw AssetVisualEditingError.changedSource }
            guard try await client.edits(asset.id).edits == list.edits else { throw AssetVisualEditingError.changedEdits }
            try Task.checkCancellation()
            guard owner == controller.generation, requestID == loadID else { return }
            sourceVersion = version
            existing = list
            draft = value
            initialDraft = value
            sourceImage = image
            loadedOwner = owner
            validSource = true
        } catch {
            guard owner == controller.generation, requestID == loadID, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// 前台恢复时重验资源和编辑；只检测失效，不自动覆盖用户草稿或重发写入。
    private func verifyCurrentSource() async {
        guard let expected = sourceVersion, let client = controller.client, let owner = loadedOwner else { return }
        let requestID = loadID
        do {
            let fresh = try await client.asset(asset.id)
            guard try Self.sourceVersion(fresh, userID: client.userID) == expected else { throw AssetVisualEditingError.changedSource }
            guard try await client.edits(asset.id).edits == existing.edits else { throw AssetVisualEditingError.changedEdits }
            try Task.checkCancellation()
        } catch {
            guard owner == controller.generation, requestID == loadID, !Task.isCancelled else { return }
            validSource = false
            sourceImage = nil
            self.error = error.localizedDescription
        }
    }

    /// 点击确认时固定全部参数；先重读源和编辑再调用官方精确状态码接口，不覆盖原图或自动重试。
    private func save() async {
        guard canSave, let draft, let expected = sourceVersion, let owner = loadedOwner else { return }
        let payload = draft.payload
        let previous = existing.edits
        do {
            try await controller.perform { client in
                let fresh = try await client.asset(expected.assetID)
                guard try Self.sourceVersion(fresh, userID: client.userID) == expected else { throw AssetVisualEditingError.changedSource }
                guard try await client.edits(expected.assetID).edits == previous else { throw AssetVisualEditingError.changedEdits }
                if payload.edits.isEmpty {
                    try await client.resetEdits(expected.assetID)
                } else {
                    try await client.saveEdits(expected.assetID, payload)
                }
            }
            guard owner == controller.generation else { return }
            changed()
            dismiss()
        } catch {
            guard owner == controller.generation else { return }
            // 网络失败可能发生在服务端已接受参数之后；先重读再操作，不能连续重放未知结果的写入。
            validSource = false
            sourceImage = nil
            self.error = error.localizedDescription
        }
    }

    /// 清除旧像素和可提交状态；草稿只在显式重新读取或退出账号时丢弃。
    private func invalidate() {
        validSource = false
        sourceImage = nil
        sourceVersion = nil
        draft = nil
        initialDraft = nil
        loadedOwner = nil
        forceReset = false
    }

    /// asset为同次真实读取响应，userID为当前通道身份；返回官方尺寸与不透明版本，拒绝不支持的媒体。
    nonisolated static func sourceVersion(_ asset: ManagedAsset, userID: String) throws -> AssetEditSourceVersion {
        let suffix = (asset.originalFileName as NSString).pathExtension.lowercased()
        guard asset.ownerId == userID, asset.type == "IMAGE", asset.livePhotoVideoId == nil,
              asset.projectionType != "EQUIRECTANGULAR", !["gif", "svg", "insp"].contains(suffix)
        else { throw AssetVisualEditingError.unsupportedMedia }
        guard let size = AssetEditPixelSize(exifWidth: asset.exifInfo?.exifImageWidth, exifHeight: asset.exifInfo?.exifImageHeight,
                                            orientation: asset.exifInfo?.orientation) else { throw AssetVisualEditingError.invalidDimensions }
        return try AssetEditSourceVersion(assetID: asset.id, ownerID: asset.ownerId, checksum: asset.checksum,
                                          updatedAt: asset.updatedAt, originalFileName: asset.originalFileName, size: size)
    }
}
