import SwiftUI
import UniformTypeIdentifiers

/// 当前账号的持久前台备份入口；扫描与上传分开确认，离开前台只暂停，不删除手机或服务器资源。
struct PhotoBackupView: View {
    let controller: LibraryManagementController
    let localMatches: LocalMediaMatchController?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var backup: PhotoBackupController
    @State private var albumSync: PhotoBackupAlbumSyncController
    @State private var albumAutomation: PhotoBackupAlbumAutomation
    @State private var loadingQueue = false
    @State private var queueReadTask: Task<Void, Never>?
    @State private var confirmsResume = false
    @State private var retryID: UUID?
    @State private var resumesUnattempted = false
    @State private var confirmationOwner: UUID?
    @State private var showsConfiguration = false
    @State private var importsHistory = false
    @State private var visibleJobs = 100

    /// controller提供当前鉴权通道，backup由Media统一持有，页面草稿/手动任务与前台自动化共享同一持久队列事实。
    /// albumSync/albumAutomation同由Media持有；页面只借用，关闭页面不能销毁正在运行的自动规则。
    init(controller: LibraryManagementController, backup: PhotoBackupController, albumSync: PhotoBackupAlbumSyncController, albumAutomation: PhotoBackupAlbumAutomation, localMatches: LocalMediaMatchController? = nil) {
        self.controller = controller
        self.localMatches = localMatches
        _backup = State(initialValue: backup)
        _albumSync = State(initialValue: albumSync)
        _albumAutomation = State(initialValue: albumAutomation)
    }

