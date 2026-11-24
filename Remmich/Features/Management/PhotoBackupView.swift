import SwiftUI

/// 当前账号的持久前台备份入口；扫描与上传分开确认，离开前台只暂停，不删除手机或服务器资源。
struct PhotoBackupView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var backup = PhotoBackupController()
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
                        Button("读取手机相簿…") { Task { await backup.loadAlbums() } }
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
                        Button("扫描并保存所选相簿") { backup.scan(using: controller) }
                            .disabled(backup.selected.isEmpty || controller.client == nil || controller.busy)
                        Button("继续备份队列") {
                            retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                        }
                        .disabled(!backup.jobs.contains { [.queued, .paused, .failed].contains($0.stage) } || controller.client == nil || controller.busy)
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
                                        Button("取消任务", role: .destructive) { backup.cancelJob(job.id, using: controller) }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(controller.busy)
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
                    guard confirmationOwner == controller.generation else { return }
                    backup.resume(using: controller, jobID: retryID)
                }
            } message: {
                Text("使用扫描时保存的 iCloud 选项；需要更改时先重新扫描。成功回执仍会重新查重和核对配对；不自动重试未知结果。")
            }
            .task { await backup.load(using: controller) }
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
}
