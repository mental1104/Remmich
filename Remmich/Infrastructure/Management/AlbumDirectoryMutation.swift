import Foundation

extension LibraryMutationClient {
    /// command为已经确认的单项目录意图；逐项映射现有Fork/官方接口，不增加写队列或自动重试。
    func applyDirectoryCommand(_ command: AlbumDirectoryCommand) async throws {
        switch command {
        case let .createCategory(name): _ = try await createAlbumCategory(name: name)
        case let .renameCategory(id, name): _ = try await renameAlbumCategory(id, name: name)
        case let .deleteCategory(id): try await deleteAlbumCategory(id)
        case let .assignGroup(name, categoryID): try await assignAlbumGroup(name, categoryID: categoryID)
        case let .moveAlbum(id, groupName): _ = try await setAlbumGroup(id, groupName: groupName)
        }
    }
}