    /// 状态与常用操作优先显示；配置使用独立表单，避免把恢复说明和开关堆在任务列表前。
    var body: some View {
        let _ = locale.identifier
        NavigationStack {
            Form {
                if let localMatches, let reconciler = localMatches.fullLibraryReconciler {
                    fullLibrarySyncSection(localMatches, reconciler: reconciler)
                }
                Section("Original Backup") {
                    Label(statusTitle, systemImage: backup.running ? "arrow.triangle.2.circlepath" : "icloud")
                        .font(.headline)
                    Text(backup.status)
                    Text(backup.continuityStatus).font(.footnote).foregroundStyle(.secondary)
                    if backup.running {
                        if let fraction = backup.progressFraction {
                            ProgressView(value: fraction, total: 1)
                        } else {
                            ProgressView()
                        }
                    } else {
                        // 冷摘要只表示上次保存的累计结果；运行中的实时数值由上方进度文案发布。
                        LabeledContent("Matched on Server") { Text(backup.unattemptedSummary.matched, format: .number) }
                        LabeledContent("Uploaded or Matched") { Text(backup.unattemptedSummary.completed, format: .number) }
                        LabeledContent("Needs Review") { Text(backup.unattemptedSummary.failed + backup.unattemptedSummary.attemptedOrUnconfirmed, format: .number) }
                    }
                    if let localMatches, localMatches.recoveringCompletedAssociations {
                        ProgressView(value: Double(localMatches.scanned), total: Double(max(1, localMatches.total)))
                        Text(localMatches.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if backup.running {
                        Button(L10n.string(backup.foregroundAutomaticEnabled || backup.backgroundAutomaticEnabled ? "Stop & Disable Automatic Backup" : "Pause Backup"), role: .destructive) {
                            Task { await backup.stopManually(using: controller) }
                        }
                    } else {
                        Button { showsConfiguration = true } label: {
                            LabeledContent("Backup Source") { Text("Entire Photos Library") }
                        }
                        .accessibilityIdentifier("backup-settings-entry")
                        if loadingQueue {
                            ProgressView("Loading Backup Queue")
                        }
                        Button("Scan Library") { backup.scan(using: controller) }
                            .accessibilityIdentifier("backup-scan-library")
                            .disabled(loadingQueue || backup.configuringAutomatic || controller.client == nil || controller.busy)
                        Button("Back Up Originals") {
                            resumesUnattempted = false; retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                        }
                        .disabled(loadingQueue || backup.configuringAutomatic || backup.requiresSelectionScan || !backup.jobs.contains { [.queued, .paused, .failed].contains($0.stage) } || controller.client == nil || controller.busy)
                        DisclosureGroup("Recovery Options") {
                            Button("Continue Unattempted Items") {
                                resumesUnattempted = true; retryID = nil; confirmationOwner = controller.generation; confirmsResume = true
                            }
                            .disabled(loadingQueue || backup.configuringAutomatic || backup.requiresSelectionScan || backup.unattemptedSummary.eligibleJobIDs.isEmpty || controller.client == nil || controller.busy)
                            Text("Up to \(backup.unattemptedSummary.eligibleJobIDs.count) unattempted items can be rechecked against the latest library scan. Failed, uncertain, cancelled, and completed items keep their saved state.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Scan the entire authorized Photos library without uploading originals. Original backup starts only after your confirmation; saved progress and receipts are retained.")
                }
                if let localMatches, localMatches.fullLibraryReconciler == nil {
                    Section("本机照片优先") {
                        Toggle("自动匹配并优先使用本机照片", isOn: Binding(get: { localMatches.enabled }, set: {
                            localMatches.setEnabled($0, using: controller, followBackup: true)
                        }))
                        .disabled(backup.running)
                        Text("照片同步的已验证匹配同时用于本机浏览，无需单独扫描；未匹配的新照片继续查重后备份。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if localMatches.enabled {
                            Text(localMatches.status).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if !backup.running, !backup.jobs.isEmpty {
                    Section {
                        DisclosureGroup("Recent Tasks (\(backup.jobs.count))") {
                            ForEach(Array(backup.jobs.prefix(visibleJobs).enumerated()), id: \.element.id) { index, job in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("第 \(index + 1) 项 · \(kindTitle(for: job.source.kind)) · \(stateTitle(for: job))")
                                    if let reason = job.failure {
                                        Text(L10n.string(reason.message)).font(.footnote).foregroundStyle(.secondary)
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
            }
            .navigationTitle("Library Sync")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsConfiguration = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Backup Settings")
                        .disabled(backup.running)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { backup.cancelPageWork(); dismiss() } }
            }
            .sheet(isPresented: $showsConfiguration) { configurationView }
            .confirmationDialog(L10n.string(resumesUnattempted ? "Continue Unattempted Backups?" : retryID == nil ? "Start Original Backup?" : "Retry This Backup Item?"), isPresented: $confirmsResume, titleVisibility: .visible) {
                Button("Continue Original Backup") {
                    guard !loadingQueue, confirmationOwner == controller.generation else { return }
                    if resumesUnattempted {
                        backup.resumeUnattempted(using: controller)
                    } else {
                        backup.resume(using: controller, jobID: retryID)
                    }
                }
            } message: {
                if resumesUnattempted {
                    Text("Recheck Photos access and the saved library scan before continuing up to \(backup.unattemptedSummary.eligibleJobIDs.count) unattempted items. The saved iCloud option is used. Failed, uncertain, cancelled, and completed items are retained.")
                } else {
                    Text("Use the latest library scan and saved iCloud option. Existing receipts are rechecked; uncertain results are not retried automatically.")
                }
            }
            .task(id: controller.generation) {
                // 离线恢复过程中切换到在线通道会撤销旧读；等旧读退役后读取新代际，不能把累计进度留在0。
                do {
                    while loadingQueue {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    try Task.checkCancellation()
                    await reloadBackupQueue()
                } catch { /* 新代际或页面退役会取消等待，不重排队列。 */ }
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

    /// Full-library display identity counts come from the reconciler, independently of backup and timeline indexing.
    @ViewBuilder private func fullLibrarySyncSection(_ localMatches: LocalMediaMatchController, reconciler: LocalPhotoDisplayReconciler) -> some View {
        let progress = reconciler.progress
        let preparing = reconciler.state == .preparingMetadata || progress.phase == .readingMetadata
        Section {
            if localMatches.sourcePolicyReady {
                Toggle("自动匹配并优先使用本机照片", isOn: Binding(get: { localMatches.enabled }, set: {
                    localMatches.setEnabled($0, using: controller, followBackup: true)
                }))
                .accessibilityIdentifier("photo-sync-local-source-toggle")
                .disabled(backup.running)
            } else {
                ProgressView("Restoring Saved Photos Progress")
            }
            if localMatches.enabled, localMatches.sourcePolicyReady {
                Label(identityStatusTitle(reconciler.state), systemImage: identityStatusSymbol(reconciler.state))
                    .font(.headline)
                    .accessibilityIdentifier("photo-sync-local-status")
                Text(reconciler.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if preparing {
                    if reconciler.running, reconciler.state != .paused {
                        ProgressView("Preparing Photo Identities")
                    }
                    LabeledContent("Server Metadata Rows Read") { Text(progress.rawMetadataRows, format: .number) }
                        .accessibilityIdentifier("photo-sync-metadata-rows")
                    Text("The server identity dictionary is being read. Photo matching counts update after it is complete.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if progress.totalLocal > 0 {
                    ProgressView(value: Double(min(progress.processedLocal, progress.totalLocal)), total: Double(progress.totalLocal))
                        .accessibilityLabel("Photo Identity Matching Progress")
                        .accessibilityValue("\(progress.processedLocal) / \(progress.totalLocal)")
                        .accessibilityIdentifier("photo-sync-local-progress")
                }
                if progress.totalLocal > 0 || reconciler.state == .completed || reconciler.state == .needsReview {
                    LabeledContent("Authorized Photos Items") { Text(progress.totalLocal, format: .number) }
                        .accessibilityIdentifier("photo-sync-local-total")
                    LabeledContent("Photos Items Checked") { Text(progress.processedLocal, format: .number) }
                        .accessibilityIdentifier("photo-sync-local-processed")
                    LabeledContent("Photos Items Matched") { Text(progress.matchedLocal, format: .number) }
                        .accessibilityIdentifier("photo-sync-local-matched")
                    LabeledContent("Photos Items Unmatched") { Text(progress.unmatchedLocal, format: .number) }
                        .accessibilityIdentifier("photo-sync-local-unmatched")
                    LabeledContent("Photos Items Pending Review") { Text(progress.pendingLocal, format: .number) }
                        .accessibilityIdentifier("photo-sync-local-pending")
                } else {
                    Text("Restoring Saved Photos Progress")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = reconciler.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("photo-sync-local-error")
                }
                if reconciler.running {
                    if reconciler.state == .paused {
                        Button("Pausing Photos Matching…") {}
                            .disabled(true)
                    } else {
                        Button("Pause Photos Matching") { localMatches.pauseFullLibraryMatching() }
                            .accessibilityIdentifier("photo-sync-metadata-pause")
                    }
                } else {
                    Button("Sync Library") {
                        localMatches.resumeFullLibraryMatching(using: controller)
                    }
                    .accessibilityIdentifier("photo-sync-metadata-resume")
                    .disabled(controller.client == nil)
                }
            }
        } header: {
            Text("Library Sync")
        } footer: {
            Text("Local Photos items use Photos and iCloud as their source. This matching step reads metadata only; backup starts from your backup controls below.")
        }
    }

    private func identityStatusTitle(_ state: LocalPhotoDisplayReconcilerState) -> String {
        switch state {
        case .idle: L10n.string("Ready to Match Photos")
        case .preparingMetadata: L10n.string("Preparing Photo Identities")
        case .matching: L10n.string("Matching Photos")
        case .waiting: L10n.string("Waiting for the Server")
        case .paused: L10n.string("Photos Matching Paused")
        case .completed: L10n.string("All Photos Items Matched")
        case .needsReview: L10n.string("Photos Matching Needs Review")
        case .blocked: L10n.string("Photos Matching Unavailable")
        }
    }

    private func identityStatusSymbol(_ state: LocalPhotoDisplayReconcilerState) -> String {
        switch state {
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        case .needsReview, .blocked: "exclamationmark.circle"
        case .waiting: "wifi.exclamationmark"
        case .preparingMetadata, .matching: "arrow.triangle.2.circlepath"
        case .idle: "photo"
        }
    }

    /// 只根据已有队列摘要解释当前界面状态，不计算或改变任何上传许可。
    private var statusTitle: String {
        if backup.running {
            return L10n.string("Syncing")
        }
        if backup.requiresSelectionScan {
            return L10n.string("Scan Library First")
        }
        if backup.unattemptedSummary.failed > 0 {
            return L10n.string("Needs Review")
        }
        return L10n.string("Ready")
    }

    /// 全库来源固定；原片选项与相簿组织分别保存，不因打开设置启动扫描或上传。
    private var configurationView: some View {
        NavigationStack {
            Form {
                Section("Backup Source") {
                    Label("Entire Photos Library", systemImage: "photo.on.rectangle.angled")
                    Text("All photos and videos allowed by your current Photos permission are included. Album choices apply only to organization.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("允许下载 iCloud 原片（可能使用移动数据）", isOn: $backup.allowCloud)
                        .disabled(loadingQueue)
                } header: {
                    Text(verbatim: "iCloud")
                } footer: {
                    Text("This option applies only when you manually start original backup. Changing it requires another library scan; matching does not download originals.")
                }
                if backup.foregroundAutomaticEnabled || backup.backgroundAutomaticEnabled {
                    Section("Saved Automatic Backup Rule") {
                        Text("Library backup is manual. Stop any previously saved automatic backup rule before continuing.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Stop & Disable Automatic Backup", role: .destructive) {
                            Task { await backup.stopManually(using: controller) }
                        }
                        .disabled(loadingQueue || backup.configuringAutomatic)
                    }
                }
                Section("Advanced") {
                    Button("导入旧备份记录（可选）") { importsHistory = true }
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
                    NavigationLink("Album Organization") {
                        organizationView
                    }
                }
            }
            .navigationTitle("Backup Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsConfiguration = false } } }
            .fileImporter(isPresented: $importsHistory, allowedContentTypes: [.database, .data]) { result in
                guard case let .success(url) = result else { return }
                Task { await backup.importHistory(from: url, using: controller) }
            }
        }
    }

    private var organizationView: some View {
        Form {
            Section {
                Button("Read Photos Albums") { Task { await backup.loadAlbums() } }
                    .disabled(backup.loadingAlbums || loadingQueue || backup.running)
                if backup.loadingAlbums {
                    ProgressView("Loading Photos Albums")
                }
                ForEach(backup.albums) { album in
                    Toggle(album.title, isOn: Binding(
                        get: { backup.selected.contains(album.id) },
                        set: { value in
                            if value {
                                backup.selected.insert(album.id)
                            } else {
                                backup.selected.remove(album.id)
                            }
                        }
                    ))
                }
                unavailableSelections
                exclusionChoices
                Button("Save Organization Albums") {
                    Task { await backup.saveOrganizationSelection(using: controller) }
                }
                .disabled(!backup.requiresOrganizationSave || backup.requiresSelectionScan || backup.loadingAlbums || loadingQueue
                    || backup.running || backup.configuringAutomatic || controller.busy)
                if backup.requiresSelectionScan {
                    Text("Scan the library before saving organization albums. Scanning preserves your choices and does not start original backup.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if backup.requiresOrganizationSave {
                    Text("Save these album choices before previewing or changing album organization.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Organization Albums")
            } footer: {
                Text("These choices only organize albums. Library sync and the backup scan always include the entire authorized Photos library.")
            }
            .disabled(loadingQueue || backup.running || backup.configuringAutomatic)
            PhotoBackupAlbumSyncSection(sync: albumSync, manager: controller, backup: backup, automatic: albumAutomation)
        }
        .navigationTitle("Album Organization")
        .task {
            if !backup.hasLoadedAlbums {
                await backup.loadAlbums()
            }
        }
    }

    /// kind为稳定源类型，只返回用户可读名称，不更改任务中的序列化标识。
    private func kindTitle(for kind: PhotoBackupSource.Kind) -> String {
        switch kind {
        case .photo: L10n.string("Photo")
        case .video: L10n.string("Video")
        case .livePhoto: L10n.string("Live Photo")
        case .rawJPEG: L10n.string("RAW + JPEG")
        }
    }

    /// job为当前账号持久任务；仅转换本轮匹配/未确认状态，避免把匹配依据展示为一次上传成功。
    private func stateTitle(for job: PhotoBackupJob) -> String {
        if job.stage == .existing {
            return L10n.string("Matched on Server")
        }
        if job.failure == .historyNeedsReview || job.failure == .historyUnconfirmed {
            return L10n.string("Skipped — Backup Unconfirmed")
        }
        switch job.stage {
        case .queued: return L10n.string("Queued")
        case .exporting: return L10n.string("Preparing Original")
        case .uploadingMotion: return L10n.string("Uploading Live Photo Video")
        case .uploadingPrimary: return L10n.string("Uploading Original")
        case .verifying: return L10n.string("Verifying")
        case .paused: return L10n.string("Paused")
        case .failed: return L10n.string("Needs Review")
        case .cancelled: return L10n.string("Cancelled")
        case .completed: return L10n.string("Uploaded")
        case .existing: return L10n.string("Matched on Server")
        }
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

    /// 只根据成功读取的相簿列表判断组织选择缺项；不缩小全库扫描来源。
    @ViewBuilder private var unavailableSelections: some View {
        let count = backup.unavailableAlbumIDs.count
        if count > 0 {
            Text("\(count) selected organization albums are unavailable. You can remove these choices and save again; photos and backup history are retained.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Remove Unavailable Organization Albums") { backup.removeUnavailableAlbumSelections() }
                .accessibilityIdentifier("backup-remove-unavailable-albums")
        }
    }

    /// 排除仅限制相簿组织；保存后生效，不改变全库扫描或原片备份范围。
    private var exclusionChoices: some View {
        DisclosureGroup("Exclude Albums from Organization") {
            Text("Exclusions apply only to album organization. They do not remove photos from library sync or the backup scan.")
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
