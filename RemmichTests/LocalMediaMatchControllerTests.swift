import Foundation
import Testing
@testable import Remmich

/// 合成系统/网络边界之上的真实Controller与JSON恢复；不请求PhotoKit、账号、媒体或任何外网。
@Suite("Local media association controller")
@MainActor struct LocalMediaMatchControllerTests {
    /// 唯一官方元数据先匹配再fresh GET；没有哈希读取，保存后精确远端版本才可查询关联。
    @Test func metadataMatchPersistsOnlyVerifiedAssociation() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try matchFixture(directory: directory)
        let operation = try #require(fixture.controller.scan(using: fixture.manager))
        await operation.value
        let value = try #require(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision))
        #expect(value.source == .mobileMetadata && value.localIdentity == fixture.snapshot.identity)
        #expect(fixture.controller.metadataMatches == 1 && fixture.controller.checksumMatches == 0 && fixture.controller.scanned == 1)
        #expect(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision.addingTimeInterval(0.001)) == nil)
        #expect(fixture.checksum.requests == 0 && fixture.inventory.authorizationRequests == 1)
        let persisted = try await fixture.store.load(scope: fixture.scope)
        #expect(persisted?.enabled == true && persisted?.associations == [value])
        let calls = await fixture.remote.calls
        #expect(calls == ["metadata", "asset"] && !fixture.controller.running)
    }

    /// fresh详情必须逐项满足身份/owner/类型/在线/未编辑/明确状态及有效SHA1，不能用旧缓存或缺省false确认。
    @Test(arguments: ["id", "owner", "type", "trash", "offline", "edited", "unknown-offline", "unknown-edited", "checksum", "version"])
    func unsafeFreshDetailsNeverCreateAssociation(_ mode: String) async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try MatchRemote(records: [matchRecord()], asset: matchAsset(mode))
        let fixture = try matchFixture(directory: directory, remote: remote)
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        #expect(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) == nil)
        #expect(fixture.controller.metadataMatches == 0 && fixture.controller.unmatched == 1)
        let document = try await fixture.store.load(scope: fixture.scope)
        #expect(document?.associations.isEmpty == true)
    }

    /// 重复cloud候选不靠第一条猜测；不足的本机字节证明也不能转换为匹配或上传。
    @Test func duplicateMetadataRemainsUnconfirmed() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let record = try matchRecord()
        let fixture = try matchFixture(directory: directory, remote: MatchRemote(records: [record, record], asset: matchAsset()))
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        #expect(fixture.controller.metadataMatches == 0 && fixture.controller.unmatched == 1 && fixture.checksum.requests == 1)
        let calls = await fixture.remote.calls
        #expect(calls == ["metadata"])
    }

    /// metadata检查点、旧服务端、半截流或单条坏字段不能阻断独立本机SHA1；坏流不交出任何元数据关联。
    @Test(arguments: ["checkpoint", "unsupported", "incomplete", "bad-record"])
    func unavailableMetadataStillUsesIndependentLocalProof(_ mode: String) async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = matchSnapshot()
        let checksum = try MatchChecksum(proof: matchProof(snapshot))
        let remote = MatchRemote(records: [], asset: matchAsset(), metadataMode: mode)
        let fixture = try matchFixture(directory: directory, snapshot: snapshot, remote: remote, checksum: checksum)
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        let association = try #require(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision))
        #expect(association.source == .checksum && fixture.controller.metadataMatches == 0 && fixture.controller.checksumMatches == 1)
        #expect(fixture.controller.metadataFailures == 1 && fixture.controller.status.contains("元数据不可用"))
        let calls = await remote.calls
        #expect(calls == ["metadata", "checksum", "asset"] && checksum.requests == 1)
        let document = try await fixture.store.load(scope: fixture.scope)
        #expect(document?.associations == [association])
    }

    /// 取消错误必须传播到停止状态，不能伪装成metadata不可用后额外读取本机字节或继续远端查询。
    @Test func cancelledMetadataNeverFallsThroughToChecksum() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let remote = MatchRemote(records: [], asset: matchAsset(), metadataMode: "cancelled")
        let fixture = try matchFixture(directory: directory, remote: remote)
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        #expect(fixture.controller.metadataFailures == 0 && fixture.checksum.requests == 0 && fixture.controller.status.contains("已停止"))
        let calls = await remote.calls
        #expect(calls == ["metadata"] && fixture.controller.metadataMatches == 0 && fixture.controller.checksumMatches == 0)
    }

    /// 无CloudID仍可读本机严格current证明并查SHA1；结果ID对应、fresh checksum和状态都要确认。
    @Test(arguments: ["existing", "wrong-checksum", "trashed", "no-match", "wrong-query"])
    func checksumFallbackRequiresProofAndFreshIdentity(_ mode: String) async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = matchSnapshot(cloud: .unavailable)
        let proof = try matchProof(snapshot)
        let checksum = MatchChecksum(proof: proof)
        let remote = MatchRemote(records: [], asset: matchAsset(mode == "wrong-checksum" ? "different-checksum" : "valid"), lookupMode: mode)
        let fixture = try matchFixture(directory: directory, snapshot: snapshot, remote: remote, checksum: checksum)
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        let value = fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision)
        #expect((value != nil) == (mode == "existing"))
        #expect(fixture.controller.metadataMatches == 0 && fixture.controller.checksumMatches == (mode == "existing" ? 1 : 0))
        let sentDigests = await remote.digests
        #expect(sentDigests == [proof.digest])
        let document = try await fixture.store.load(scope: fixture.scope)
        #expect(document?.associations.count == (mode == "existing" ? 1 : 0))
    }

    /// 全量130项仍只使用64/64/2的有限元数据批次，不对每一批重新请求完整server stream。
    @Test func largeInventoryUsesFiniteBatchesWithoutRepeatedStreams() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = (0 ..< 130).map { matchSnapshot(localID: "synthetic-\($0)", cloud: .unavailable) }
        let metadata = MatchMetadata(snapshots: snapshots)
        let inventory = MatchInventory(ids: snapshots.map(\.identity.localIdentifier))
        let fixture = try matchFixture(directory: directory, inventory: inventory, metadata: metadata)
        let operation = try #require(fixture.controller.scan(using: fixture.manager)); await operation.value
        #expect(metadata.batchCounts == [64, 64, 2, 64, 64, 2])
        #expect(fixture.controller.total == 130 && fixture.controller.scanned == 130 && fixture.controller.unmatched == 130)
        let calls = await fixture.remote.calls
        #expect(calls.isEmpty)
    }

    /// fresh GET迟到时换号或停止，都不能发布或持久化旧扫描结果；完成前保存的启用配置不伪造关联。
    @Test(arguments: ["account", "cancel"])
    func heldFreshReadCannotPublishAfterRetirement(_ mode: String) async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try MatchRemote(records: [matchRecord()], asset: matchAsset(), holdAsset: true)
        let fixture = try matchFixture(directory: directory, remote: remote)
        let operation = try #require(fixture.controller.scan(using: fixture.manager))
        do {
            try await waitForAsset(remote)
            if mode == "account" {
                let session = matchSession(owner: "22222222-2222-4222-8222-222222222222")
                fixture.manager.configure(session: session, endpoint: session.apiURL)
                fixture.controller.configure(using: fixture.manager, scope: .init(session: session))
            } else {
                fixture.controller.cancel()
            }
            await remote.releaseAsset(); await operation.value
            #expect(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) == nil)
            let document = try await fixture.store.load(scope: fixture.scope)
            #expect(document?.enabled == true && document?.associations.isEmpty == true && !fixture.controller.running)
        } catch {
            fixture.controller.cancel(); await remote.releaseAsset(); await operation.value; throw error
        }
    }

    /// 离线同namespace冷恢复仍能本机读取；client缺失不能当退出登录，且不请求权限/服务器或擅自清零。
    @Test(arguments: [true, false])
    func coldOfflineRestoreRespectsScopeAndAuthorization(_ allowed: Bool) async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try matchFixture(directory: directory)
        let association = try #require(LocalMediaAssociation.verified(remote: matchAsset(), requestedID: matchRemoteID, ownerID: fixture.scope.userID,
                                                                      local: fixture.snapshot.identity, source: .mobileMetadata))
        let saved = try await fixture.store.save(.init(scope: fixture.scope, enabled: true, access: .full, associations: [association]),
                                                 scope: fixture.scope, permit: LocalMediaSavePermit())
        #expect(saved)
        fixture.manager.configure(session: matchSession(), endpoint: nil)
        fixture.inventory.authorization = allowed ? .full : .denied
        let restore = try #require(fixture.controller.restoreAndRefresh(using: fixture.manager, scope: fixture.scope)); await restore.value
        #expect(fixture.controller.enabled && (fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) != nil) == allowed)
        #expect(fixture.inventory.authorizationRequests == 0 && fixture.metadata.batchCounts.isEmpty)
        let calls = await fixture.remote.calls
        #expect(calls.isEmpty)
        fixture.controller.configure(using: fixture.manager, scope: nil)
        #expect(!fixture.controller.enabled && fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) == nil)
    }

    /// 已启用配置在新进程自动刷新，已有授权不再次请求；相同manager代际的多次生命周期通知不反复扫描。
    @Test func enabledColdRestoreRefreshesOnceWithoutPrompt() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try matchFixture(directory: directory)
        _ = try await fixture.store.save(.init(scope: fixture.scope, enabled: true, access: nil, associations: []), scope: fixture.scope, permit: LocalMediaSavePermit())
        let restore = try #require(fixture.controller.restoreAndRefresh(using: fixture.manager, scope: fixture.scope)); await restore.value
        #expect(fixture.controller.metadataMatches == 1 && fixture.inventory.authorizationRequests == 0)
        let previous = fixture.metadata.batchCounts
        let repeated = fixture.controller.restoreAndRefresh(using: fixture.manager, scope: fixture.scope)
        #expect(repeated == nil && fixture.metadata.batchCounts == previous)
    }

    /// 路由由在线切离线仍保留同账号确认项；权限撤销立即不再提供旧关联，恢复处理不会弹系统权限框。
    @Test func sameScopeOfflineAndPermissionRevocationInvalidateCorrectly() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try matchFixture(directory: directory)
        let scan = try #require(fixture.controller.scan(using: fixture.manager)); await scan.value
        let revision = fixture.controller.revision
        fixture.manager.configure(session: matchSession(), endpoint: nil)
        fixture.controller.configure(using: fixture.manager, scope: fixture.scope)
        #expect(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) != nil)
        fixture.inventory.authorization = .denied
        #expect(fixture.controller.association(assetID: matchRemoteID.uuidString, revision: matchRevision) == nil)
        let change = try #require(fixture.controller.restoreAndRefresh(using: fixture.manager, scope: fixture.scope)); await change.value
        #expect(fixture.controller.revision > revision && fixture.inventory.authorizationRequests == 1)
        let document = try await fixture.store.load(scope: fixture.scope)
        #expect(document?.enabled == true && document?.associations.isEmpty == true)
    }

    /// 只等待真实Controller到达fresh读取；超时抛错交给调用方释放闸门，不把固定sleep当成功时序。
    private func waitForAsset(_ remote: MatchRemote) async throws {
        for _ in 0 ..< 200 {
            if await remote.assetStarted {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await remote.assetStarted
        try #require(started, "Fresh local-match asset read did not start")
    }
}

/// 独立原子JSON资料的权限、格式及账号隔离，真实文件全部在每个测试自己的临时目录。
@Suite("Local media atomic recovery")
struct LocalMediaAssociationStoreTests {
    /// 真实详情wire缺失状态保持未知，ISO版本精确解码；不能因可选字段缺失而合成false。
    @Test(arguments: ["2026-11-24T13:30:00.123Z", "2026-11-24T13:30:00Z"])
    func freshWireKeepsMissingStatesUnknown(_ date: String) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["id": matchRemoteID.uuidString, "ownerId": matchOwnerID.uuidString, "type": "IMAGE", "updatedAt": date])
        let value = try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: bytes)
        #expect(value.isTrashed == nil && value.isOffline == nil && value.isEdited == nil && value.checksum == nil && value.updatedAt != nil)
        #expect(LocalMediaAssociation.verified(remote: value, requestedID: matchRemoteID, ownerID: matchOwnerID.uuidString, local: matchSnapshot().identity, source: .mobileMetadata) == nil)
    }

    /// 错误/截断/额外后缀日期拒绝解码，不能成为nil后继续与未知版本匹配。
    @Test(arguments: ["invalid", "2026-11-24", "2026-11-24T13:30:00Zextra"])
    func malformedFreshVersionsThrow(_ date: String) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["id": matchRemoteID.uuidString, "ownerId": matchOwnerID.uuidString, "type": "IMAGE", "updatedAt": date])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: bytes) }
    }

    /// 许可撤销后不能写；未知未来格式拒绝覆盖，原始字节保留。
    @Test func revokedWritesAndFutureDocumentsCannotOverwrite() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaAssociationStore(directory: directory)
        let scope = MediaAccountScope(session: matchSession())
        let permit = LocalMediaSavePermit(); permit.invalidate()
        let revoked = try await store.save(.init(scope: scope, enabled: true, access: nil, associations: []), scope: scope, permit: permit)
        #expect(!revoked)
        let missing = try await store.load(scope: scope); #expect(missing == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
        let bytes = try JSONSerialization.data(withJSONObject: ["formatVersion": 2, "namespace": scope.cacheNamespace, "enabled": true, "associations": []])
        try bytes.write(to: path)
        await #expect(throws: LocalMediaMetadataError.invalidMetadata) {
            try await store.save(.init(scope: scope, enabled: false, access: nil, associations: []), scope: scope, permit: LocalMediaSavePermit())
        }
        #expect(try Data(contentsOf: path) == bytes)
    }

    /// 两个用户的配置文件互不覆盖，JSON往返保留精确源/远端版本与来源。
    @Test func namespacesAndAssociationVersionsRemainSeparate() async throws {
        let directory = temporaryMatchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaAssociationStore(directory: directory)
        let first = MediaAccountScope(session: matchSession())
        let second = MediaAccountScope(session: matchSession(owner: "22222222-2222-4222-8222-222222222222"))
        let association = LocalMediaAssociation(remoteID: matchRemoteID, remoteRevision: matchRevision, localIdentity: matchSnapshot().identity,
                                                checksum: matchChecksum, source: .mobileMetadata)
        _ = try await store.save(.init(scope: first, enabled: true, access: .full, associations: [association]), scope: first, permit: LocalMediaSavePermit())
        _ = try await store.save(.init(scope: second, enabled: false, access: nil, associations: []), scope: second, permit: LocalMediaSavePermit())
        let cold = LocalMediaAssociationStore(directory: directory)
        let a = try await cold.load(scope: first); let b = try await cold.load(scope: second)
        #expect(a?.enabled == true && a?.associations == [association] && b?.enabled == false && b?.associations.isEmpty == true)
    }
}

