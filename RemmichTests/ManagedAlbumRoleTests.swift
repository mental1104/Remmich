import Foundation
import Testing
@testable import Remmich

/// 真实管理DTO/目录Store/manager/HTTP的角色回归；仅响应字节与时序为合成，不接生产或Photos。
@Suite("Management album roles")
nonisolated struct ManagedAlbumRoleTests {
    /// variant覆盖完整角色和legacy存在/未知边界；显示owner投影不能覆盖显式成员权限。
    @Test(arguments: ["co-owner", "editor", "viewer", "unknown", "missing-role", "duplicate", "unknown-other", "invalid-member", "absent-current", "legacy", "null-members", "malformed-members"])
    func membershipIsAuthoritativeForEachManagementAction(_ variant: String) throws {
        let json: String
        switch variant {
        case "legacy": json = #"{"id":"\#(roleAlbumID)","albumName":"Synthetic album","ownerId":"\#(roleUserID)"}"#
        case "null-members", "malformed-members":
            let members = variant == "null-members" ? "null" : #"[{"id":"old-member"}]"#
            json = #"{"id":"\#(roleAlbumID)","albumName":"Synthetic album","ownerId":"\#(roleUserID)","albumUsers":\#(members)}"#
        case "duplicate":
            json = roleAlbum(role: "editor", extra: #",{"user":{"id":"\#(roleUserID)"},"role":"viewer"}"#)
        case "unknown-other":
            json = roleAlbum(role: "editor", extra: #",{"user":{"id":"44444444-4444-4444-8444-444444444444"},"role":"future"}"#)
        case "invalid-member":
            json = roleAlbum(role: "editor", extra: #",{"user":{"id":"not-an-identity"},"role":"viewer"}"#)
        case "absent-current": json = roleAlbum(role: "editor").replacingOccurrences(of: roleUserID, with: "55555555-5555-4555-8555-555555555555")
        default: json = roleAlbum(role: variant == "co-owner" ? "owner" : variant == "missing-role" ? nil : variant,
                                  legacyOwner: roleUserID)
        }
        let album = try JSONDecoder().decode(ManagedAlbum.self, from: Data(json.utf8))
        let editable = ["co-owner", "editor", "legacy"].contains(variant)
        #expect(album.access.allows(.update, userID: roleUserID) == editable)
        #expect(album.access.allows(.assets, userID: roleUserID) == editable)
        #expect(album.access.allows(.delete, userID: roleUserID) == ["co-owner", "legacy"].contains(variant))
        #expect(!album.access.allows(.update, userID: ""))
        let directory = try JSONDecoder().decode(ManagedDirectoryAlbum.self, from: Data(json.utf8))
        #expect(directory.access.allows(.update, userID: roleUserID) == editable)
    }

    /// role在第二个有序成员中；各管理动作都先fresh GET，editor不能DELETE，其他动作保留原官方方法/body。
    @Test(arguments: ["owner", "editor"], ["rename", "cover", "add", "remove", "delete"])
    @MainActor func checkedWritesUseFreshRolesAndExactOriginalContracts(_ role: String, _ kind: String) async throws {
        let command: ManagedAlbumMutation
        let method: String
        let path: String
        let body: String?
        switch kind {
        case "rename": command = .rename(id: roleAlbumID, name: "New title"); method = "PATCH"; path = roleAlbumPath; body = #"{"albumName":"New title"}"#
        case "cover": command = .cover(id: roleAlbumID, assetID: roleAssetID); method = "PATCH"; path = roleAlbumPath; body = #"{"albumThumbnailAssetId":"\#(roleAssetID)"}"#
        case "add": command = .add(id: roleAlbumID, assetID: roleAssetID); method = "PUT"; path = roleAlbumPath + "/assets"; body = #"{"ids":["\#(roleAssetID)"]}"#
        case "remove": command = .remove(id: roleAlbumID, assetID: roleAssetID); method = "DELETE"; path = roleAlbumPath + "/assets"; body = #"{"ids":["\#(roleAssetID)"]}"#
        default: command = .delete(id: roleAlbumID); method = "DELETE"; path = roleAlbumPath; body = nil
        }
        let permitted = kind != "delete" || role == "owner"
        let response = kind == "add" || kind == "remove" ? #"[{"id":"\#(roleAssetID)","success":true}]"# : roleAlbum(role: role)
        var exchanges = [roleRead(role: role)]
        if permitted {
            exchanges.append(.init(method: method, path: path, status: kind == "delete" ? 204 : 200, json: response))
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        if permitted {
            try await fixture.manager.perform { try await $0.performAlbumManagement(command) }
        } else {
            do {
                try await fixture.manager.perform { try await $0.performAlbumManagement(command) }
                Issue.record("Editor unexpectedly deleted an album.")
            } catch LibraryWriteError.http(403) { } catch { throw error }
        }
        let requests = await fixture.script.requests()
        try #require(requests.count == (permitted ? 2 : 1))
        #expect(requests[0].method == "GET" && requests[0].body == nil && requests[0].url == fixture.endpoint.appending(path: roleAlbumPath))
        if permitted {
            #expect(requests[1].method == method && requests[1].url == fixture.endpoint.appending(path: path))
            try assertRoleBody(requests[1], json: body)
        }
        #expect(requests.allSatisfy { $0.authorization == "Bearer checksum-owner" })
        #expect(fixture.manager.revision == (permitted ? 1 : 0) && !fixture.manager.busy)
    }

    /// 查看列表时可写不代表确认时仍可写；viewer/未知role均只读，旧legacy owner字段不能恢复已撤销权限。
    @Test(arguments: ["viewer", "future", "missing"])
    @MainActor func freshDemotionDoesNotSendThePreviouslyVisibleAction(_ role: String) async throws {
        let current = roleAlbum(role: role == "missing" ? nil : role, legacyOwner: roleUserID)
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: "GET", path: "albums", status: 200, json: "[\(roleAlbum(role: "editor"))]"),
            .init(method: "GET", path: roleAlbumPath, status: 200, json: current),
        ])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let visible = try await client.albums()
        #expect(visible.first?.access.allows(.assets, userID: roleUserID) == true)
        do {
            try await fixture.manager.perform { try await $0.performAlbumManagement(.add(id: roleAlbumID, assetID: roleAssetID)) }
            Issue.record("A demoted album member unexpectedly sent a write.")
        } catch LibraryWriteError.http(403) { } catch { throw error }
        #expect(await fixture.script.requests().map(\.method) == ["GET", "GET"])
        #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
    }

    /// 实际目录Store保留非首owner/editor入口；fresh降权只能停止，不写分组、不宣称成功或重发。
    @Test(arguments: ["owner", "editor", "revoked"])
    @MainActor func directoryMoveUsesTheSameRolePolicyAtReviewAndPreflight(_ variant: String) async throws {
        let original = roleAlbum(role: variant == "owner" ? "owner" : "editor")
        let confirmed = roleAlbum(role: variant == "owner" ? "owner" : "editor", group: "South")
        let state = #"{"categories":[],"groups":[]}"#
        var exchanges: [ChecksumLookupExchange] = [
            .init(method: "GET", path: "fork/album-categories", status: 200, json: state),
            .init(method: "GET", path: "albums", status: 200, json: "[\(original)]"),
            roleRead(role: variant == "revoked" ? "viewer" : variant),
        ]
        if variant != "revoked" {
            exchanges += [
                .init(method: "PATCH", path: roleAlbumPath, status: 200, json: confirmed),
                .init(method: "GET", path: "fork/album-categories", status: 200, json: state),
                .init(method: "GET", path: "albums", status: 200, json: "[\(confirmed)]"),
            ]
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        let reload = try #require(store.reload(manager: fixture.manager)); await reload.value
        #expect(store.hasFreshData && store.directory?.albums.first?.ownerId == roleOriginalOwnerID)
        let plan = try store.prepare(.moveAlbum(id: roleAlbumID, groupName: "South"), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager)); await operation.value
        let requests = await fixture.script.requests()
        #expect(requests.map(\.method) == (variant == "revoked" ? ["GET", "GET", "GET"] : ["GET", "GET", "GET", "PATCH", "GET", "GET"]))
        if variant == "revoked" {
            #expect(!store.hasFreshData && store.notice == nil && store.error != nil && fixture.manager.revision == 0)
        } else {
            #expect(store.hasFreshData && store.directory?.albums.first?.groupName == "South" && store.notice != nil && store.error == nil)
            try assertRoleBody(requests[3], json: #"{"customGroupName":"South"}"#)
            #expect(fixture.manager.revision == 1)
        }
    }

    /// viewer无权改共享相簿属性，但自己的分组→大组映射仍合法；不能把新角色门禁扩到个人偏好。
    @Test @MainActor func viewerCanStillAssignAPersonalCategory() async throws {
        let state = #"{"categories":[{"id":"44444444-4444-4444-8444-444444444444","name":"Personal"}],"groups":[]}"#
        let after = #"{"categories":[{"id":"44444444-4444-4444-8444-444444444444","name":"Personal"}],"groups":[{"groupName":"North","categoryId":"44444444-4444-4444-8444-444444444444"}]}"#
        let albums = "[\(roleAlbum(role: "viewer"))]"
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: "GET", path: "fork/album-categories", status: 200, json: state),
            .init(method: "GET", path: "albums", status: 200, json: albums),
            .init(method: "PUT", path: "fork/album-categories/group", status: 204, json: ""),
            .init(method: "GET", path: "fork/album-categories", status: 200, json: after),
            .init(method: "GET", path: "albums", status: 200, json: albums),
        ])
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        let reload = try #require(store.reload(manager: fixture.manager)); await reload.value
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.moveAlbum(id: roleAlbumID, groupName: "South"), manager: fixture.manager) }
        let plan = try store.prepare(.assignGroup(name: "North", categoryID: "44444444-4444-4444-8444-444444444444"), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager)); await operation.value
        #expect(store.hasFreshData && store.error == nil && fixture.manager.revision == 1)
        #expect(await fixture.script.requests().map(\.method) == ["GET", "GET", "PUT", "GET", "GET"])
    }

    /// 在真实fresh GET等待期间取消/换号/换路由，旧client不得继续写；门退出与业务退休都真实等待并清理。
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "account", "endpoint"])
    @MainActor func retiredRoleReadsCannotSendTheWrite(_ retirement: String) async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: [roleRead(role: "owner", held: true)])
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let operation = Task {
                try await fixture.manager.perform { try await $0.performAlbumManagement(.delete(id: roleAlbumID)) }
            }
            let completion = Task { _ = await operation.result; await fixture.script.operationFinished() }
            let arrived = await fixture.script.waitForHeld()
            if !arrived {
                operation.cancel(); await fixture.script.release(); await completion.value
                Issue.record("Fresh album role request did not reach its hold boundary.")
                return
            }
            if retirement == "cancel" {
                operation.cancel()
            } else {
                let endpoint = retirement == "endpoint" ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
                let user = retirement == "account" ? "55555555-5555-4555-8555-555555555555" : roleUserID
                fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint, user: user), endpoint: endpoint)
            }
            await fixture.script.release(); await completion.value
            await fixture.script.waitForHeldResponderExit()
            #expect(await fixture.script.requests().map(\.method) == ["GET"])
            #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
        } onCancel: { Task { await fixture.script.stop() } }
    }
}

