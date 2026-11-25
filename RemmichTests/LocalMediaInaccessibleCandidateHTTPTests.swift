import Foundation
import Testing
@testable import Remmich

/// 真实Controller→LibraryMutationClient→URLSession穿过服务端精确400合同；仅系统观察和HTTP端口为合成输入。
@Suite("Inaccessible local-match candidates over HTTP")
@MainActor struct LocalMediaInaccessibleCandidateHTTPTests {
    /// path覆盖两个fresh入口，message覆盖权限前不可读及权限后消失；首项撤销后继续第二项并真实冷恢复。
    @Test(arguments: ["metadata", "checksum"], ["denied", "gone"])
    func exactDenialContinuesAndColdRestoresOnlySecond(_ path: String, _ message: String) async throws {
        let fixture = try await inaccessibleFixture(path: path, first: inaccessibleResponse(message))
        defer { fixture.close() }
        let operation = try #require(fixture.controller.scan(using: fixture.http.manager))
        await operation.value
        let second = try #require(fixture.controller.association(assetID: inaccessibleSecond.uuidString, revision: inaccessibleRevision))
        #expect(second.localIdentity == fixture.snapshots[1].identity && second.source == (path == "metadata" ? .mobileMetadata : .checksum))
        #expect(fixture.controller.association(assetID: inaccessibleFirst.uuidString, revision: inaccessibleRevision) == nil)
        #expect(fixture.controller.total == 2 && fixture.controller.scanned == 2 && fixture.controller.unmatched == 1)
        #expect(fixture.controller.metadataMatches == (path == "metadata" ? 1 : 0) && fixture.controller.checksumMatches == (path == "checksum" ? 1 : 0))
        #expect(fixture.controller.metadataFailures == 0 && fixture.controller.status.contains("已完成") && !fixture.controller.running)
        let saved = try await fixture.store.load(scope: fixture.scope)
        #expect(saved?.enabled == true && saved?.associations == [second])
        let coldManager = LibraryManagementController()
        coldManager.configure(session: checksumLookupSession(endpoint: fixture.http.endpoint), endpoint: nil)
        let cold = LocalMediaMatchController(inventory: fixture.inventory, metadata: InaccessibleMetadata(fixture.snapshots),
                                             checksum: fixture.checksum, persistence: fixture.store, observeChanges: false)
        let restore = try #require(cold.restoreAndRefresh(using: coldManager, scope: fixture.scope))
        await restore.value
        #expect(cold.association(assetID: inaccessibleFirst.uuidString, revision: inaccessibleRevision) == nil)
        #expect(cold.association(assetID: inaccessibleSecond.uuidString, revision: inaccessibleRevision) == second)
        let requests = await fixture.http.script.requests()
        try inaccessibleAssertRequests(requests, path: path, freshIDs: [inaccessibleFirst, inaccessibleSecond])
        #expect(fixture.checksum.localIDs == (path == "metadata" ? ["synthetic-first"] : ["synthetic-first", "synthetic-second"]))
    }

    /// 精确拒绝metadata候选后仍用独立本机hash找到另一个可读副本；不将整个本机项目直接丢弃。
    @Test func deniedMetadataCanConfirmAnotherChecksumCopy() async throws {
        let fixture = try await inaccessibleFixture(path: "metadata", first: inaccessibleResponse("denied"), recoverCopy: true)
        defer { fixture.close() }
        let operation = try #require(fixture.controller.scan(using: fixture.http.manager))
        await operation.value
        let copy = try #require(fixture.controller.association(assetID: inaccessibleCopy.uuidString, revision: inaccessibleRevision))
        #expect(copy.localIdentity == fixture.snapshots[0].identity && copy.source == .checksum)
        #expect(fixture.controller.metadataMatches == 1 && fixture.controller.checksumMatches == 1 && fixture.controller.unmatched == 0)
        let saved = try await fixture.store.load(scope: fixture.scope)
        #expect(Set(saved?.associations.map(\.remoteID) ?? []) == [inaccessibleSecond, inaccessibleCopy])
        let requests = await fixture.http.script.requests()
        try inaccessibleAssertRequests(requests, path: "metadata", freshIDs: [inaccessibleFirst, inaccessibleSecond, inaccessibleCopy], copy: true)
    }

