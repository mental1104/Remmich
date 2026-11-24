import SwiftUI

struct AlbumManagementView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [ManagedAlbum] = []
    @State private var name = ""
    @State private var renaming: ManagedAlbum?
    @State private var deleting: ManagedAlbum?
    @State private var error: String?
    @State private var showsRename = false

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section("创建相簿") {
                    TextField("相簿名称", text: $name)
                    Button("创建") {
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        run { _ = try await $0.createAlbum(name: title) }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("我拥有的相簿") {
                    ForEach(albums) { album in
                        LabeledContent(album.albumName) {
                            Menu("管理") {
                                Button("重命名") { renaming = album; name = album.albumName; showsRename = true }
                                Button("删除相簿", role: .destructive) { deleting = album }
                            }
                        }
                    }
                }
            }
            .disabled(controller.busy)
            .navigationTitle("相簿管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(controller.busy) } }
            .task(id: controller.generation) { await load() }
            .onChange(of: controller.generation) { _, _ in dismiss() }
            .alert("重命名相簿", isPresented: $showsRename) {
                TextField("名称", text: $name)
                Button("保存") {
                    guard let album = renaming else { return }
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    run { try await $0.renameAlbum(album.id, name: title) }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("删除此相簿？", isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible, presenting: deleting) { album in
                Button("删除 \(album.albumName)", role: .destructive) { run { try await $0.deleteAlbum(album.id) } }
            } message: { _ in Text("删除相簿及其组织关系，保留其中的照片和视频。所有客户端都会看到此变更。") }
        }
        .interactiveDismissDisabled(controller.busy)
    }

    private func load() async {
        guard let client = controller.client else { return }
        let owner = controller.generation
        do {
            let fresh = try await client.albums()
            guard owner == controller.generation, !Task.isCancelled else { return }
            albums = fresh.filter { $0.ownerId == client.userID }
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ action: @escaping @Sendable (LibraryMutationClient) async throws -> Void) {
        error = nil
        Task {
            do { try await controller.perform(action); name = ""; await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