private nonisolated let matchRemoteID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private nonisolated let matchOwnerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let matchRevision = Date(timeIntervalSince1970: 100.123)
private nonisolated let matchChecksum = Data(repeating: 0xAA, count: 20).base64EncodedString()

/// 每例唯一临时根目录，便于确定清理且避免测试间共享账号恢复资料。
private nonisolated func temporaryMatchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("LocalMatch-\(UUID())", isDirectory: true)
}

/// 只有合成账号字段；真实client不会被调用，所有远端操作都经过只读actor边界。
private nonisolated func matchSession(owner: String = "11111111-1111-4111-8111-111111111111") -> AccountSession {
    .init(apiURL: URL(string: "https://local-match.invalid/api")!, accessToken: "synthetic-no-network", userID: owner,
          userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 公开资源描述为单一JPEG，cloud状态由场景控制，不读取真实库或文件。
private nonisolated func matchSnapshot(localID: String = "synthetic-local", cloud: LocalPhotoCloudIdentity = .resolved("synthetic-cloud:complete")) -> LocalPhotoSnapshot {
    .init(identity: .init(localIdentifier: localID, modificationDate: Date(timeIntervalSince1970: 15), mediaKind: .image),
          creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
          pixelWidth: 64, pixelHeight: 48, duration: 0, mediaSubtypes: 0,
          resources: [.init(type: 1, role: .originalPhoto, originalFilename: "synthetic.jpg", uniformTypeIdentifier: "public.jpeg", pixelWidth: 64, pixelHeight: 48)], cloudIdentity: cloud)
}

/// 单一字段失效用于验证真实领域门禁；默认是新鲜同owner/类型/未编辑资源。
private nonisolated func matchAsset(_ mode: String = "valid") -> LocalMediaRemoteAsset {
    .init(id: mode == "id" ? UUID() : matchRemoteID, ownerId: mode == "owner" ? UUID() : matchOwnerID, type: mode == "type" ? "VIDEO" : "IMAGE",
          isTrashed: mode == "trash", isOffline: mode == "unknown-offline" ? nil : mode == "offline", isEdited: mode == "unknown-edited" ? nil : mode == "edited",
          checksum: mode == "checksum" ? "invalid" : mode == "different-checksum" ? Data(repeating: 0xBB, count: 20).base64EncodedString() : matchChecksum,
          updatedAt: mode == "version" ? nil : matchRevision)
}

/// 真实JSONDecoder消费官方mobile-app字符串wire，元数据本身不带fresh安全字段。
private nonisolated func matchRecord() throws -> LocalMediaRemoteMetadataRecord {
    try .init(assetID: matchRemoteID, value: JSONSerialization.data(withJSONObject: ["iCloudId": "synthetic-cloud:complete", "createdAt": "1970-01-01T00:00:10Z"]))
}

/// 使用真实proof构造器验证单一未编辑资源政策；摘要是合成值，不伪造读取真实照片的证据。
private nonisolated func matchProof(_ source: LocalPhotoSnapshot) throws -> LocalPhotoChecksumProof {
    let source = source.withCloudIdentity(.unavailable)
    let resource = LocalPhotoChecksumResource(descriptor: source.resources[0], format: .image)
    return try .init(asset: .init(snapshot: source, resources: [resource]), resource: resource,
                     digest: .init(sha1Hex: String(repeating: "aa", count: 20), byteCount: 5))
}

/// 准备真实Controller、真实原子JSON存储及有限合成系统边界，manager仅提供真实scope/generation门禁。
@MainActor private func matchFixture(directory: URL, snapshot: LocalPhotoSnapshot = matchSnapshot(), inventory: MatchInventory? = nil,
                                     metadata: MatchMetadata? = nil, remote: MatchRemote? = nil, checksum: MatchChecksum? = nil) throws -> MatchFixture
{
    let manager = LibraryManagementController(); let session = matchSession(); manager.configure(session: session, endpoint: session.apiURL)
    let inventory = inventory ?? MatchInventory(ids: [snapshot.identity.localIdentifier])
    let metadata = metadata ?? MatchMetadata(snapshots: [snapshot])
    let remote = try remote ?? MatchRemote(records: [matchRecord()], asset: matchAsset())
    let checksum = checksum ?? MatchChecksum()
    let store = LocalMediaAssociationStore(directory: directory)
    let controller = LocalMediaMatchController(inventory: inventory, metadata: metadata, checksum: checksum, remote: remote, persistence: store, observeChanges: false)
    controller.configure(using: manager, scope: .init(session: session))
    return .init(controller: controller, manager: manager, scope: .init(session: session), store: store, inventory: inventory, metadata: metadata, remote: remote, checksum: checksum, snapshot: snapshot)
}

/// 只保存单例测试依赖，不另造Controller状态或通过fixture推导匹配结果。
@MainActor private struct MatchFixture {
    let controller: LocalMediaMatchController
    let manager: LibraryManagementController
    let scope: MediaAccountScope
    let store: LocalMediaAssociationStore
    let inventory: MatchInventory
    let metadata: MatchMetadata
    let remote: MatchRemote
    let checksum: MatchChecksum
    let snapshot: LocalPhotoSnapshot
}

/// 当前Photos身份清单与授权替身；不模拟Controller的版本、账户、匹配或存储规则。
@MainActor private final class MatchInventory: LocalPhotoInventoryReading {
    var authorization = LocalPhotoLibraryAccess.full
    private(set) var authorizationRequests = 0
    let ids: [String]
    /// ids保留输入顺序，以验证产品batch边界。
    init(ids: [String]) {
        self.ids = ids
    }

    /// 只记录明确授权动作，自动刷新场景必须保持零次。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorizationRequests += 1; return authorization
    }

    /// validateContext实际执行，身份值只来自本例合成清单。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return ids
    }
}

