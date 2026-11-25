import Foundation
import Photos
import Testing
@testable import Remmich

/// 只读校验和真实URLSession契约；没有上传、mobile-app依赖、服务媒体读取或备份状态变更。
@Suite("Local media checksum lookup")
@MainActor struct LocalMediaChecksumLookupTests {
    /// 本机无cloud元数据仍可通过真正SHA1→HTTP找到NAS已有候选；反序回执按nonce还原，不把accept当上传。
    @Test func usesOnlyLocalBytesAndReadOnlyPrecheck() async throws {
        let source = checksumAsset()
        let reader = PhotoKitCurrentResourceChecksumReader(source: { _ in source }, bytes: { _, _ in
            let stream = LocalPhotoResourceSHA1Stream()
            return try await stream.read(start: { allowed, receive, complete in
                #expect(!allowed); receive(Data(checksumBytes.prefix(9))); receive(Data(checksumBytes.dropFirst(9))); complete(nil); return 7
            }, cancel: { _ in Issue.record("Successful synthetic read should not cancel") })
        }, authorization: { .authorized })
        let outcome = try await reader.checksum(for: source.snapshot, validateContext: {})
        guard case let .verified(proof) = outcome else { Issue.record("Expected local current proof without cloud identity"); return }
        #expect(proof.source.cloudIdentity == .unavailable)
        let queries = try [LocalMediaChecksumQuery(id: lookupNonce1, digest: proof.digest),
                           LocalMediaChecksumQuery(id: lookupNonce2, digest: .init(sha1Hex: "bed01e34622b5ba65e2c8502113e11bbba40ffaf", byteCount: 30)),
                           LocalMediaChecksumQuery(id: lookupNonce3, digest: .init(sha1Hex: "3c661e929a2027c1b16459ead69840d4d8c95d59", byteCount: 30))]
        let response = #"{"results":[{"id":"33333333-3333-4333-8333-333333333333","action":"accept"},{"id":"22222222-2222-4222-8222-222222222222","action":"reject","reason":"duplicate","assetId":"55555555-5555-4555-8555-555555555555","isTrashed":true},{"id":"11111111-1111-4111-8111-111111111111","action":"reject","reason":"duplicate","assetId":"44444444-4444-4444-8444-444444444444","isTrashed":false}]}"#
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "POST", path: lookupPath, status: 200, json: response)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let result = try await client.lookupLocalMediaChecksums(queries)
        #expect(result == [.init(id: lookupNonce1, outcome: .existing(lookupRemote1)), .init(id: lookupNonce2, outcome: .trashed(lookupRemote2)), .init(id: lookupNonce3, outcome: .noMatch)])
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        try assertLookupJSON(requests[0], expected: #"{"assets":[{"id":"11111111-1111-4111-8111-111111111111","checksum":"c4502db68c24556654ccd8993abc2d2e578ad286"},{"id":"22222222-2222-4222-8222-222222222222","checksum":"bed01e34622b5ba65e2c8502113e11bbba40ffaf"},{"id":"33333333-3333-4333-8333-333333333333","checksum":"3c661e929a2027c1b16459ead69840d4d8c95d59"}]}"#)
        #expect(requests.map(\.url.lastPathComponent) == ["bulk-upload-check"] && requests[0].method == "POST")
        #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
    }