    /// 普通400、其他权限、错误形状/JSON、401/403/404/5xx及坏200均中止，不删除旧关联、不继续第二张或保存虚假完成。
    @Test(arguments: ["metadata", "checksum"], ["400", "401", "403", "404", "500", "503", "wrong-permission", "message-array", "extra-field", "bad-json", "malformed-200", "wrong-content-type"])
    func unrelatedFailuresRetainExplicitFailure(_ path: String, _ failure: String) async throws {
        let fixture = try await inaccessibleFixture(path: path, first: inaccessibleResponse(failure))
        defer { fixture.close() }
        let revision = fixture.controller.revision
        let operation = try #require(fixture.controller.scan(using: fixture.http.manager))
        await operation.value
        #expect(fixture.controller.association(assetID: inaccessibleFirst.uuidString, revision: inaccessibleRevision) == fixture.seed)
        #expect(fixture.controller.association(assetID: inaccessibleSecond.uuidString, revision: inaccessibleRevision) == nil)
        #expect(fixture.controller.revision == revision && fixture.controller.unmatched == 0 && !fixture.controller.running)
        #expect(fixture.controller.status.contains("未完成"))
        let saved = try await fixture.store.load(scope: fixture.scope)
        #expect(saved?.associations == [fixture.seed])
        let requests = await fixture.http.script.requests()
        try inaccessibleAssertRequests(requests, path: path, freshIDs: [inaccessibleFirst])
    }

    /// 两fresh入口在真实HTTP等待点取消/换号/换端点/撤权限；旧400不得变成未匹配并继续扫描或改写冷保存。
    @Test(.timeLimit(.minutes(1)), arguments: ["metadata", "checksum"], ["cancel", "account", "endpoint", "permission"])
    func retirementPrecedesInterpretingDenial(_ path: String, _ action: String) async throws {
        var first = inaccessibleResponse("denied"); first.held = true
        let fixture = try await inaccessibleFixture(path: path, first: first)
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let revision = fixture.controller.revision
            let operation = try #require(fixture.controller.scan(using: fixture.http.manager))
            let completion = Task { await operation.value; await fixture.http.script.operationFinished() }
            let started = await fixture.http.script.waitForHeld()
            #expect(started)
            if action == "cancel" {
                fixture.controller.cancel()
            } else if action == "permission" {
                fixture.inventory.authorization = .denied
            } else {
                let session = checksumLookupSession(endpoint: fixture.http.endpoint,
                                                    user: action == "account" ? "22222222-2222-4222-8222-222222222222" : inaccessibleOwner.uuidString)
                let endpoint = action == "endpoint" ? fixture.http.endpoint.appending(path: "new-route") : fixture.http.endpoint
                fixture.http.manager.configure(session: session, endpoint: endpoint)
            }
            await fixture.http.script.release(); await completion.value
            await fixture.http.script.waitForHeldResponderExit()
            #expect(fixture.controller.revision == revision && fixture.controller.unmatched == 0 && !fixture.controller.running)
            #expect(fixture.controller.association(assetID: inaccessibleSecond.uuidString, revision: inaccessibleRevision) == nil)
            let saved = try await fixture.store.load(scope: fixture.scope)
            #expect(saved?.associations == [fixture.seed])
            let requests = await fixture.http.script.requests()
            try inaccessibleAssertRequests(requests, path: path, freshIDs: [inaccessibleFirst])
        } onCancel: {
            Task { @MainActor in fixture.controller.cancel(); await fixture.http.script.stop() }
        }
    }

    /// 相同精确正文出现在普通管理读取/PUT时仍是HTTP400；窄读取修补不能改变通用send或写入语义。
    @Test(arguments: ["read", "write"])
    func managementOperationsKeepTheirHTTPFailure(_ operation: String) async throws {
        var response = inaccessibleResponse("denied")
        response = .init(method: operation == "write" ? "PUT" : "GET", path: response.path, status: response.status, json: response.json)
        let http = ChecksumLookupHTTPFixture(exchanges: [response]); defer { http.close() }
        let client = try #require(http.manager.client)
        do {
            if operation == "write" {
                try await client.update(inaccessibleFirst.uuidString, favorite: true)
            } else {
                _ = try await client.asset(inaccessibleFirst.uuidString)
            }
            Issue.record("Management denial must remain an HTTP failure")
        } catch let LibraryWriteError.http(status) { #expect(status == 400) }
        let requests = await http.script.requests()
        #expect(requests.count == 1)
    }
}

