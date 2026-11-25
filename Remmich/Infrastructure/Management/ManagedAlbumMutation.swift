import Foundation

extension LibraryMutationClient {
    /// id为明确相簿，permission为本次动作；fresh GET重新读取角色，失权/未知响应只读且不发写请求。
    /// 原client取消与请求前后门禁照常生效，服务端仍最终裁决写入瞬间的权限。
    func requireManagedAlbumPermission(_ id: String, permission: ManagedAlbumPermission) async throws {
        let fresh = try await managementAlbum(id)
        guard fresh.access.allows(permission, userID: userID) else { throw LibraryWriteError.http(403) }
        try Task.checkCancellation()
    }

    /// change只来自明确管理动作；每次最多一个原官方写入，fresh预检失败不发送，不自动重放未知结果。
    /// 原底层写方法/回执保持不变，避免改变上传、备份或旧SDK调用的网络合同。
    func performAlbumManagement(_ change: ManagedAlbumMutation) async throws {
        try await requireManagedAlbumPermission(change.albumID, permission: change.permission)
        switch change {
        case let .rename(id, name): try await renameAlbum(id, name: name)
        case let .delete(id): try await deleteAlbum(id)
        case let .cover(id, assetID): _ = try await setAlbumCover(id, assetID: assetID)
        case let .add(id, assetID): try await add(assetID, to: id)
        case let .remove(id, assetID): try await remove(assetID, from: id)
        }
    }
}