    /// 错误身份/重复/缺字段/错误动作与状态一律不给候选，不能将缺省isTrashed当false或多余条目隐藏成单一成功。
    @Test(arguments: ["201", "403", "503", "missing-row", "extra-row", "wrong-id", "duplicate-id", "missing-trash", "null-trash", "string-trash", "missing-asset", "null-asset", "invalid-asset", "v7-asset", "unsupported-reason", "unknown-action", "accept-fields", "accept-null", "root-array"])
    func rejectsIncompleteOrContradictoryPrecheck(_ kind: String) async throws {
        var row = lookupRow()
        switch kind {
        case "missing-row": row = ""
        case "extra-row", "duplicate-id": row += "," + lookupRow()
        case "wrong-id": row = row.replacingOccurrences(of: lookupNonce1.uuidString.lowercased(), with: lookupNonce2.uuidString.lowercased())
        case "missing-trash": row = lookupRow(trash: nil)
        case "null-trash": row = lookupRow(trash: "null")
        case "string-trash": row = lookupRow(trash: #""false""#)
        case "missing-asset": row = lookupRow(asset: nil)
        case "null-asset": row = lookupRow(asset: "null")
        case "invalid-asset": row = lookupRow(asset: #""not-an-asset""#)
        case "v7-asset": row = lookupRow(asset: #""44444444-4444-7444-8444-444444444444""#)
        case "unsupported-reason": row = row.replacingOccurrences(of: "duplicate", with: "unsupported-format")
        case "unknown-action": row = row.replacingOccurrences(of: "reject", with: "something-new")
        case "accept-fields": row = row.replacingOccurrences(of: "reject", with: "accept")
        case "accept-null": row = #"{"id":"11111111-1111-4111-8111-111111111111","action":"accept","assetId":null}"#
        default: break
        }
        let json = kind == "root-array" ? "[" + row + "]" : #"{"results":[\#(row)]}"#
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "POST", path: lookupPath, status: Int(kind) ?? 200, json: json)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        do { _ = try await client.lookupLocalMediaChecksums([lookupQuery()]); Issue.record("Unconfirmed precheck must fail") }
        catch { #expect(!(error is CancellationError)) }
        #expect(await fixture.script.requests().count == 1)
        #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
    }

    /// 客户端64项限额是明确本地政策，65/重复nonce在HTTP前拒绝；空批次不探测也不上传。
    @Test func enforcesInputBoundaryWithoutNetwork() async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: [])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let query = try lookupQuery()
        #expect(try await client.lookupLocalMediaChecksums([]).isEmpty)
        for queries in try [[query, query], (1 ... 65).map { try lookupQuery(id: lookupUUID($0)) }] {
            do { _ = try await client.lookupLocalMediaChecksums(queries); Issue.record("Invalid checksum batch must fail before HTTP") }
            catch { #expect(error as? LocalPhotoChecksumError == .invalidInput) }
        }
        #expect(await fixture.script.requests().isEmpty)
    }

    /// 64项同hash未命中是合法响应；每个nonce仍有自己的回执，不能因相同hash把本机身份去重掉。
    @Test func preservesCompleteMaximumBatch() async throws {
        let queries = try (1 ... 64).map { try lookupQuery(id: lookupUUID($0)) }
        let rows = queries.reversed().map { #"{"id":"\#($0.id.uuidString.lowercased())","action":"accept"}"# }
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "POST", path: lookupPath, status: 200, json: #"{"results":[\#(rows.joined(separator: ","))]}"#)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        let results = try await client.lookupLocalMediaChecksums(queries)
        #expect(results.map(\.id) == queries.map(\.id) && results.allSatisfy { $0.outcome == .noMatch })
        let requests = await fixture.script.requests()
        try #require(requests.count == 1)
        let body = try JSONSerialization.jsonObject(with: #require(requests[0].body)) as? [String: Any]
        #expect(body?.keys.count == 1 && (body?["assets"] as? [[String: String]])?.count == 64)
    }

    /// 真实HTTP在途时取消/换账号/换端点，晚回执不会返回给新上下文；未发送上传、ACK或媒体请求。
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "account", "endpoint"])
    func rejectsLateReplyAfterCancellationOrAccountChange(_ mode: String) async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "POST", path: lookupPath, status: 200, json: #"{"results":[\#(lookupRow())]}"#, held: true)])
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let client = try #require(fixture.manager.client)
            let query = try lookupQuery()
            let operation = Task { try await client.lookupLocalMediaChecksums([query]) }
            let completion = Task { let result = await operation.result; await fixture.script.operationFinished(); return result }
            #expect(await fixture.script.waitForHeld())
            if mode == "cancel" {
                operation.cancel()
            } else {
                let endpoint = mode == "endpoint" ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
                fixture.manager.configure(session: checksumLookupSession(endpoint: endpoint, user: mode == "account" ? "88888888-8888-4888-8888-888888888888" : "99999999-9999-4999-8999-999999999999", token: "checksum-next"), endpoint: endpoint)
            }
            await fixture.script.release()
            let result = await completion.value
            await fixture.script.waitForHeldResponderExit()
            if case .success = result {
                Issue.record("Cancelled or replaced account must not receive a checksum lookup")
            }
            #expect(await fixture.script.requests().count == 1)
            #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
        } onCancel: { Task { @MainActor in fixture.close() } }
    }
}

/// 合成nonce与远端UUID彼此不同，避免用响应顺序或本机ID伪造远端身份。
private nonisolated let lookupNonce1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let lookupNonce2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private nonisolated let lookupNonce3 = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private nonisolated let lookupRemote1 = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private nonisolated let lookupRemote2 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private nonisolated let lookupPath = "assets/bulk-upload-check"

/// id为本轮独立nonce；摘要来自Node参考，不调用上传/检查请求的生产编码器来构造预期。
private nonisolated func lookupQuery(id: UUID = lookupNonce1) throws -> LocalMediaChecksumQuery {
    try .init(id: id, digest: .init(sha1Hex: "c4502db68c24556654ccd8993abc2d2e578ad286", byteCount: 37))
}

/// value生成合法独立v4 nonce，覆盖64/65实际不同ID，不能让重复ID掩盖批量边界。
private nonisolated func lookupUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
}

/// asset/trash是独立JSON片段，nil明确省略字段；便于验证缺键/null而非生产解码器默认值。
private nonisolated func lookupRow(asset: String? = #""44444444-4444-4444-8444-444444444444""#, trash: String? = "false") -> String {
    let asset = asset.map { #", "assetId":\#($0)"# } ?? ""
    let trash = trash.map { #", "isTrashed":\#($0)"# } ?? ""
    return #"{"id":"11111111-1111-4111-8111-111111111111","action":"reject","reason":"duplicate"\#(asset)\#(trash)}"#
}

/// request是完整实际POST；expected是独立JSON，全部键值比较，检测暗中附带上传字段或私有身份。
private nonisolated func assertLookupJSON(_ request: ChecksumLookupRequest, expected: String) throws {
    let actual = try JSONSerialization.jsonObject(with: #require(request.body))
    let expected = try JSONSerialization.jsonObject(with: Data(expected.utf8))
    #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
}
