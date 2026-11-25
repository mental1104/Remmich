import SwiftUI

/// 已有相簿映射和明确补入入口；沿用备份Form，不创建相簿、不镜像删除，不把组织成功写成上传成功。
struct PhotoBackupAlbumSyncSection: View {
    let sync: PhotoBackupAlbumSyncController
    let manager: LibraryManagementController
    let backup: PhotoBackupController
    @State private var confirmsSync = false
    @State private var confirmationOwner: UUID?

    /// 只检查当前包含映射；失效目标仍保留UUID标签供明确改选，不让Picker隐式退到同名第一项。
    private var unavailableTargets: Int {
        sync.state.mappings.count { mapping in
            backup.selected.contains(mapping.localAlbumID) && !sync.targets.contains { UUID(uuidString: $0.id) == mapping.targetID }
        }
    }

    var body: some View {
        Section("相簿同步 · 手动增量补入") {
            Text(sync.status)
            Text("将当前包含且未排除的本地相簿，明确映射到已有自有相簿。只补入已确认照片的缺失成员关系；不上传或下载原片，不改名、不删除相簿/照片，也不自动移除成员。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("普通照片、视频及Live Photo主体需先开启本机照片匹配。RAW+JPEG需先具备两份完整原图回执；待匹配项目本次跳过，不会转为上传。")
                .font(.footnote).foregroundStyle(.secondary)
            if sync.running {
                ProgressView("已核对 \(sync.processed) 组，完整确认 \(sync.confirmed) 组")
                Button("停止相簿组织", role: .destructive) { sync.cancel() }
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
                }
                Button("预览相簿补入计划") { sync.prepare(using: manager, backup: backup) }
                    .disabled(sync.loading || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan || sync.state.mappings.isEmpty || unavailableTargets > 0)
                if sync.prepared {
                    Text("本次最多 \(sync.previewCount) 个逻辑组，\(sync.unmatched) 项待匹配或待完整回执。Live Photo只加入主体；RAW+JPEG需两份原图均确认才算整组完成。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("确认并立即补入") { confirmationOwner = manager.generation; confirmsSync = true }
                        .disabled(sync.previewCount == 0 || manager.busy || backup.running || backup.configuringAutomatic || backup.requiresSelectionScan || unavailableTargets > 0)
                }
                if !sync.state.operations.isEmpty {
                    Text("已有记录：\(sync.state.operations.count { $0.phase == .confirmed }) 组已确认；\(sync.state.operations.count { $0.phase != .confirmed && !$0.confirmedAssetIDs.isEmpty }) 组保留部分确认。未知/中断项须重新预览核查。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("向已明确选择的相簿补入当前缺失关系？", isPresented: $confirmsSync, titleVisibility: .visible) {
            Button("补入并逐项核查") {
                guard confirmationOwner == manager.generation else { return }
                sync.synchronize(using: manager, backup: backup)
            }
        } message: {
            Text("最多核对 \(sync.previewCount) 个逻辑组。名称相同也只使用已保存UUID目标；服务端已存在的匹配照片无需重新上传。不会创建、改名或删除任何相簿/照片。中断会保留待核查状态，不自动重发。")
        }
    }
}
