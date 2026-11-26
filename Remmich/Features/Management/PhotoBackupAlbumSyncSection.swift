import SwiftUI

/// 明确已有/新建目标和增量补入入口；创建单独预览确认，未知结果不重POST，不镜像删除或冒充上传完成。
struct PhotoBackupAlbumSyncSection: View {
    let sync: PhotoBackupAlbumSyncController
    let manager: LibraryManagementController
    let backup: PhotoBackupController
    let automatic: PhotoBackupAlbumAutomation
    /// 两种写入共用一个确认宿主，避免并列confirmationDialog互相遮蔽；目标ID来自已保存预览。
    private enum Confirmation { case members, create(UUID) }
    @State private var confirmation: Confirmation?
    @State private var confirmationOwner: UUID?
    @State private var creationNames: [String: String] = [:]

    /// 草稿/忙门使创建与现有组织同样不可执行；保留停止入口，不禁用整个Section。
    private var creationBlocked: Bool {
        sync.loading || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan
    }

    /// 只检查当前包含映射；失效目标仍保留UUID标签供明确改选，不让Picker隐式退到同名第一项。
    private var unavailableTargets: Int {
        sync.state.mappings.count { mapping in
            backup.selected.contains(mapping.localAlbumID) && !sync.targets.contains { UUID(uuidString: $0.id) == mapping.targetID }
        }
    }