private nonisolated let inaccessibleFirst = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")!
private nonisolated let inaccessibleSecond = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")!
private nonisolated let inaccessibleCopy = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")!
private nonisolated let inaccessibleOwner = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
private nonisolated let inaccessibleRevision = Date(timeIntervalSince1970: 100.123)

/// mode选择首个fresh响应；精确body来自原始HTTP回执，其他形状必须维持失败，绝不调用产品分类器生成预期。
private nonisolated func inaccessibleResponse(_ mode: String) -> ChecksumLookupExchange {
    var status = Int(mode) ?? 400
    var json = #"{"message":"Not found or no asset.read access"}"#
    switch mode {
    case "gone": json = #"{"message":"Asset not found"}"#
    case "400": json = #"{"message":"Validation failed"}"#
    case "wrong-permission": json = #"{"message":"Not found or no asset.update access"}"#
    case "message-array": json = #"{"message":["Not found or no asset.read access"]}"#
    case "extra-field": json = #"{"message":"Not found or no asset.read access","detail":"ambiguous"}"#
    case "bad-json": json = #"{"message":"Not found or no asset.read access""#
    case "malformed-200": status = 200; json = "{}"
    default: break
    }
    return .init(method: "GET", path: "assets/\(inaccessibleFirst.uuidString)", status: status, json: json,
                 contentType: mode == "wrong-content-type" ? "text/plain" : "application/json")
}

