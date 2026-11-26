import SwiftUI

/// 当前照片标签与个人标签树的原生入口；关系变更和全局树变更分开确认，不向搜索候选写入状态。
struct AssetTagManagementView: View {
    let assetID: String
    let controller: LibraryManagementController
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AssetTagStore()
    @State private var selectedID = ""
    @State private var parentID = ""
    @State private var name = ""
    @State private var renameName = ""
    @State private var pending: AssetTagPlan?

    /// 选择必须来自当前fresh树；过期ID不会变成可直接发送的新标签。
    private var selected: ManagedTag? {
        store.state?.tags.first { $0.id == selectedID }
    }

    /// 排序只影响展示；domain的稳定ID顺序用于fresh预检比较。
    private var tags: [ManagedTag] {
        (store.state?.tags ?? []).sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    /// 所有权/回收站/fresh/写通道门控均满足才开放命令，最后权限仍由服务器决定。
    private var canWrite: Bool {
        store.hasFreshData && !store.isLoading && !store.isWorking && !controller.busy
            && store.state?.asset.ownerId.lowercased() == controller.client?.userID.lowercased()
            && store.state?.asset.isTrashed == false
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if let state = store.state {
                    currentSection(state)
                    createSection.disabled(!canWrite)
                    selectedSection.disabled(!canWrite)
                }
            }
            .navigationTitle("Tags")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(store.isWorking) } }
            .interactiveDismissDisabled(store.isWorking)
            .task(id: controller.generation) {
                let operation = store.reload(assetID: assetID, manager: controller)
                await operation?.value
            }
            .onChange(of: store.state) { _, _ in selectedID = ""; parentID = ""; name = ""; renameName = ""; pending = nil }
            .onChange(of: selectedID) { _, _ in renameName = selected?.name ?? ""; pending = nil }
            .onChange(of: store.confirmedChanges) { old, current in
                if current > old, store.savedAccountGeneration == controller.generation {
                    changed()
                }
            }
            .onChange(of: controller.generation) { _, _ in pending = nil; store.invalidate(manager: controller); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    store.cancel()
                }
            }
            .onDisappear { store.invalidate(manager: controller) }
            .confirmationDialog("Apply tag change?", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }),
            titleVisibility: .visible, presenting: pending) { plan in
                if case .delete = plan.command {
                    Button("Delete tag and descendants", role: .destructive) { store.start(plan, manager: controller); pending = nil }
                } else {
                    Button("Apply change") { store.start(plan, manager: controller); pending = nil }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { plan in Text(confirmationText(plan)) }
        }
    }

    /// 保存回执、未知结果与任务进度独立显示；重新加载必须真正访问当前服务器。
    private var statusSection: some View {
        Section {
            if let notice = store.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(L10n.string(error)).foregroundStyle(.red)
            }
            if store.isLoading {
                ProgressView("Loading current tags")
            }
            if store.isWorking {
                ProgressView("Checking and saving tags")
                Button("Stop waiting") { store.cancel() }
            }
            Button("Reload server tags") { pending = nil; store.reload(assetID: assetID, manager: controller) }
                .disabled(store.isLoading || store.isWorking)
        }
    }

    /// state仅来自fresh树和资源读取；展示照片真实标签，绝不把列表为空当成移除命令。
    private func currentSection(_ state: AssetTagState) -> some View {
        Section("Tags on this asset") {
            if state.asset.tags.isEmpty {
                Text("No tags").foregroundStyle(.secondary)
            }
            ForEach(state.asset.tags.sorted { $0.value < $1.value }) { tag in
                Text(tag.value).textSelection(.enabled)
            }
            if state.asset.ownerId.lowercased() != controller.client?.userID.lowercased() {
                Text("Only the owner can manage tags here.").foregroundStyle(.secondary)
            } else if state.asset.isTrashed {
                Text("Restore this asset before changing its tags.").foregroundStyle(.secondary)
            }
        }
    }

    /// 创建只提交一个叶名及显式父ID；不会通过斜线自动建多级路径，也不会创建后自动关联照片。
    private var createSection: some View {
        Section {
            TextField("One tag name", text: $name)
            Picker("Parent", selection: $parentID) {
                Text("Root").tag("")
                ForEach(tags) { tag in Text(tag.value).tag(tag.id) }
            }
            Button("Review create tag") { review(.create(name: name, parentID: parentID.isEmpty ? nil : parentID)) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: { Text("Create personal tag") } footer: {
            Text("Creation changes your tag tree. Attach the new tag to this asset separately. Use one name without a slash.")
        }
    }

    /// 关系操作只触及本照片；改名/删除作用于完整个人标签树，必须经不同的确认说明。
    private var selectedSection: some View {
        Section {
            Picker("Tag", selection: $selectedID) {
                Text("Choose a tag").tag("")
                ForEach(tags) { tag in Text(tag.value).tag(tag.id) }
            }
            if let selected, let state = store.state {
                let attached = state.asset.tags.contains { $0.id == selected.id }
                Text(selected.value).font(.footnote).foregroundStyle(.secondary)
                Button(attached ? "Review remove from this asset" : "Review add to this asset") {
                    review(attached ? .detach(tagID: selected.id) : .attach(tagID: selected.id))
                }
                TextField("New leaf name", text: $renameName)
                Button("Review rename tag") { review(.rename(tagID: selected.id, name: renameName)) }
                    .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameName == selected.name)
                AssetTagColorEditor(tag: selected) { review(.color(tagID: selected.id, change: $0)) }
                    .id(selected.id)
                Button("Review delete tag", role: .destructive) { review(.delete(tagID: selected.id)) }
            }
        } header: { Text("Manage existing tag") } footer: {
            Text("Renaming changes descendant paths. Deleting removes this tag, descendants and their links from all assets; photos and videos remain. Parent moves and tag colors are not edited here.")
        }
    }

    /// command来自明确按钮，prepare只生成固定确认，不发送网络；输入错误只显示本地说明。
    private func review(_ command: AssetTagCommand) {
        do { pending = try store.prepare(command, manager: controller) }
        catch { store.showError((error as? AssetTagError)?.errorDescription ?? "Reload tags before reviewing another change.") }
    }

    /// plan是审阅时固定树/命令；显示全局层级影响与单照片影响，避免把删除标签误读为取消关联。
    private func confirmationText(_ plan: AssetTagPlan) -> String {
        let state = plan.baseline
        switch plan.command {
        case let .create(name, parentID):
            let parent = state.tags.first { $0.id == parentID }
            return "Create \(parent.map { $0.value + "/" } ?? "")\(name.trimmingCharacters(in: .whitespacesAndNewlines)) in your personal tag tree. This does not attach it to the asset."
        case let .rename(id, name):
            let tag = state.tags.first { $0.id == id }
            return "Rename \(tag?.value ?? "tag") to leaf name \(name.trimmingCharacters(in: .whitespacesAndNewlines)). This changes \(state.subtree(id).count) known tag paths and their appearance on all affected assets. Photos remain."
        case let .color(id, change):
            let value = state.tags.first { $0.id == id }?.value ?? "tag"
            let effect = switch change { case .keep: "Keep the current color"; case .clear: "Clear the color"; case let .set(color): "Set the color to \(color.hex)" }
            return "\(effect) for \(value) everywhere. The name, hierarchy, other tag colors and photo relationships are kept."
        case let .delete(id):
            let tag = state.tags.first { $0.id == id }
            return "Delete \(tag?.value ?? "tag") and \(max(0, state.subtree(id).count - 1)) known descendants from your personal tag tree. Their links are removed from every affected asset. Photos and videos are kept."
        case let .attach(id): return "Attach \(state.tags.first { $0.id == id }?.value ?? "tag") only to this asset. Other tags remain."
        case let .detach(id): return "Remove \(state.tags.first { $0.id == id }?.value ?? "tag") only from this asset. The tag tree and other asset links remain."
        }
    }
}
