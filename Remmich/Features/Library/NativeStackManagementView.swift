import SwiftUI

/// Library可达的官方原生堆叠管理；浏览/缩略图复用Remmich，Fork场景叠栈不进入此页面。
struct NativeStackManagementView: View {
    let source: any NativeStackManaging
    let media: MediaLibraryController
    @State private var store = NativeStackManagementStore()
    @State private var selection: ManagedNativeStack?
    @State private var creating = false
    @State private var operation: Task<Void, Never>?
    @State private var loadedOwner: UUID?

    /// 独立列表表达式保留真实空状态/失败，缩小外层sheet与生命周期修饰链的类型检查范围。
    private var listContent: some View {
        List {
            Section {
                Text("Group your photos, change a stack's representative, or separate its members. Original photos are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                NativeStackStatus(store: store, reload: beginReload)
                Button("Create photo stack") { creating = true }
                    .disabled(store.busy || store.needsReload)
                    .accessibilityIdentifier("native-stacks-create")
            }
            Section("Photo stacks") {
                ForEach(store.stacks) { stack in
                    Button { selection = stack } label: {
                        HStack {
                            if let primary = stack.assets.first(where: { $0.id == stack.primaryAssetID }) {
                                NativeStackPhoto(asset: primary, media: media)
                            } else {
                                Image(systemName: "square.stack").frame(width: 52, height: 52)
                            }
                            VStack(alignment: .leading) {
                                Text("\(stack.assets.count) visible members").foregroundStyle(.primary)
                                if !stack.canManage {
                                    Text("Read-only").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(store.busy || store.needsReload)
                    .accessibilityIdentifier("native-stack-\(stack.id)")
                }
                if store.hasLoaded, store.stacks.isEmpty, store.error == nil {
                    Text("No photo stacks").foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        listContent
            .safeAreaInset(edge: .top, spacing: 0) {
                LibraryPageHeader(title: "Photo stacks") {
                    Button("Reload", action: beginReload).disabled(store.busy)
                }
            }
            .sheet(item: $selection) { stack in
                NavigationStack {
                    NativeStackDetailView(stack: stack, store: store, source: source, media: media,
                                          owner: loadedOwner, perform: perform, reload: beginReload)
                }
            }
            .sheet(isPresented: $creating) {
                NavigationStack {
                    NativeStackPickerView(existing: nil, store: store, source: source, media: media,
                                          owner: loadedOwner, perform: perform, reload: beginReload)
                }
            }
            .task(id: media.management.generation) {
                operation?.cancel(); operation = nil; selection = nil; creating = false
                store.invalidate(); loadedOwner = media.management.generation
                await store.reload(source: source)
            }
            .onChange(of: store.revision) { _, _ in selection = nil; creating = false }
            .onChange(of: store.mutationRevision) { _, _ in
                if let loadedOwner {
                    media.management.publishChanges(ifGeneration: loadedOwner)
                }
            }
            .onDisappear { operation?.cancel(); operation = nil; loadedOwner = nil; store.invalidate() }
            .accessibilityIdentifier("native-stacks-root")
    }

    /// 显式Reload只读取当前状态，不重发先前确认的POST/PUT/DELETE。
    private func beginReload() {
        run { await store.reload(source: source) }
    }

    /// change是确认时冻结的照片/主图/成员快照；实际写入由原仓库重新检查权限与代际。
    private func perform(_ change: NativeStackChange) {
        run { await store.perform(change, source: source) }
    }

    /// action由当前管理页持有；离开页面取消真实请求，账号/端点变化拒绝旧确认。
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard loadedOwner == media.management.generation else { store.invalidate(); return }
        operation?.cancel(); operation = Task { await action() }
    }
}

/// 详情只提供官方允许的非破坏性关系操作；两成员组须整体拆分，主图不能直接移出。
private struct NativeStackDetailView: View {
    let stack: ManagedNativeStack
    let store: NativeStackManagementStore
    let source: any NativeStackManaging
    let media: MediaLibraryController
    let owner: UUID?
    let perform: (NativeStackChange) -> Void
    let reload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pending: NativeStackChange?
    @State private var adding = false

    /// 成员列表只展示服务器可见项，关系操作始终先进入独立确认。
    private var listContent: some View {
        List {
            Section {
                NativeStackStatus(store: store, reload: reload)
                Text("Only visible, non-trashed members are listed. Stack-wide changes also affect any members omitted by the server.")
                    .font(.caption).foregroundStyle(.secondary)
                if !stack.canManage {
                    Text(NativeStackError.unavailableMembers.errorDescription ?? "Read-only")
                }
                Button("Add photos") { adding = true }.disabled(!canWrite)
                Button("Review dissolving stack", role: .destructive) { pending = .dissolve(stack) }
                    .disabled(!canWrite)
                    .accessibilityIdentifier("native-stack-dissolve")
            }
            Section("Members") {
                ForEach(stack.assets) { asset in
                    HStack(alignment: .top) {
                        NativeStackPhoto(asset: asset, media: media)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(asset.capturedAt, format: .dateTime.year().month().day().hour().minute())
                            if asset.id == stack.primaryAssetID {
                                Label("Representative", systemImage: "checkmark.seal").font(.caption)
                            } else {
                                Button("Review using as representative") { pending = .primary(stack, assetID: asset.id) }
                                    .disabled(!canWrite)
                                if stack.assets.count > 2 {
                                    Button("Review removing from stack") { pending = .remove(stack, assetID: asset.id) }
                                        .disabled(!canWrite)
                                }
                            }
                        }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    var body: some View {
        listContent
            .navigationTitle("Photo stack")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(store.busy) } }
            .interactiveDismissDisabled(store.busy)
            .sheet(isPresented: $adding) {
                NavigationStack {
                    NativeStackPickerView(existing: stack, store: store, source: source, media: media,
                                          owner: owner, perform: perform, reload: reload)
                }
            }
            .confirmationDialog("Confirm stack change", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible) {
                if let pending {
                    Button("Confirm", role: isDissolving ? .destructive : nil) { self.pending = nil; perform(pending) }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text(confirmationMessage) }
    }

    /// 可写性绑定当前账号代际和完整fresh加载；错误后旧详情只能查看及Reload。
    private var canWrite: Bool {
        stack.canManage && !store.busy && !store.needsReload && owner == media.management.generation
    }

    /// 拆分关系使用醒目的确认；其他操作不伪装成原片删除。
    private var isDissolving: Bool {
        if case .dissolve? = pending {
            return true
        }; return false
    }

    /// 文案说明官方动作与范围，不承诺无CAS接口能阻止同时发生的外部修改。
    private var confirmationMessage: String {
        switch pending {
        case .primary?: "Use the selected member as this stack's representative? Photos are kept."
        case .remove?: "Remove the selected member from this stack? It remains in your library."
        case .dissolve?: "Dissolve the entire stack, including any hidden or trashed members omitted from this list? Photos are kept."
        default: ""
        }
    }
}

/// 新建/追加从真实metadata分页选择未归组照片；确认前固定主图和ID顺序，不上传或删除任何照片。
private struct NativeStackPickerView: View {
    let existing: ManagedNativeStack?
    let store: NativeStackManagementStore
    let source: any NativeStackManaging
    let media: MediaLibraryController
    let owner: UUID?
    let perform: (NativeStackChange) -> Void
    let reload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates = NativeStackCandidateStore()
    @State private var selected: [String] = []
    @State private var representative = ""
    @State private var pending: NativeStackChange?
    @State private var loading: Task<Void, Never>?

    /// 分页照片列表和选择表单独立于sheet生命周期，避免大型SwiftUI类型推断表达式。
    private var listContent: some View {
        List {
            Section {
                NativeStackStatus(store: store, reload: reload)
                Text("Choose your own unstacked photos. More photos are available through the server's next page.")
                    .font(.caption).foregroundStyle(.secondary)
                if existing != nil {
                    Text("Adding creates a replacement stack with the current representative and all current non-trashed members, including hidden members. Trashed members lose their stack link. Other existing stacks are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Selected \(selected.count)")
                if existing == nil, !selected.isEmpty {
                    Picker("Representative", selection: $representative) {
                        ForEach(selected, id: \.self) { id in
                            if let asset = candidates.assets.first(where: { $0.id == id }) {
                                HStack {
                                    NativeStackPhoto(asset: asset, media: media)
                                    Text(asset.capturedAt, format: .dateTime.year().month().day().hour().minute())
                                }.tag(id)
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Button(existing == nil ? "Review creating stack" : "Review adding photos") {
                    let ordered = existing == nil ? [representative] + selected.filter { $0 != representative } : selected
                    pending = .create(assetIDs: ordered, addingTo: existing)
                }
                .disabled(!canConfirm)
                .accessibilityIdentifier("native-stack-review-selection")
            }
            Section("Available photos") {
                ForEach(candidates.assets) { asset in
                    Button { toggle(asset.id) } label: {
                        HStack {
                            NativeStackPhoto(asset: asset, media: media)
                            Text(asset.capturedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }.disabled(store.busy || store.needsReload)
                        .accessibilityIdentifier("native-stack-candidate-\(asset.id)")
                }
                if candidates.hasLoaded, candidates.assets.isEmpty, candidates.error == nil {
                    Text(candidates.continuation == nil ? "No available photos" : "No available photos on this page. Load more to continue.")
                        .foregroundStyle(.secondary)
                }
                if let error = candidates.error {
                    Text(L10n.string(error)).foregroundStyle(.red)
                }
                if candidates.busy {
                    ProgressView("Loading photos")
                }
                if !candidates.hasLoaded || candidates.continuation != nil {
                    Button(candidates.error == nil ? "Load more photos" : "Retry page", action: loadMore)
                        .disabled(candidates.busy || store.busy || store.needsReload)
                }
            }
        }
    }

    var body: some View {
        listContent
            .navigationTitle(existing == nil ? "Create photo stack" : "Add photos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
            .interactiveDismissDisabled(store.busy)
            .task(id: owner) {
                candidates.invalidate(); selected = []; representative = ""
                await candidates.loadMore(source: source, excluding: excludedIDs)
            }
            .onDisappear { loading?.cancel(); loading = nil; candidates.invalidate() }
            .confirmationDialog(existing == nil ? "Create this stack?" : "Add selected photos?", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible) {
                if let pending {
                    Button("Confirm") { self.pending = nil; perform(pending) }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(existing == nil ? "The selected representative becomes the first member. Selected photos remain in your library."
                    : "The server replaces this stack with a new stack containing its current non-trashed members and your selection. Trashed members lose their stack link. Photos are kept.")
            }
    }

    /// 本次快照所有已知堆叠成员都排除，服务端写前仍逐张验证没有新加入其他堆叠。
    private var excludedIDs: Set<String> {
        Set(store.stacks.flatMap { $0.assets.map(\.id) })
    }

    /// 当前账号已fresh加载且至少选中所需数量；新建必须保留一个真实已选主图。
    private var canConfirm: Bool {
        !store.busy && !store.needsReload && owner == media.management.generation
            && selected.count >= (existing == nil ? 2 : 1)
            && (existing != nil || selected.contains(representative))
    }

    /// id为已加载照片；切换选择保持点击顺序，取消主图时采用剩余首项而不使用随机Set顺序。
    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.removeAll { $0 == id }
        } else {
            selected.append(id)
        }
        if !selected.contains(representative) {
            representative = selected.first ?? ""
        }
    }

    /// 分页任务仅由当前选图页持有，关闭时取消，不预取整个图库。
    private func loadMore() {
        guard owner == media.management.generation else { candidates.invalidate(); return }
        loading?.cancel(); loading = Task { await candidates.loadMore(source: source, excluding: excludedIDs) }
    }
}

/// 共同显示明确busy/错误和只读Reload；不把网络失败呈现为空堆叠。
private struct NativeStackStatus: View {
    let store: NativeStackManagementStore
    let reload: () -> Void

    var body: some View {
        if store.busy {
            ProgressView("Contacting server")
        }
        if let error = store.error {
            Text(L10n.string(error)).foregroundStyle(.red).accessibilityIdentifier("native-stacks-error")
            Button("Reload stacks", action: reload).disabled(store.busy)
        }
        if let notice = store.notice {
            Text(notice).foregroundStyle(.secondary)
        }
    }
}

/// 真实缩略图沿用账户隔离缓存与鉴权，照片日期标签由调用者提供，不展示合成预览数据。
private struct NativeStackPhoto: View {
    let asset: TimelineAssetSummary
    let media: MediaLibraryController

    var body: some View {
        LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
            .frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
    }
}
