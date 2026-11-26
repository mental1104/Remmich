import Foundation
import Testing
@testable import Remmich

/// 使用实际客户端与私有URLSession验证服务端匹配标记合同；原片、官方关联和备份回执均不在写入范围。
@Suite("iCloud match provenance HTTP")
@MainActor struct PhotoBackupICloudMarkerHTTPTests {
    /// 固定独立JSON金值核完整请求及数据库回执；只允许PUT资产元数据，不下载、上传媒体或覆盖mobile-app。
    @Test func storesOnlyIdentityMatchWithoutByteProof() async throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let row = #"{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"remmich-icloud-match","value":{"version":1,"method":"icloud-id","iCloudId":"synthetic-cloud","byteVerified":false},"updatedAt":"2026-11-26T00:00:00Z"}"#
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "PUT", path: "assets/metadata", status: 200, json: "[" + row + "]")])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        try await client.recordICloudMatches([id: "synthetic-cloud"])
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        let body = try #require(requests[0].body)
        let actual = try JSONSerialization.jsonObject(with: body) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(#"{"items":[{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"remmich-icloud-match","value":{"version":1,"method":"icloud-id","iCloudId":"synthetic-cloud","byteVerified":false}}]}"#.utf8)) as? NSDictionary
        #expect(actual == expected && actual != nil)
        #expect(requests[0].method == "PUT" && requests[0].url == fixture.endpoint.appending(path: "assets/metadata"))
    }

    /// kind覆盖错误状态/缺项/重复/错误身份与错误证明；每次真正HTTP返回都不得升级成匹配已保存。
    @Test(arguments: ["missing", "duplicate", "identity", "method", "cloud", "byte-proof", "key", "403", "204"])
    func rejectsUnconfirmedOrUpgradedReceipts(_ kind: String) async throws {
        let id = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        var row = #"{"assetId":"11111111-1111-4111-8111-111111111111","key":"remmich-icloud-match","value":{"version":1,"method":"icloud-id","iCloudId":"synthetic-cloud","byteVerified":false}}"#
        switch kind {
        case "identity": row = row.replacingOccurrences(of: id.uuidString, with: "22222222-2222-4222-8222-222222222222")
        case "method": row = row.replacingOccurrences(of: "icloud-id", with: "sha1")
        case "cloud": row = row.replacingOccurrences(of: "synthetic-cloud", with: "other-cloud")
        case "byte-proof": row = row.replacingOccurrences(of: "false", with: "true")
        case "key": row = row.replacingOccurrences(of: "remmich-icloud-match", with: "mobile-app")
        default: break
        }
        let rows = kind == "missing" ? "[]" : "[" + row + (kind == "duplicate" ? "," + row : "") + "]"
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "PUT", path: "assets/metadata", status: Int(kind) ?? 200, json: rows)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        await #expect(throws: (any Error).self) { try await client.recordICloudMatches([id: "synthetic-cloud"]) }
        let requests = await fixture.script.requests()
        #expect(requests.count == 1)
    }

    /// 空批次不联网；超过64项、空/不完整云标识在写入前失败，不生成部分匹配状态。
    @Test func rejectsInvalidInputBeforeWriting() async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: [])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        try await client.recordICloudMatches([:])
        let tooMany = Dictionary(uniqueKeysWithValues: (0 ..< 65).map { _ in (UUID(), "synthetic-cloud") })
        for values in [tooMany, [UUID(): ""], [UUID(): "invalid:"]] {
            await #expect(throws: LocalPhotoChecksumError.invalidInput) { try await client.recordICloudMatches(values) }
        }
        let requests = await fixture.script.requests()
        #expect(requests.isEmpty)
    }
}