/// 每次返回指定ID公开观察，保留请求大小供真实Controller有界扫描断言。
@MainActor private final class MatchMetadata: LocalPhotoMetadataReading {
    private let values: [String: LocalPhotoSnapshot]
    private(set) var batchCounts: [Int] = []
    /// snapshots唯一键来自每例合成清单，不生成额外照片。
    init(snapshots: [LocalPhotoSnapshot]) {
        values = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.localIdentifier, $0) })
    }

    /// IDs由真实Controller分批；不在fixture中修正重复/越界输入。
    func snapshots(for localIdentifiers: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext(); batchCounts.append(localIdentifiers.count); return localIdentifiers.compactMap { values[$0] }
    }
}

/// 只替换本机字节读取，真实Controller仍决定何时hash以及如何查验fresh远端响应。
@MainActor private final class MatchChecksum: LocalPhotoChecksumReading {
    private let proof: LocalPhotoChecksumProof?
    private(set) var requests = 0
    /// nil表示云上-only不足，不会返回空摘要或请求上传。
    init(proof: LocalPhotoChecksumProof? = nil) {
        self.proof = proof
    }

    /// expected仍由真实Controller传入，validateContext在模拟await边界执行。
    func checksum(for _: LocalPhotoSnapshot, validateContext: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        try validateContext(); requests += 1
        return proof.map(LocalPhotoChecksumOutcome.verified) ?? .insufficient(.notLocallyAvailable)
    }
}

