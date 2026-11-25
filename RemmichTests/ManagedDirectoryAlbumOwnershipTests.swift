import Foundation
import Testing
@testable import Remmich

/// 目录GET和分组PATCH经真实客户端读取当前/旧版身份；仅HTTP字节由各例私有URLSession提供。
@Suite("Directory album ownership projection")
nonisolated struct ManagedDirectoryAlbumOwnershipTests {
    /// operation覆盖列表/设分组/清分组；shape覆盖首owner、显式null及旧字段优先，不能把后续owner当原始owner。
    @Test(arguments: ["list", "group", "clear"], ["modern", "modern-null", "legacy", "legacy-precedence"])
    @MainActor func directoryRequestsReadBothOwnershipShapes(_ operation: String, _ shape: String) async throws {
        let group = operation == "clear" ? "null" : #""North""#
        let json = directoryOwnershipAlbum(shape: shape, group: group)
        let method = operation == "list" ? "GET" : "PATCH"
        let path = operation == "list" ? "albums" : "albums/\(directoryOwnershipID)"
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: method, path: path, status: 200, json: operation == "list" ? "[\(json)]" : json),
        ])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let album: ManagedDirectoryAlbum
        if operation == "list" {
            let albums = try await client.directoryAlbums()
            try #require(albums.count == 1)
            album = try #require(albums.first)
        } else {
            album = try await client.setAlbumGroup(directoryOwnershipID, groupName: operation == "clear" ? " \n " : "  North  ")
        }
        #expect(album.id == directoryOwnershipID && album.albumName == "Synthetic directory album")
        #expect(album.ownerId == directoryOwnershipOwner && album.groupName == (operation == "clear" ? "" : "North"))
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        #expect(requests[0].method == method && requests[0].url == fixture.endpoint.appending(path: path))
        #expect(requests[0].authorization == "Bearer checksum-owner")
        if operation == "list" {
            #expect(requests[0].body == nil)
        } else {
            let body = try #require(requests[0].body)
            let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let object = try #require(decoded)
            #expect(object.count == 1)
            if operation == "clear" {
                #expect(object["customGroupName"] is NSNull)
            } else {
                #expect(object["customGroupName"] as? String == "North")
            }
        }
    }

    /// GET/PATCH均拒绝缺失、空或顺序不符的新版身份；不能因存在后续owner或成功HTTP状态而猜测。
    @Test(arguments: [false, true], ["missing", "empty", "editor-first", "empty-owner", "wrong-owner-type"])
    @MainActor func directoryRequestsRejectUnconfirmedOwners(_ patch: Bool, _ variant: String) async throws {
        let members = switch variant {
        case "missing": ""
        case "empty": #","albumUsers":[]"#
        case "editor-first": #","albumUsers":[{"user":{"id":"editor"},"role":"editor"},{"user":{"id":"later-owner"},"role":"owner"}]"#
        case "empty-owner": #","albumUsers":[{"user":{"id":""},"role":"owner"}]"#
        default: #","ownerId":42,"albumUsers":[{"user":{"id":"later-owner"},"role":"owner"}]"#
        }
        let json = #"{"id":"\#(directoryOwnershipID)","albumName":"Synthetic directory album","customGroupName":"North"\#(members)}"#
        // 先独立确认是合法JSON；测试失败须来自身份解码，不能靠格式错误冒充拒绝无效owner。
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: patch ? "PATCH" : "GET", path: patch ? "albums/\(directoryOwnershipID)" : "albums",
                  status: 200, json: patch ? json : "[\(json)]"),
        ])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        do {
            if patch {
                _ = try await client.setAlbumGroup(directoryOwnershipID, groupName: "North")
            } else {
                _ = try await client.directoryAlbums()
            }
            Issue.record("Unconfirmed album ownership must fail decoding.")
        } catch is DecodingError {
            // 正确失败：既有鉴权/路由都已经过真实HTTP边界，但响应不能建立已确认身份。
        }
        #expect(await fixture.script.requests().count == 1)
    }

    /// 当前无目录扩展字段的响应可用于只读列表；PATCH仍必须真实返回该字段，不能把忽略写入当清分组成功。
    @Test(arguments: [false, true])
    @MainActor func missingGroupFieldRemainsReadOnlyCompatible(_ patch: Bool) async throws {
        let json = directoryOwnershipAlbum(shape: "modern", group: nil)
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: patch ? "PATCH" : "GET", path: patch ? "albums/\(directoryOwnershipID)" : "albums",
                  status: 200, json: patch ? json : "[\(json)]"),
        ])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        if patch {
            do {
                _ = try await client.setAlbumGroup(directoryOwnershipID, groupName: nil)
                Issue.record("A missing group field cannot confirm a directory write.")
            } catch LibraryWriteError.malformedResponse {
                // 身份可解码，但响应没有确认写入字段；保留原有未知写入结果门禁。
            }
        } else {
            let albums = try await client.directoryAlbums()
            #expect(albums.count == 1 && albums.first?.ownerId == directoryOwnershipOwner && albums.first?.groupName == "")
        }
        #expect(await fixture.script.requests().count == 1)
    }
}

/// 合成身份只在本测试使用，不包含账号、私人相簿或媒体。
private nonisolated let directoryOwnershipID = "11111111-1111-4111-8111-111111111111"
private nonisolated let directoryOwnershipOwner = "22222222-2222-4222-8222-222222222222"

/// shape选当前/旧版合同，group为显式JSON值或nil省略；后续owner故意不同，证明读取保留响应顺序。
private nonisolated func directoryOwnershipAlbum(shape: String, group: String?) -> String {
    let ownership: String
    switch shape {
    case "legacy": ownership = #""ownerId":"\#(directoryOwnershipOwner)""#
    case "legacy-precedence": ownership = #""ownerId":"\#(directoryOwnershipOwner)","albumUsers":[{"id":"legacy-member"}]"#
    default:
        let legacy = shape == "modern-null" ? #""ownerId":null,"# : ""
        ownership = #"\#(legacy)"albumUsers":[{"user":{"id":"\#(directoryOwnershipOwner)"},"role":"owner"},{"user":{"id":"33333333-3333-4333-8333-333333333333"},"role":"owner"}]"#
    }
    let directory = group.map { #","customGroupName":\#($0)"# } ?? ""
    return #"{"id":"\#(directoryOwnershipID)","albumName":"Synthetic directory album",\#(ownership)\#(directory)}"#
}