    var body: some View {
        Section("相簿同步 · 手动增量补入") {
            Toggle("自动相簿同步（本账户）", isOn: Binding(get: { automatic.enabled }, set: { value in Task { await automatic.setEnabled(value, using: manager) } }))
                .disabled(automatic.configuring || (!automatic.enabled && (manager.client == nil || backup.requiresSelectionScan || backup.running || backup.configuringAutomatic || sync.state.mappings.isEmpty)))
            Text(automatic.status).font(.footnote).foregroundStyle(.secondary)
            Text("默认关闭。开启后在前台，或已开启系统后台备份的有效租约内，将安全新项目补入已映射目标。使用保存包含/排除，不创建相簿，不重放未知/失败/取消项，不为组织上传或下载原片。")
                .font(.footnote).foregroundStyle(.secondary)
            Text(sync.status)
            Text("将当前包含且未排除的本地相簿，明确选择自有或具有编辑权限的共享相簿，或单独确认新建空相簿。只补入已确认照片的缺失成员关系；不上传、不从iCloud或Immich下载原片，不改名、不删除相簿/照片，也不自动移除成员。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("普通照片、视频及Live主体可用当前匹配，或同源完整备份记录的原片摘要；RAW+JPEG可用双回执，或本机可用且未编辑的双原图摘要分别核对已有服务器原图。未完整证明项目跳过，不转为上传，不为组织下载iCloud。")
                .font(.footnote).foregroundStyle(.secondary)
            if sync.running {
                ProgressView("已核对 \(sync.processed) 组，完整确认 \(sync.confirmed) 组")
                Button(L10n.string(automatic.enabled ? "停止并关闭自动相簿同步" : "停止相簿组织"), role: .destructive) {
                    sync.cancel()
                    if automatic.enabled || automatic.running {
                        Task { await automatic.setEnabled(false, using: manager) }
                    }
                }
            } else {
                if sync.loading {
                    ProgressView("读取当前目标")
                }
                if unavailableTargets > 0 {
                    Text("有 \(unavailableTargets) 个已保存目标当前不可用。请重新读取，或明确解除/改选映射；不会自动创建或选择其他相簿。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(backup.selected.sorted(), id: \.self) { localID in
                    Picker(sync.titles[localID] ?? backup.albums.first(where: { $0.id == localID })?.title ?? "手机相簿", selection: Binding<UUID?>(
                        get: { sync.state.mappings.first { $0.localAlbumID == localID }?.targetID },
                        set: { value in sync.setMapping(localID: localID, targetID: value, using: manager, backup: backup) }
                    )) {
                        Text("未映射").tag(UUID?.none)
                        ForEach(sync.targets) { album in
                            if let id = UUID(uuidString: album.id) {
                                Text("\(album.albumName) · \(album.id.prefix(8))").tag(Optional(id))
                            }
                        }
                        if let saved = sync.state.mappings.first(where: { $0.localAlbumID == localID }), !sync.targets.contains(where: { UUID(uuidString: $0.id) == saved.targetID }) {
                            Text("原目标不可用 · \(saved.targetName) · \(saved.targetID.uuidString.prefix(8))").tag(Optional(saved.targetID))
                        }
                    }
                    .disabled(sync.loading || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan)
                    creationControls(localID: localID)
                }
                Button("预览相簿补入计划") { sync.prepare(using: manager, backup: backup) }
                    .disabled(sync.loading || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan || sync.state.mappings.isEmpty || unavailableTargets > 0)
                if sync.prepared {
                    Text("本次最多 \(sync.previewCount) 个逻辑组，\(sync.unmatched) 项待匹配或待完整回执。Live Photo只加入主体；RAW+JPEG需两份原图均确认才算整组完成。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("确认并立即补入") { confirmationOwner = manager.generation; confirmation = .members }
                        .disabled(sync.previewCount == 0 || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan || unavailableTargets > 0)
                }
                if !sync.state.operations.isEmpty {
                    Text("已有记录：\(sync.state.operations.count { $0.phase == .confirmed }) 组已确认；\(sync.state.operations.count { $0.phase != .confirmed && !$0.confirmedAssetIDs.isEmpty }) 组保留部分确认。未知/中断项须重新预览核查。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("确认相簿操作？", isPresented: Binding(get: { confirmation != nil }, set: {
            if !$0 {
                confirmation = nil
            }
        }), titleVisibility: .visible, presenting: confirmation) { action in
            switch action {
            case .members:
                Button("补入并逐项核查") {
                    guard confirmationOwner == manager.generation else { return }
                    sync.synchronize(using: manager, backup: backup)
                }
            case let .create(id):
                Button("确认新建并映射") {
                    guard confirmationOwner == manager.generation else { return }
                    sync.createAndMap(id, using: manager, backup: backup)
                }
            }
        } message: { action in
            switch action {
            case .members:
                Text("最多核对 \(sync.previewCount) 个逻辑组。只使用已保存UUID目标；本次不会创建、改名或删除相簿/照片，中断保留待核查状态。")
            case let .create(id):
                Text("创建 ‘\(sync.state.creations.first { $0.id == id }?.name ?? "")’。即使已有同名相簿也会另建一本。原目标及照片保留；照片要另行预览补入。结果未知时不会重发创建。")
            }
        }
    }

    /// localID为已保存包含相簿；名称草稿只在本面板内，不改变备份/iCloud草稿，预览成功才保存创建意图。
    @ViewBuilder private func creationControls(localID: String) -> some View {
        if let intent = sync.state.creations.first(where: { $0.localAlbumID == localID && $0.unresolved }) {
            Text("待处理创建：\(intent.name)").font(.footnote)
            if intent.phase == .prepared {
                Button("确认创建新相簿…") { confirmationOwner = manager.generation; confirmation = .create(intent.id) }
                    .disabled(creationBlocked)
                Button("取消未发送的创建预览") { sync.abandonPreparedCreation(intent.id, using: manager, backup: backup) }
                    .disabled(creationBlocked)
            } else {
                Text(L10n.string(intent.receiptID == nil ? "创建结果未知。请只读核查后明确选择现有目标；同名不能证明是本次创建，不会再次发送POST。" : "已有本次201身份回执，需重新核实目标后完成映射，不会再次创建。"))
                    .font(.footnote).foregroundStyle(.secondary)
                Button("只读核查创建结果") { sync.recoverCreation(intent.id, using: manager, backup: backup) }
                    .disabled(creationBlocked)
            }
        } else {
            TextField("新相簿名（单独确认后创建）", text: Binding(get: { creationNames[localID] ?? sync.titles[localID] ?? "" }, set: { creationNames[localID] = $0 }))
                .disabled(creationBlocked)
            Button("预览创建新相簿并映射") {
                sync.prepareCreation(localID: localID, name: creationNames[localID] ?? sync.titles[localID] ?? "", using: manager, backup: backup)
            }
            .disabled(creationBlocked || (creationNames[localID] ?? sync.titles[localID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
