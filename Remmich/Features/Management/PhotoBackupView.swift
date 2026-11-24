import SwiftUI

/// 当前账号的持久前台备份入口；扫描与上传分开确认，离开前台只暂停，不删除手机或服务器资源。
struct PhotoBackupView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var backup = PhotoBackupController()
    @State private var loadingQueue = false
    @State private var confirmsResume = false
    @State private var retryID: UUID?
    @State private var confirmationOwner: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("前台备份") {
                    Text(backup.status)
                    Text("队列及已确认回执按账户保存。离开页面、锁屏、切换账户或进入后台会停止；重新打开后需明确继续。不会删除或修改手机原片。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if backup.running {
                        ProgressView(value: Double(backup.completed + backup.failed), total: Double(max(1, backup.total)))
                        Button("停止并保存队列", role: .destructive) { backup.cancel() }
                    } else {
                        Button("重新读取备份队列") { Task { await reloadBackupQueue() } }
                            .disabled(loadingQueue || backup.running || controller.busy || controller.client == nil)
                        Button("读取手机相簿…") { Task { await backup.loadAlbums() } }
                            .disabled(backup.loadingAlbums || loadingQueue)
                        if loadingQueue {
                            ProgressView("正在读取备份队列")
                        }
                        if backup.loadingAlbums {
                            ProgressView("正在读取手机相簿")
                        }
                        Toggle("允许下载 iCloud 原片（可能使用移动数据）", isOn: $backup.allowCloud)
                        ForEach(backup.albums) { album in
                            Toggle(album.title, isOn: Binding(
                                get: { backup.selected.contains(album.id) },
                                set: {
                                    if $0 {
                                        backup.selected.insert(album.id)
                                    } else {
                                        backup.selected.remove(album.id)
                                    }
                                }
                            ))
                        }
                        unavailableSelections
                        exclusionChoices
                        Button("扫描并更新备份队列") { backup.scan(using: controller) }
                            .disabled(loadingQueue || !backup.hasLoadedAlbums || backup.loadingAlbums || backup.selected.isEmpty || controller.client == nil || controller.busy)
                        Button("继续备份队列") {
                            retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                        }
                        .disabled(loadingQueue || backup.requiresSelectionScan || !backup.jobs.contains { [.queued, .paused, .failed].contains($0.stage) } || controller.client == nil || controller.busy)
                    }
                }
                if !backup.running, !backup.jobs.isEmpty {
                    Section("当前账户队列（\(backup.jobs.count) 项）") {
                        ForEach(Array(backup.jobs.enumerated()), id: \.element.id) { index, job in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(index + 1) 项 · \(job.source.kind.rawValue) · \(job.stage.rawValue)")
                                if let reason = job.failure {
                                    Text(reason.message).font(.footnote).foregroundStyle(.secondary)
                                }
                                if [.queued, .paused, .failed].contains(job.stage) {
                                    HStack {
                                        Button("只重试这一项") {
                                            retryID = job.id; confirmationOwner = controller.generation; confirmsResume = true
                                        }
                                        .disabled(backup.requiresSelectionScan)
                                        Button("取消任务", role: .destructive) { backup.cancelJob(job.id, using: controller) }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(loadingQueue || controller.busy)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("照片备份")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { backup.cancel(); dismiss() } } }
            .confirmationDialog(retryID == nil ? "继续当前账户的备份队列？" : "只重试所选任务？", isPresented: $confirmsResume, titleVisibility: .visible) {
                Button("继续上传并查重") {
                    guard !loadingQueue, confirmationOwner == controller.generation else { return }
                    backup.resume(using: controller, jobID: retryID)
                }
            } message: {
                Text("使用最近扫描保存的相簿排除和 iCloud 选项；更改后需重新扫描。成功回执仍会重新查重和核对配对；不自动重试未知结果。")
            }
            .task { await reloadBackupQueue() }
            .onChange(of: controller.generation) { _, _ in backup.cancel(); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase == .background {
                    backup.cancel()
                }
            }
            .onDisappear { backup.cancel() }
        }
        .interactiveDismissDisabled(backup.running)
    }

    /// 首次打开和明确重读共用现有load；同页只允许一次读取，不与扫描/上传或管理写入重叠。
    /// 读取只恢复当前账户队列，不扫描或上传；失败保留现有资料，用户可以再次点击重读。
    @MainActor private func reloadBackupQueue() async {
        guard !loadingQueue, !backup.running, !controller.busy else { return }
        loadingQueue = true
        defer { loadingQueue = false }
        await backup.load(using: controller)
    }

    /// 只根据成功读取的当前授权列表判断缺项；按钮仅调整页面选择，下一次扫描前不能继续或重试旧队列。
    @ViewBuilder private var unavailableSelections: some View {
        let count = backup.unavailableAlbumIDs.count
        if count > 0 {
            Text("当前授权相簿列表中有 \(count) 个已保存或已选相簿不可用。可明确移除这些选择后重新扫描；不会删除照片。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("移除不可用的选择") { backup.removeUnavailableAlbumSelections() }
                .accessibilityIdentifier("backup-remove-unavailable-albums")
        }
        if backup.requiresSelectionScan {
            Text("相簿选择尚未保存。请先重新选择并扫描，之后才可继续备份。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 排除规则只在明确扫描保存后生效；与包含集合重叠时排除优先，已上传资源不会删除。
    private var exclusionChoices: some View {
        DisclosureGroup("排除相簿（扫描时应用）") {
            Text("排除优先于包含。扫描后，不再符合选择的待执行项会取消；已上传回执保留，不删除手机或服务器照片。相簿内容变化后需重新扫描。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(backup.albums) { album in
                Toggle(album.title, isOn: Binding(
                    get: { backup.excluded.contains(album.id) },
                    set: {
                        if $0 {
                            backup.excluded.insert(album.id)
                        } else {
                            backup.excluded.remove(album.id)
                        }
                    }
                ))
            }
        }
    }
}
