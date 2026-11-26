import Foundation
import Testing
@testable import Remmich

/// 自有来源通过官方元数据API保存并从真实同步解析器恢复；不覆盖官方关系，也不把ID匹配升级成字节证明。
@Suite("Backup iCloud origin and cross-client metadata")
struct PhotoBackupOriginTests {
    /// 同一资产的不同云ID使用独立key；官方/自有相同事实合并，官方重复候选仍保留为歧义。
    @Test func preservesAliasesWithoutDuplicatingOfficialCandidates() throws {
        let assetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let first = try originTestValue(cloudID: "cloud-one"), second = try originTestValue(cloudID: "cloud-two")
        #expect(PhotoBackupOrigin.metadataKey(for: first.metadata.cloudId) != PhotoBackupOrigin.metadataKey(for: second.metadata.cloudId))
        let official = try originTestRow(assetID: assetID, key: "mobile-app", value: JSONEncoder().encode(first.metadata))
        let own = try originTestRow(assetID: assetID, key: PhotoBackupOrigin.metadataKey(for: first.metadata.cloudId), value: JSONEncoder().encode(first))
        let alias = try originTestRow(assetID: assetID, key: PhotoBackupOrigin.metadataKey(for: second.metadata.cloudId), value: JSONEncoder().encode(second))
        let matched = try originTestDecode(official + own + alias, clouds: ["cloud-one", "cloud-two"])
        #expect(try matched.count == 2 && Set(matched.map(\.assetID)) == [#require(UUID(uuidString: assetID))])
        let clouds = try matched.map { try JSONDecoder().decode(LocalMediaMobileMetadata.self, from: $0.value).cloudId }
        #expect(Set(clouds) == ["cloud-one", "cloud-two"])
        let ambiguous = try originTestDecode(official + official + own, clouds: ["cloud-one"])
        #expect(ambiguous.count == 2)
    }

    /// kind选择坏版本/方法/字节声明/摘要/key；完整流也不能接受伪造的来源证据。
    @Test(arguments: ["version", "method", "byteVerified", "checksum", "key"])
    func rejectsMalformedOriginEvidence(_ kind: String) throws {
        let origin = try originTestValue(cloudID: "cloud-one")
        var value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin)) as? [String: Any])
        switch kind {
        case "version": value[kind] = 2
        case "method": value[kind] = "icloud-id"
        case "byteVerified": value[kind] = false
        case "checksum": value[kind] = "incomplete"
        default: break
        }
        let key = PhotoBackupOrigin.metadataKey(for: kind == "key" ? "other-cloud" : "cloud-one")
        let row = try originTestRow(assetID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", key: key, value: JSONSerialization.data(withJSONObject: value))
        #expect(throws: (any Error).self) { try originTestDecode(row, clouds: ["cloud-one"]) }
    }

    /// 响应只允许确认原样来源；错误checksum/身份/key/证明及HTTP失败均传播，不能把媒体完成当作来源完成。
    @Test(arguments: ["checksum", "identity", "key", "proof", "503", "missing"])
    @MainActor func rejectsUnconfirmedOriginWrites(_ kind: String) async throws {
        let id = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let origin = try originTestValue(cloudID: "cloud-one")
        let fixture = ChecksumLookupHTTPFixture(exchanges: [
            .init(method: "PUT", path: "assets/metadata", status: Int(kind) ?? 200, json: "", responseJSON: { request in
                if kind == "missing" {
                    return "[]"
                }
                guard let body = request.body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      var rows = json["items"] as? [[String: Any]], rows.count == 1,
                      var value = rows[0]["value"] as? [String: Any] else { throw LibraryWriteError.malformedResponse }
                switch kind {
                case "checksum": value["checksum"] = "wrong"
                case "proof": value["byteVerified"] = false
                case "identity": rows[0]["assetId"] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                case "key": rows[0]["key"] = "mobile-app"
                default: break
                }
                rows[0]["value"] = value
                return try String(decoding: JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
            }),
        ])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        await #expect(throws: (any Error).self) { try await client.recordBackupOrigin(assetID: id, origin: origin) }
        let requests = await fixture.script.requests()
        #expect(requests.count == 1 && requests.first?.method == "PUT")
    }
}

/// cloudID是完整合成Photos云标识；摘要为公开abc样本的SHA1，公开元组与官方字符串格式相同。
private nonisolated func originTestValue(cloudID: String) throws -> PhotoBackupOrigin {
    try .init(metadata: LocalMediaMobileMetadata(cloudId: cloudID, createdAt: Date(timeIntervalSince1970: 200), adjustmentTime: nil, latitude: nil, longitude: nil),
              checksum: "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
}

/// assetID/key/value组成独立服务端事件；不省略真实stream envelope和ACK，不从解析器内部状态生成数据。
private nonisolated func originTestRow(assetID: String, key: String, value: Data) throws -> String {
    let payload: [String: Any] = try ["assetId": assetID, "key": key, "value": JSONSerialization.jsonObject(with: value)]
    let event: [String: Any] = ["type": "AssetMetadataV1", "ack": "AssetMetadataV1|11111111-1111-4111-8111-111111111111", "data": payload]
    return try String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n"
}

/// text为待检JSONL，clouds限定本轮身份；真实逐字节解码并要求正常终止后返回结果。
private nonisolated func originTestDecode(_ text: String, clouds: Set<String>) throws -> [LocalMediaRemoteMetadataRecord] {
    var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: clouds)
    let complete = "{\"type\":\"SyncCompleteV1\",\"data\":{},\"ack\":\"SyncCompleteV1|22222222-2222-4222-8222-222222222222\"}\n"
    for byte in (text + complete).utf8 {
        try decoder.append(byte)
    }
    return try decoder.finish()
}