private nonisolated let roleAlbumID = "11111111-1111-4111-8111-111111111111"
private nonisolated let roleUserID = "99999999-9999-4999-8999-999999999999"
private nonisolated let roleOriginalOwnerID = "22222222-2222-4222-8222-222222222222"
private nonisolated let roleAssetID = "33333333-3333-4333-8333-333333333333"
private nonisolated let roleAlbumPath = "albums/11111111-1111-4111-8111-111111111111"

/// role是第二位当前用户的明确角色，nil只省略role；group用于目录回读，legacyOwner/extra构造冲突或未知反例。
private nonisolated func roleAlbum(role: String?, group: String = "North", legacyOwner: String? = nil, extra: String = "") -> String {
    let field = role.map { #", "role":"\#($0)""# } ?? ""
    let legacy = legacyOwner.map { #", "ownerId":"\#($0)""# } ?? ""
    return #"{"id":"\#(roleAlbumID)","albumName":"Synthetic album","customGroupName":"\#(group)"\#(legacy),"albumUsers":[{"user":{"id":"\#(roleOriginalOwnerID)"},"role":"owner"},{"user":{"id":"\#(roleUserID)"}\#(field)}\#(extra)]}"#
}

/// role为fresh完整成员快照，held暂停真实URLSession；绝不返回伪造本机/服务端写入结果。
private nonisolated func roleRead(role: String, held: Bool = false) -> ChecksumLookupExchange {
    .init(method: "GET", path: roleAlbumPath, status: 200, json: roleAlbum(role: role), held: held)
}

/// request为真实发出的有限JSON，json为独立期望；nil要求无body，排序规范化后逐字节对比全部字段。
private nonisolated func assertRoleBody(_ request: ChecksumLookupRequest, json: String?) throws {
    guard let json else { #expect(request.body == nil); return }
    let data = try #require(request.body)
    let actual = try JSONSerialization.jsonObject(with: data)
    let expected = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let actualBytes = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
    let expectedBytes = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
    #expect(actualBytes == expectedBytes)
}
