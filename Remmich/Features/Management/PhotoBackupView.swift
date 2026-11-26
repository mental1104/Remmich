import SwiftUI
import UniformTypeIdentifiers

/// 当前账号的持久前台备份入口；扫描与上传分开确认，离开前台只暂停，不删除手机或服务器资源。
struct PhotoBackupView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var backup: PhotoBackupController
    @State private var albumSync: PhotoBackupAlbumSyncController
    @State private var albumAutomation: PhotoBackupAlbumAutomation
    @State private var loadingQueue = false
    @State private var queueReadTask: Task<Void, Never>?
    @State private var confirmsResume = false
    @State private var retryID: UUID?
    @State private var resumesUnattempted = false
    @State private var confirmationOwner: UUID?
    @State private var importsHistory = false
    @State private var visibleJobs = 100

    /// controller提供当前鉴权通道，backup由Media统一持有，页面草稿/手动任务与前台自动化共享同一持久队列事实。
    /// albumSync/albumAutomation同由Media持有；页面只借用，关闭页面不能销毁正在运行的自动规则。
    init(controller: LibraryManagementController, backup: PhotoBackupController, albumSync: PhotoBackupAlbumSyncController, albumAutomation: PhotoBackupAlbumAutomation) {
        self.controller = controller
        _backup = State(initialValue: backup)
        _albumSync = State(initialValue: albumSync)
        _albumAutomation = State(initialValue: albumAutomation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("前台备份") {
                    Text(backup.status)
                    Text(backup.continuityStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("队列及回执按账户保存。手动备份离开本页会停止；前台自动备份进入后台会停止。系统后台备份须另行开启并等待 iOS 调度。不会删除或修改手机原片。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if backup.running {
                        ProgressView(value: Double(backup.processed), total: Double(max(1, backup.total)))
                        Button(backup.foregroundAutomaticEnabled || backup.backgroundAutomaticEnabled ? "停止并关闭自动备份" : "停止并保存队列", role: .destructive) {
                            Task { await backup.stopManually(using: controller) }
                        }
                    } else {
                        Button("导入 Immich 备份记录") { importsHistory = true }
                            .disabled(loadingQueue || backup.configuringAutomatic || controller.client == nil)
                        Button("重新读取备份队列") {
                            guard queueReadTask == nil else { return }
                            // 按钮创建的Task须随页面/账号退役取消，不能依赖SwiftUI只取消首次.task读取。
                            queueReadTask = Task {
                                await reloadBackupQueue()
                                queueReadTask = nil
                            }
                        }
                        .disabled(loadingQueue || backup.running || backup.configuringAutomatic || controller.busy || controller.client == nil)
                        Button("读取手机相簿…") { Task { await backup.loadAlbums() } }
                            .disabled(backup.loadingAlbums || loadingQueue)
                        if loadingQueue {
                            ProgressView("正在读取备份队列")
                        }
                        if backup.loadingAlbums {
                            ProgressView("正在读取手机相簿")
                        }
                        Toggle("前台自动备份（本账户）", isOn: Binding(
                            get: { backup.foregroundAutomaticEnabled },
                            set: { value in Task { await backup.setForegroundAutomaticEnabled(value, using: controller) } }
                        ))
                        .disabled(loadingQueue || backup.configuringAutomatic || controller.client == nil
                            || (!backup.foregroundAutomaticEnabled && (backup.requiresSelectionScan || backup.selected.isEmpty || controller.busy)))
                        Text("默认关闭。开启后只使用最近扫描保存的相簿、排除与 iCloud 选项；允许 iCloud 的已保存设置可能下载原片。默认仅处理安全的新项和未尝试项；连接失败重核须另行同意下方选项，其他失败、已尝试暂停及取消项仍需手动处理。手动停止会关闭并保存自动规则。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Toggle("网络恢复后核查连接失败项（本账户）", isOn: Binding(
                            get: { backup.foregroundNetworkRecoveryEnabled },
                            set: { value in Task { await backup.setForegroundNetworkRecoveryEnabled(value, using: controller) } }
                        ))
                        .disabled(loadingQueue || backup.configuringAutomatic || controller.client == nil
                            || (!backup.foregroundNetworkRecoveryEnabled && (!backup.foregroundAutomaticEnabled || backup.running
                                    || backup.requiresSelectionScan || controller.busy)))
                        Text("独立同意，默认关闭。仅前台新网络经服务器验证后，使用保存的相簿、排除和 iCloud 选项重核同版本连接失败项。已发送未知结果先重新导出、查重并核对回执，不直接重发；权限、源变化、取消和其他失败仍需手动处理，再次失败等待下一网络事件。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Toggle("允许下载 iCloud 原片（可能使用移动数据）", isOn: $backup.allowCloud)
                            .disabled(loadingQueue)
                        Toggle("系统后台备份（本账户）", isOn: Binding(
                            get: { backup.backgroundAutomaticEnabled },
                            set: { value in Task { await backup.setBackgroundAutomaticEnabled(value, using: controller) } }
                        ))
                        .disabled(loadingQueue || backup.configuringAutomatic || controller.client == nil
                            || (!backup.backgroundAutomaticEnabled && (backup.requiresSelectionScan || backup.selected.isEmpty || controller.busy)))
                        Text("默认关闭，独立于前台开关。iOS 可延后运行；后台只使用保存的相簿、排除和 iCloud 选项，失败或未知历史保持待核查。系统到期会暂停并保存回执。")
                            .font(.footnote).foregroundStyle(.secondary)
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
                            .disabled(loadingQueue)
                        }
                        unavailableSelections
                            .disabled(loadingQueue)
                        exclusionChoices
                            .disabled(loadingQueue)
                        Button("扫描并更新备份队列") { backup.scan(using: controller) }
                            .disabled(loadingQueue || backup.configuringAutomatic || !backup.hasLoadedAlbums || backup.loadingAlbums || backup.selected.isEmpty || controller.client == nil || controller.busy)
                        Button("继续备份队列") {
                            resumesUnattempted = false; retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                        }
                        .disabled(loadingQueue || backup.configuringAutomatic || backup.requiresSelectionScan || !backup.jobs.contains { [.queued, .paused, .failed].contains($0.stage) } || controller.client == nil || controller.busy)
                        Button("仅继续未尝试项目") {
                            resumesUnattempted = true; retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                        }
                        .disabled(loadingQueue || backup.configuringAutomatic || backup.requiresSelectionScan || backup.selected.isEmpty || backup.unattemptedSummary.eligibleJobIDs.isEmpty || controller.client == nil || controller.busy)
                        Text("可重新核对并继续最多 \(backup.unattemptedSummary.eligibleJobIDs.count) 项。跳过：失败 \(backup.unattemptedSummary.failed) 项、已尝试或回执待核查 \(backup.unattemptedSummary.attemptedOrUnconfirmed) 项、已取消 \(backup.unattemptedSummary.cancelled) 项、已完成 \(backup.unattemptedSummary.completed) 项。相簿权限及成员会先重新核对；失败或未知项可单独明确重试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                PhotoBackupAlbumSyncSection(sync: albumSync, manager: controller, backup: backup, automatic: albumAutomation)
                if !backup.running, !backup.jobs.isEmpty {
                    Section("当前账户队列（\(backup.jobs.count) 项）") {
                        ForEach(Array(backup.jobs.prefix(visibleJobs).enumerated()), id: \.element.id) { index, job in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(index + 1) 项 · \(job.source.kind.rawValue) · \(job.stage.rawValue)")
                                if let reason = job.failure {
                                    Text(reason.message).font(.footnote).foregroundStyle(.secondary)
                                }
                                if [.queued, .paused, .failed].contains(job.stage) {
                                    HStack {
                                        Button("只重试这一项") {
                                            resumesUnattempted = false; retryID = job.id; confirmationOwner = controller.generation; confirmsResume = true
                                        }
                                        .disabled(backup.requiresSelectionScan)
                                        Button("取消任务", role: .destructive) { backup.cancelJob(job.id, using: controller) }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(loadingQueue || backup.configuringAutomatic || controller.busy)
                                }
                            }
                        }
                        if visibleJobs < backup.jobs.count {
                            Button("显示后续任务") { visibleJobs += 100 }
                        }
                    }
                }
            }
            .navigationTitle("照片备份")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { backup.cancelPageWork(); dismiss() } } }
            .confirmationDialog(resumesUnattempted ? "仅继续未尝试项目？" : retryID == nil ? "继续当前账户的备份队列？" : "只重试所选任务？", isPresented: $confirmsResume, titleVisibility: .visible) {
                Button("继续上传并查重") {
                    guard !loadingQueue, confirmationOwner == controller.generation else { return }
                    if resumesUnattempted {
                        backup.resumeUnattempted(using: controller)
                    } else {
                        backup.resume(using: controller, jobID: retryID)
                    }
                }
            } message: {
                if resumesUnattempted {
                    Text("重新核对保存的包含/排除相簿及已有照片权限后，最多继续 \(backup.unattemptedSummary.eligibleJobIDs.count) 个从未尝试且没有部分回执的项目；iCloud 使用已保存选项。失败、已尝试未知、取消和完成项保持原状态，不会重新开启前台自动备份。")
                } else {
                    Text("使用最近扫描保存的相簿排除和 iCloud 选项；更改后需重新扫描。成功回执仍会重新查重和核对配对；不自动重试未知结果。")
                }
            }
            .task { await reloadBackupQueue() }
            .fileImporter(isPresented: $importsHistory, allowedContentTypes: [.database, .data]) { result in
                guard case let .success(url) = result else { return }
                Task { await backup.importHistory(from: url, using: controller) }
            }
            .onChange(of: controller.generation) { _, _ in
                queueReadTask?.cancel(); backup.cancelPageWork()
                // Media负责自动实例的账号退役；旧页面迟到的dismiss不能取消已接管新账号的自动任务。
                if !albumAutomation.running {
                    albumSync.cancel()
                }
                dismiss()
            }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    albumSync.cancel()
                    if phase != .background {
                        return
                    }
                    queueReadTask?.cancel()
                    backup.automaticConditionsChanged(using: controller, scope: controller.backupScope, active: false)
                    backup.cancel()
                }
            }
            .onDisappear {
                queueReadTask?.cancel(); backup.cancelPageWork(); if !albumAutomation.running {
                    albumSync.cancel()
                }
            }
        }
        .interactiveDismissDisabled(backup.running && !backup.automaticRunning)
    }

    /// 首次打开和明确重读共用现有load；同页只允许一次读取，不与扫描/上传或管理写入重叠。
    /// 读取只恢复当前账户队列，不扫描或上传；失败保留现有资料，用户可以再次点击重读。
    @MainActor private func reloadBackupQueue() async {
        guard !loadingQueue, !backup.running, !backup.configuringAutomatic, !controller.busy else { return }
        loadingQueue = true
        defer { loadingQueue = false }
        await backup.load(using: controller)
        await albumSync.load(using: controller, backup: backup)
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
