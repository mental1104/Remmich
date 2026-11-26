import SwiftUI

/// 当前账户的具名搜索入口；完整替换和删除登记需确认，不涉及照片写入。
struct SearchPresetsPanel: View {
    @Binding var query: NativeSearchQuery
    let manager: LibraryManagementController
    @State private var store = NativeSearchPresetStore()
    @State private var name = ""
    @State private var editing: NativeSearchPreset?
    @State private var pending: Pending?
    @State private var conversionError: String?

    /// 固定确认时的目标及查询，避免等待确认期间条件变化造成写错内容。
    private enum Pending {
        case replace(NativeSearchPreset, NativeSearchQuery)
        case remove(NativeSearchPreset)
    }

    var body: some View {
        DisclosureGroup("Saved searches") {
            VStack(alignment: .leading, spacing: 12) {
                Button(store.busy ? "Loading" : "Reload saved searches") { Task { conversionError = nil; await store.load(manager: manager) } }
                    .disabled(store.busy)
                    .accessibilityIdentifier("saved-search-reload")
                if store.supported == false {
                    Text("This server does not provide saved searches.").font(.caption)
                }
                if store.supported == true {
                    TextField("Search name", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("saved-search-name")
                    HStack {
                        Button(editing == nil ? "Save current search" : "Save name") { Task { await save() } }
                            .disabled(store.busy || !store.hasFreshData || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("saved-search-save")
                        if editing != nil {
                            Button("Cancel rename") { editing = nil; name = "" }
                        }
                    }
                    ForEach(store.presets) { preset in
                        HStack {
                            Button(preset.name) { apply(preset) }
                                .accessibilityHint("Apply all saved search conditions")
                                .accessibilityIdentifier("saved-search-apply-\(preset.id)")
                            Spacer()
                            Menu {
                                Button("Rename") { editing = preset; name = preset.name }
                                Button("Replace with current conditions") { conversionError = nil; pending = .replace(preset, query) }
                                Button("Delete saved search", role: .destructive) { conversionError = nil; pending = .remove(preset) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }.accessibilityLabel("Manage \(preset.name)")
                                .accessibilityIdentifier("saved-search-manage-\(preset.id)")
                        }.disabled(store.busy || !store.hasFreshData)
                    }
                }
                if let error = conversionError ?? store.error {
                    Text(L10n.string(error)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("saved-search-error")
                }
            }
        }
        .onChange(of: manager.generation) { _, _ in
            store.invalidate()
            name = ""
            editing = nil
            pending = nil
            conversionError = nil
        }
        .confirmationDialog("Change saved search?", isPresented: Binding(get: { pending != nil }, set: {
            if !$0 {
                pending = nil
            }
        }), presenting: pending) { action in
            switch action {
            case let .replace(preset, snapshot):
                Button("Replace all conditions", role: .destructive) { Task { _ = await store.replace(preset, query: snapshot, manager: manager) } }
                    .accessibilityIdentifier("saved-search-confirm-replace")
            case let .remove(preset):
                Button("Delete saved search", role: .destructive) { Task {
                    if await store.remove(preset, manager: manager), editing?.id == preset.id {
                        editing = nil
                        name = ""
                    }
                } }
                .accessibilityIdentifier("saved-search-confirm-delete")
            }
        } message: { action in
            switch action {
            case let .replace(preset, _): Text("Replace all conditions in ‘\(preset.name)’ with the current search?")
            case let .remove(preset): Text("Delete ‘\(preset.name)’? Photos will be kept.")
            }
        }
    }

    /// preset为选中的完整登记；转换成功才一次性替换查询，失败保留原查询。
    private func apply(_ preset: NativeSearchPreset) {
        do {
            let restored = try NativeSearchPresetCodec.restore(preset.conditions, timeZone: query.timeZone)
            query = restored
            conversionError = nil
        } catch {
            conversionError = error.localizedDescription
        }
    }

    /// 保存点击时的名称和条件；确认失败不清空草稿，账户切换后不发布旧成功状态。
    private func save() async {
        let owner = manager.generation
        let draft = name
        let target = editing
        conversionError = nil
        let success: Bool = if let target {
            await store.rename(target, name: draft, manager: manager)
        } else {
            await store.create(name: draft, query: query, manager: manager)
        }
        guard success, owner == manager.generation, name == draft, editing?.id == target?.id else { return }
        name = ""
        editing = nil
    }
}
