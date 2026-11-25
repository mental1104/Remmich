import SwiftUI

/// 可达的原生目录管理页；大组/整组父归属是个人偏好，相簿分组改动在确认中明确跨客户端影响。
struct AlbumDirectoryManagementView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @State private var store = AlbumDirectoryManagementStore()
    @State private var categoryName = ""
    @State private var editingCategory: ForkAlbumDirectory.Category?
    @State private var movingAlbum: ManagedDirectoryAlbum?
    @State private var groupName = ""
    @State private var pending: AlbumDirectoryPlan?

    /// 写入口只在完整fresh快照可用且管理通道空闲时启用，读取错误不能伪装成默认目录。
    private var canWrite: Bool {
        store.hasFreshData && !store.isLoading && !store.isWorking && !controller.busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Categories and group placement are private to your account. Album group names are shared album properties.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let notice = store.notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                    if let error = store.error {
                        Text(error).foregroundStyle(.red)
                    }
                    if store.isLoading {
                        ProgressView("Loading directory")
                    }
                    if store.isWorking {
                        ProgressView("Saving and reloading")
                        Button("Stop waiting") { store.cancel() }
                    }
                    Button("Reload directory") { store.reload(manager: controller) }
                        .disabled(store.isWorking || store.isLoading)
                }
                if store.isUnsupported {
                    Section {
                        Text("This server does not provide album categories. Standard album management remains available.")
                    }
                }
                if let directory = store.directory {
                    categoryEditor
                    Section("Categories") {
                        LabeledContent("Default", value: "System category")
                        ForEach(directory.state.categories) { category in
                            LabeledContent(category.name) {
                                Menu("Manage") {
                                    Button("Rename") { editingCategory = category; categoryName = category.name }
                                    Button("Delete category", role: .destructive) { prepare(.deleteCategory(id: category.id)) }
                                }
                            }
                        }
                    }.disabled(!canWrite)
                    Section {
                        ForEach(directory.groupNames, id: \.self) { group in
                            LabeledContent(group.isEmpty ? "Ungrouped" : group) {
                                Menu(directory.categoryName(for: group)) {
                                    Button("Default") { prepare(.assignGroup(name: group, categoryID: nil)) }
                                    ForEach(directory.state.categories) { category in
                                        Button(category.name) { prepare(.assignGroup(name: group, categoryID: category.id)) }
                                    }
                                }
                            }
                        }
                        if directory.groupNames.isEmpty {
                            Text("Groups appear when an album uses a group name.").foregroundStyle(.secondary)
                        }
                    } header: { Text("Group placement") } footer: {
                        Text("Moving a group changes its category for your account, including all visible albums with that group name.")
                    }.disabled(!canWrite)
                    Section {
                        ForEach(directory.albums.filter { $0.ownerId.lowercased() == controller.client?.userID.lowercased() }) { album in
                            LabeledContent {
                                Button(album.groupName.isEmpty ? "Ungrouped" : album.groupName) {
                                    movingAlbum = album; groupName = album.groupName
                                }
                            } label: { Text(album.albumName) }
                        }
                    } header: { Text("Move an owned album") } footer: {
                        Text("Choose an existing group or enter a new name. Shared albums owned by someone else are excluded here.")
                    }.disabled(!canWrite)
                    if let movingAlbum {
                        albumGroupEditor(movingAlbum, directory: directory)
                    }
                }
            }
            .navigationTitle("Album directory")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(store.isWorking) }
            }
            .task(id: controller.generation) {
                if let task = store.reload(manager: controller) {
                    await task.value
                }
            }
            .onChange(of: controller.generation) { _, _ in
                pending = nil; store.invalidate(); dismiss()
            }
            .onChange(of: store.notice) { _, notice in
                if notice != nil {
                    editingCategory = nil; categoryName = ""; movingAlbum = nil; groupName = ""
                }
            }
            .onDisappear { store.invalidate() }
            .confirmationDialog(pending?.title ?? "Confirm directory change", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible, presenting: pending) { plan in
                Button("Confirm", role: deletionRole(plan.command)) { store.start(plan, manager: controller); pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { plan in Text(plan.message) }
        }
        .interactiveDismissDisabled(store.isWorking)
    }

    /// 大组创建/改名共用输入；取消只清空本地草稿，不触发服务端请求。
    private var categoryEditor: some View {
        Section(editingCategory == nil ? "Create category" : "Rename category") {
            TextField("Category name", text: $categoryName)
            Button("Review change") {
                if let editingCategory {
                    prepare(.renameCategory(id: editingCategory.id, name: categoryName))
                } else {
                    prepare(.createCategory(name: categoryName))
                }
            }.disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if editingCategory != nil {
                Button("Cancel rename", role: .cancel) { editingCategory = nil; categoryName = "" }
            }
        }.disabled(!canWrite)
    }

    /// album为编辑草稿所属相簿，directory为当前真实目录；保存前仍由Store再次核对所有权和代际。
    private func albumGroupEditor(_ album: ManagedDirectoryAlbum, directory: ManagedAlbumDirectory) -> some View {
        Section("Move \(album.albumName)") {
            TextField("Group name (empty for Ungrouped)", text: $groupName)
            Menu("Use an existing group") {
                Button("Ungrouped") { groupName = "" }
                ForEach(directory.groupNames.filter { !$0.isEmpty }, id: \.self) { name in Button(name) { groupName = name } }
            }
            Button("Review move") { prepare(.moveAlbum(id: album.id, groupName: groupName)) }
            Button("Cancel move", role: .cancel) { movingAlbum = nil; groupName = "" }
        }.disabled(!canWrite)
    }

    /// command为用户刚选择的动作；只生成确认，输入错误安全显示，不直接写入。
    private func prepare(_ command: AlbumDirectoryCommand) {
        do { pending = try store.prepare(command, manager: controller) }
        catch { store.showError((error as? AlbumDirectoryManagementError)?.errorDescription ?? "Reload the directory before another change.") }
    }

    /// command仅在删除大组时使用破坏性确认样式；其他命令也须用户显式确认。
    private func deletionRole(_ command: AlbumDirectoryCommand) -> ButtonRole? {
        if case .deleteCategory = command {
            return .destructive
        }
        return nil
    }
}
