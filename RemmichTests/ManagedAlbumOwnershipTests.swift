import Foundation
import Testing
@testable import Remmich

/// 当前官方相簿成员投影和既有ownerId合同回归；HTTP案例经过真实管理客户端，服务字节来自隔离传输。
@Suite("Managed album ownership projection")
nonisolated struct ManagedAlbumOwnershipTests {
    /// 第二个owner可为当前成员，但兼容标量仍取官方响应的首个owner，不能按登录身份或最后一项猜测。
    @Test(arguments: [false, true])
    func readsTheFirstDeclaredOwner(_ secondOwner: Bool) throws {
        let json = modernAlbum(secondOwner: secondOwner)
        let album = try JSONDecoder().decode(ManagedAlbum.self, from: Data(json.utf8))
        #expect(album.id == albumOwnershipID && album.albumName == "Synthetic album")
        #expect(album.ownerId == albumOwnershipOwner)
    }

    /// 原ownerId响应继续按既有规则读取；附加旧版成员数组、空值或新版数组均不改旧合同的优先级。
    @Test(arguments: ["", #","albumUsers":null"#, #","albumUsers":[{"id":"legacy-member"}]"#,
                      #","albumUsers":[{"user":{"id":"another"},"role":"owner"}]"#])
    func preservesTheExistingOwnerField(_ extra: String) throws {
        let json = #"{"id":"\#(albumOwnershipID)","albumName":"Synthetic album","ownerId":"\#(albumOwnershipOwner)"\#(extra)}"#
        let album = try JSONDecoder().decode(ManagedAlbum.self, from: Data(json.utf8))
        #expect(album.ownerId == albumOwnershipOwner)
    }

    /// 缺少原ownerId后，新成员投影必须真实完整；不能从空数组、任意editor或后续owner补猜权限身份。
    @Test(arguments: ["missing", "null", "empty", "editor-first", "missing-user", "empty-owner", "wrong-role"])
    func rejectsUnconfirmedModernOwnership(_ variant: String) throws {
        let members = switch variant {
        case "missing": ""
        case "null": #","albumUsers":null"#
        case "empty": #","albumUsers":[]"#
        case "editor-first": #","albumUsers":[{"user":{"id":"editor"},"role":"editor"},{"user":{"id":"later-owner"},"role":"owner"}]"#
        case "missing-user": #","albumUsers":[{"role":"owner"}]"#
        case "empty-owner": #","albumUsers":[{"user":{"id":""},"role":"owner"}]"#
        default: #","albumUsers":[{"user":{"id":"owner"},"role":42}]"#
        }
        let json = #"{"id":"\#(albumOwnershipID)","albumName":"Synthetic album"\#(members)}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ManagedAlbum.self, from: Data(json.utf8)) }
    }

    /// 列表、创建及封面更新均必须解码实际新形状；方法、状态、Bearer及实发body由原HTTP脚本和独立断言核对。
    @Test(arguments: ["list", "create", "cover"])
    @MainActor func actualManagementReadsDecodeCurrentResponses(_ operation: String) async throws {
        let method = operation == "list" ? "GET" : operation == "create" ? "POST" : "PATCH"
        let path = operation == "cover" ? "albums/\(albumOwnershipID)" : "albums"
        let json = modernAlbum(secondOwner: false)
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: method, path: path, status: operation == "create" ? 201 : 200,
                                                                  json: operation == "list" ? "[\(json)]" : json)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let album: ManagedAlbum
        if operation == "list" {
            let values = try await client.albums()
            album = try #require(values.first)
        } else if operation == "create" {
            album = try await client.createAlbum(name: "Synthetic album")
        } else {
            album = try await client.setAlbumCover(albumOwnershipID, assetID: albumOwnershipCover)
        }
        #expect(album.id == albumOwnershipID && album.ownerId == albumOwnershipOwner)
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        #expect(requests[0].method == method && requests[0].url == fixture.endpoint.appending(path: path))
        #expect(requests[0].authorization == "Bearer checksum-owner")
        if operation == "create" {
            let body = try #require(requests[0].body)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(object?["albumName"] as? String == "Synthetic album")
            #expect(object?["assetIds"] as? [String] == [])
            #expect(object?.count == 2)
        } else if operation == "cover" {
            let body = try #require(requests[0].body)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
            #expect(object == ["albumThumbnailAssetId": albumOwnershipCover])
        } else {
            #expect(requests[0].body == nil)
        }
    }
}

private nonisolated let albumOwnershipID = "11111111-1111-4111-8111-111111111111"
private nonisolated let albumOwnershipOwner = "22222222-2222-4222-8222-222222222222"
private nonisolated let albumOwnershipCover = "33333333-3333-4333-8333-333333333333"

/// 仅投影当前官方真实字段形状；secondOwner为多owner情况，不添加当前服务已没有的ownerId。
private nonisolated func modernAlbum(secondOwner: Bool) -> String {
    let role = secondOwner ? "owner" : "editor"
    return #"{"id":"\#(albumOwnershipID)","albumName":"Synthetic album","albumUsers":[{"user":{"id":"\#(albumOwnershipOwner)"},"role":"owner"},{"user":{"id":"44444444-4444-4444-8444-444444444444"},"role":"\#(role)"}]}"#
}
