import SwiftUI

/// 当前账号拥有相簿的管理入口；批量页只在可取得真实前台读源时开放。
struct AlbumManagementView: View {
    let controller: LibraryManagementController
    let source: (any TimelineReading)?
    let media: MediaLibraryController?
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [ManagedAlbum] = []
    @State private var name = ""
    @State private var renaming: ManagedAlbum?
    @State private var deleting: ManagedAlbum?
    @State private var error: String?
    @State private var showsRename = false
    @State private var managingPhotos: ManagedAlbum?
    @State private var showsDirectory = false
    @State private var showsSharing = false

    /// controller维护写入账号代际；source/media由真实Albums页传入，默认nil保留既有基础管理入口。
    init(controller: LibraryManagementController, source: (any TimelineReading)? = nil,
         media: MediaLibraryController? = nil)
    {
        self.controller = controller
        self.source = source
        self.media = media
    }

    /// 前台读源能力与普通缓存时间线明确区分，缺少能力时不声称写后重载已刷新。
    private var managementSource: (any ManagementTimelineProviding)? {
        source as? any ManagementTimelineProviding
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section("Album directory") {
                    Button("Manage categories and groups") { showsDirectory = true }
                        .disabled(controller.client == nil)
                }
                Section("共享相簿") {
                    Button("成员与共享权限") { showsSharing = true }
                        .disabled(controller.client == nil)
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
                                Button("Manage photos and cover") { managingPhotos = album }
                                    .disabled(managementSource == nil || media == nil)
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
            .sheet(isPresented: $showsDirectory, onDismiss: { Task { await load() } }) {
                AlbumDirectoryManagementView(controller: controller)
            }
            .sheet(isPresented: $showsSharing, onDismiss: { Task { await load() } }) { AlbumSharingView(controller: controller) }
            .sheet(item: $managingPhotos, onDismiss: { Task { await load() } }) { album in
                if let managementSource, let media {
                    BatchAssetManagementView(album: .init(id: album.id, name: album.albumName),
                                             ownedAlbums: albums.map { .init(id: $0.id, name: $0.albumName) },
                                             factory: { try await managementSource.managementTimelineReader() },
                                             media: media, controller: controller)
                } else {
                    ContentUnavailableView("Album management unavailable", systemImage: "network",
                                           description: Text("Connect to the current account and reload albums."))
                }
            }
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

    /// 读取当前账号拥有相簿；账号变更或取消后的结果/错误均不能发布到下一上下文。
    private func load() async {
        guard let client = controller.client else { return }
        let owner = controller.generation
        do {
            let fresh = try await client.albums()
            guard owner == controller.generation, !Task.isCancelled else { return }
            albums = fresh.filter { $0.ownerId == client.userID }
        } catch {
            guard owner == controller.generation, !Task.isCancelled else { return }
            self.error = "Albums could not be loaded. Check permissions and connection."
        }
    }

    /// action是用户明确选择的相簿操作；只在同一账号确认成功后重载，不自动重放写请求。
    private func run(_ action: @escaping @Sendable (LibraryMutationClient) async throws -> Void) {
        error = nil
        let owner = controller.generation
        Task {
            do {
                try await controller.perform(action)
                guard owner == controller.generation, !Task.isCancelled else { return }
                name = ""
                await load()
            } catch {
                guard owner == controller.generation, !Task.isCancelled else { return }
                self.error = albumFailureMessage(error)
            }
        }
    }

    /// error为当前账号相簿操作错误；区分鉴权/权限/消失和未确认结果，不展示原始响应或URL。
    private func albumFailureMessage(_ error: Error) -> String {
        switch error {
        case LibraryWriteError.http(401): "Sign in again before managing albums."
        case LibraryWriteError.http(403): "This account does not have permission to change this album."
        case LibraryWriteError.http(404): "The album is no longer available. Reload the list."
        case LibraryWriteError.http(409): "The album changed. Reload before trying again."
        default: "The album operation could not be confirmed. Reload before trying again."
        }
    }
}