/// path规定HTTP序列；store先真实保存/离线恢复旧首项，再联网显式扫描，metadata/checksum都使用真实LibraryMutationClient。
@MainActor private func inaccessibleFixture(path: String, first: ChecksumLookupExchange, recoverCopy: Bool = false) async throws -> InaccessibleFixture {
    var exchanges: [ChecksumLookupExchange] = []
    if path == "metadata" {
        let rows = [(inaccessibleFirst, "synthetic-cloud-first"), (inaccessibleSecond, "synthetic-cloud-second")].map { id, cloud in
            #"{"type":"AssetMetadataV1","data":{"assetId":"\#(id.uuidString)","key":"mobile-app","value":{"iCloudId":"\#(cloud)","createdAt":"1970-01-01T00:00:10Z"}},"ack":"AssetMetadataV1|\#(id.uuidString)"}"#
        }
        let stream = (rows + [#"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|11111111-1111-4111-8111-111111111111"}"#]).joined(separator: "\n") + "\n"
        exchanges = [.init(method: "GET", path: "sync/ack", status: 200, json: "[]"),
                     .init(method: "POST", path: "sync/stream", status: 200, json: stream, contentType: "application/jsonlines+json")]
    } else {
        exchanges.append(inaccessiblePrecheck(copy: false))
    }
    exchanges += [first, inaccessibleAssetResponse(inaccessibleSecond, first: false)]
    if recoverCopy {
        exchanges += [inaccessiblePrecheck(copy: true), inaccessibleAssetResponse(inaccessibleCopy, first: true)]
    }
    let http = ChecksumLookupHTTPFixture(exchanges: exchanges)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InaccessibleCandidate-\(UUID())", isDirectory: true)
    do {
        let session = checksumLookupSession(endpoint: http.endpoint); let scope = MediaAccountScope(session: session)
        http.manager.configure(session: session, endpoint: nil)
        let snapshots = [inaccessibleSnapshot(first: true, cloud: path == "metadata"), inaccessibleSnapshot(first: false, cloud: path == "metadata")]
        let inventory = InaccessibleInventory(ids: snapshots.map(\.identity.localIdentifier))
        let checksum = InaccessibleChecksum(provideProofs: path == "checksum" || recoverCopy)
        let store = LocalMediaAssociationStore(directory: directory)
        let seed = LocalMediaAssociation(remoteID: inaccessibleFirst, remoteRevision: inaccessibleRevision, localIdentity: snapshots[0].identity,
                                         checksum: inaccessibleDigest(first: true), source: path == "metadata" ? .mobileMetadata : .checksum)
        let saved = try await store.save(.init(scope: scope, enabled: true, access: .full, associations: [seed]), scope: scope, permit: LocalMediaSavePermit())
        try #require(saved)
        let controller = LocalMediaMatchController(inventory: inventory, metadata: InaccessibleMetadata(snapshots), checksum: checksum, persistence: store, observeChanges: false)
        let restore = try #require(controller.restoreAndRefresh(using: http.manager, scope: scope)); await restore.value
        try #require(controller.association(assetID: inaccessibleFirst.uuidString, revision: inaccessibleRevision) == seed)
        http.manager.configure(session: session, endpoint: http.endpoint); controller.configure(using: http.manager, scope: scope)
        return .init(http: http, directory: directory, scope: scope, store: store, seed: seed, controller: controller, snapshots: snapshots, inventory: inventory, checksum: checksum)
    } catch {
        http.close(); try? FileManager.default.removeItem(at: directory); throw error
    }
}

/// 真实系统依赖之外的测试所有权；close先撤销扫描/会话，再只删除此例独占恢复目录。
@MainActor private struct InaccessibleFixture {
    let http: ChecksumLookupHTTPFixture
    let directory: URL
    let scope: MediaAccountScope
    let store: LocalMediaAssociationStore
    let seed: LocalMediaAssociation
    let controller: LocalMediaMatchController
    let snapshots: [LocalPhotoSnapshot]
    let inventory: InaccessibleInventory
    let checksum: InaccessibleChecksum

    /// 不访问图库或外部路径；异常退出也释放本例HTTP等待门。
    func close() {
        controller.cancel(); http.close(); try? FileManager.default.removeItem(at: directory)
    }
}

/// 仅返回本例两个已有授权的本机ID；不向系统请求照片内容或真实授权。
@MainActor private final class InaccessibleInventory: LocalPhotoInventoryReading {
    var authorization = LocalPhotoLibraryAccess.full
    private let ids: [String]
    /// ids固定顺序，用于证明首项拒绝后第二项仍被扫描。
    init(ids: [String]) {
        self.ids = ids
    }

    /// 显式scan只观察本例授权值。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorization
    }

    /// validateContext沿用产品Task/账号/权限门禁，返回未过滤的本例清单。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return ids
    }
}

/// metadata只替换PhotoKit快照，服务器候选流仍经真实HTTP读取/解析。
@MainActor private struct InaccessibleMetadata: LocalPhotoMetadataReading {
    let values: [LocalPhotoSnapshot]
    /// values为两个公开字段完整的合成观察。
    init(_ values: [LocalPhotoSnapshot]) {
        self.values = values
    }

    /// localIdentifiers限定当前batch；validateContext照常运行，不替Controller确认关联。
    func snapshots(for localIdentifiers: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext(); return values.filter { localIdentifiers.contains($0.identity.localIdentifier) }
    }
}

/// 只替换本机完整摘要的系统读取；真实precheck协议、nonce和fresh关联由产品决定。
@MainActor private final class InaccessibleChecksum: LocalPhotoChecksumReading {
    private let provideProofs: Bool
    private(set) var localIDs: [String] = []
    /// provideProofs决定本例本机字节可读或不足，不由远端拒绝状态推断。
    init(provideProofs: Bool) {
        self.provideProofs = provideProofs
    }

    /// expected是产品实际快照；完整proof仍经领域构造器，调用方上下文失败原样抛出。
    func checksum(for expected: LocalPhotoSnapshot, validateContext: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        try validateContext(); localIDs.append(expected.identity.localIdentifier)
        guard provideProofs else { return .insufficient(.notLocallyAvailable) }
        let source = expected.withCloudIdentity(.unavailable)
        let resource = LocalPhotoChecksumResource(descriptor: source.resources[0], format: .image)
        let digest = try LocalPhotoByteDigest(sha1Hex: String(repeating: expected.identity.localIdentifier == "synthetic-first" ? "aa" : "bb", count: 20), byteCount: 5)
        return try .verified(.init(asset: .init(snapshot: source, resources: [resource]), resource: resource, digest: digest))
    }
}