/// actor只替换读取源，持有fresh响应可观察账户/取消的真实迟到路径；没有媒体或写接口。
private actor MatchRemote: LocalMediaMatchingReading {
    private let records: [LocalMediaRemoteMetadataRecord]
    private let asset: LocalMediaRemoteAsset
    private let lookupMode: String
    private let metadataMode: String
    private let holdAsset: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var assetStarted = false
    private(set) var calls: [String] = []
    private(set) var digests: [LocalPhotoByteDigest] = []
    /// records/asset为固定响应，holdAsset只控制fresh await，不绕过真实Controller。
    init(records: [LocalMediaRemoteMetadataRecord], asset: LocalMediaRemoteAsset, lookupMode: String = "existing", holdAsset: Bool = false, metadataMode: String = "valid") {
        self.records = records; self.asset = asset; self.lookupMode = lookupMode; self.holdAsset = holdAsset; self.metadataMode = metadataMode
    }

    /// cloudIDs实际请求被记录，返回已准备的完整metadata候选。
    func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        calls.append("metadata")
        switch metadataMode {
        case "checkpoint": throw LocalMediaMetadataStreamError.metadataCheckpointExists
        case "unsupported": throw LibraryWriteError.http(404)
        case "incomplete": throw LocalMediaMetadataStreamError.incomplete
        case "cancelled": throw CancellationError()
        case "bad-record":
            return try [.init(assetID: matchRemoteID, value: JSONSerialization.data(withJSONObject: ["iCloudId": "synthetic-cloud:complete", "createdAt": "bad-date"]))]
        default: return records
        }
    }

    /// 正常/迟到fresh读取均返回同一资料，取消不会替fixture自动过滤响应。
    func localMediaAsset(_: String) async throws -> LocalMediaRemoteAsset {
        calls.append("asset"); assetStarted = true
        if holdAsset, !released {
            await withCheckedContinuation { gate = $0 }
        }
        return asset
    }

    /// 放行真实await，失败测试cleanup也调用，避免遗留等待者。
    func releaseAsset() {
        released = true; gate?.resume(); gate = nil
    }

    /// 保留query对应关系或故意违反ID，outcome只表示查找，不发起上传。
    func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        calls.append("checksum"); digests += queries.map(\.digest)
        return queries.map { query in
            let outcome: LocalMediaChecksumLookup.Outcome = lookupMode == "trashed" ? .trashed(asset.id) : lookupMode == "no-match" ? .noMatch : .existing(asset.id)
            return .init(id: lookupMode == "wrong-query" ? UUID() : query.id, outcome: outcome)
        }
    }
}