/// first/cloud只区分两份完整系统观察；静态公开资源支持原有纯image政策，不读取照片或声明备份完成。
private nonisolated func inaccessibleSnapshot(first: Bool, cloud: Bool) -> LocalPhotoSnapshot {
    .init(identity: .init(localIdentifier: first ? "synthetic-first" : "synthetic-second", modificationDate: Date(timeIntervalSince1970: 15), mediaKind: .image),
          creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
          pixelWidth: 64, pixelHeight: 48, duration: 0, mediaSubtypes: 0,
          resources: [.init(type: 1, role: .originalPhoto, originalFilename: "synthetic.jpg", uniformTypeIdentifier: "public.jpeg", pixelWidth: 64, pixelHeight: 48)],
          cloudIdentity: cloud ? .resolved(first ? "synthetic-cloud-first" : "synthetic-cloud-second") : .unavailable)
}

/// first选择两个不同的完整SHA1测试摘要；不声称本例执行真实照片读取或SHA1算法。
private nonisolated func inaccessibleDigest(first: Bool) -> String {
    Data(repeating: first ? 0xAA : 0xBB, count: 20).base64EncodedString()
}

/// id/first确定同owner有效fresh JSON，不能由产品DTO编码器掩盖协议字段缺失。
private nonisolated func inaccessibleAssetResponse(_ id: UUID, first: Bool) -> ChecksumLookupExchange {
    .init(method: "GET", path: "assets/\(id.uuidString)", status: 200,
          json: #"{"id":"\#(id.uuidString)","ownerId":"\#(inaccessibleOwner.uuidString)","type":"IMAGE","isTrashed":false,"isOffline":false,"isEdited":false,"checksum":"\#(inaccessibleDigest(first: first))","updatedAt":"1970-01-01T00:01:40.123Z"}"#)
}

/// copy只让首个本机摘要命中另一远端副本；回执nonce来自实际HTTP请求，错误body明确失败，不替产品生成请求。
private nonisolated func inaccessiblePrecheck(copy: Bool) -> ChecksumLookupExchange {
    .init(method: "POST", path: "assets/bulk-upload-check", status: 200, json: "", responseJSON: { request in
        guard let data = request.body,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]],
              let assets = body["assets"], !assets.isEmpty else { throw URLError(.badServerResponse) }
        let results = try assets.map { item -> [String: Any] in
            guard let nonce = item["id"], let digest = item["checksum"],
                  [String(repeating: "aa", count: 20), String(repeating: "bb", count: 20)].contains(digest) else { throw URLError(.badServerResponse) }
            let id = digest == String(repeating: "aa", count: 20) ? (copy ? inaccessibleCopy : inaccessibleFirst) : inaccessibleSecond
            return ["id": nonce, "action": "reject", "reason": "duplicate", "assetId": id.uuidString, "isTrashed": false]
        }
        return try String(decoding: JSONSerialization.data(withJSONObject: ["results": results]), as: UTF8.self)
    })
}

/// requests是URLSession实发事实；path/copy限定唯一白名单与顺序，freshIDs核两个候选，排除媒体/上传/ACK/reset请求。
private nonisolated func inaccessibleAssertRequests(_ requests: [ChecksumLookupRequest], path: String, freshIDs: [UUID], copy: Bool = false) throws {
    var expected = path == "metadata" ? ["GET /api/sync/ack", "POST /api/sync/stream"] : ["POST /api/assets/bulk-upload-check"]
    for (index, id) in freshIDs.enumerated() {
        if copy, index == 2 {
            expected.append("POST /api/assets/bulk-upload-check")
        }
        expected.append("GET /api/assets/\(id.uuidString)")
    }
    #expect(requests.map { "\($0.method) \($0.url.path)" } == expected)
    #expect(requests.allSatisfy { $0.authorization == "Bearer checksum-owner" && $0.cookie == nil && $0.url.query == nil })
    for request in requests where request.url.lastPathComponent == "stream" {
        let body = try #require(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: [String]]
        #expect(json == ["types": ["AssetMetadataV1"]])
    }
}
