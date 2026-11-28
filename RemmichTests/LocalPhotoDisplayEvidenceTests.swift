import Foundation
import Testing
@testable import Remmich

@Suite("Display-only iCloud identity evidence")
@MainActor struct LocalPhotoDisplayEvidenceTests {
    /// 真正客户端只读取资产与metadata；marker不能被补造成完整五元组或任何媒体读取。
    @Test func markerOnlyRemainsDisplayIdentity() async throws {
        let id = UUID()
        let fixture = displayEvidenceFixture(id: id, metadata: "[" + displayMarkerJSON(cloud: "synthetic-cloud") + "]")
        defer { fixture.close() }
        let evidence = try await #require(fixture.manager.client).localPhotoDisplayEvidenceRecord(id)
        #expect(evidence.remote.id == id && evidence.fullMetadataCandidates.isEmpty)
        #expect(evidence.cloudIDs == Set(["synthetic-cloud"]))
        #expect(evidence.displaySource(for: "synthetic-cloud") == .exactCloudIdentity)
        #expect(evidence.metadataDiagnostics.contains("markerOnly") && !evidence.metadataDiagnostics.contains("rowsEmpty"))
        let requests = await fixture.script.requests()
        #expect(requests.count == 2 && requests.allSatisfy { $0.method == "GET" && $0.body == nil })
    }

    /// 保留旧tuple合同：只有轻量marker时，旧方法仍返回空完整元数据候选。
    @Test func legacyTupleDoesNotUpgradeMarker() async throws {
        let id = UUID()
        let fixture = displayEvidenceFixture(id: id, metadata: "[" + displayMarkerJSON(cloud: "synthetic-cloud") + "]")
        defer { fixture.close() }
        let (remote, candidates) = try await #require(fixture.manager.client).localPhotoDisplayEvidence(id)
        #expect(remote.id == id && candidates.isEmpty)
    }

    @Test func emptyRowsAreDistinctFromMarkerOnly() async throws {
        let id = UUID()
        let fixture = displayEvidenceFixture(id: id, metadata: "[]")
        defer { fixture.close() }
        let evidence = try await #require(fixture.manager.client).localPhotoDisplayEvidenceRecord(id)
        #expect(evidence.cloudIDs.isEmpty && evidence.metadataDiagnostics == Set(["rowsEmpty"]))
    }

    /// 可选marker格式错误不能遮蔽合法mobile-app；不使用本机字段补造服务器元组。
    @Test(arguments: ["version", "method", "cloud", "missing-bool", "numeric-bool", "byte-proof"])
    func malformedOptionalMarkerDoesNotHideOfficialMetadata(_ invalid: String) async throws {
        let id = UUID()
        var marker = displayMarkerJSON(cloud: "synthetic-cloud")
        switch invalid {
        case "version": marker = marker.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        case "method": marker = marker.replacingOccurrences(of: "icloud-id", with: "sha1")
        case "cloud": marker = marker.replacingOccurrences(of: "synthetic-cloud", with: "incomplete:")
        case "missing-bool": marker = marker.replacingOccurrences(of: #", "byteVerified":false"#, with: "")
        case "byte-proof": marker = marker.replacingOccurrences(of: #""byteVerified":false"#, with: #""byteVerified":true"#)
        default: marker = marker.replacingOccurrences(of: #""byteVerified":false"#, with: #""byteVerified":1"#)
        }
        let official = #"{"key":"mobile-app","value":{"iCloudId":"official-cloud","createdAt":"2025-01-01T00:00:00Z"}}"#
        let fixture = displayEvidenceFixture(id: id, metadata: "[" + marker + "," + official + "]")
        defer { fixture.close() }
        let evidence = try await #require(fixture.manager.client).localPhotoDisplayEvidenceRecord(id)
        #expect(evidence.cloudIdentityCandidates.isEmpty && evidence.fullMetadataCandidates.count == 1)
        #expect(evidence.cloudIDs == Set(["official-cloud"]))
        #expect(evidence.metadataDiagnostics.contains("markerRejected"))
        #expect(evidence.fullMetadataCandidates.first?.metadata.createdAt == Date(timeIntervalSince1970: 1_735_689_600))
    }

    /// 不同有效来源不能因其中一份正好可见就绕过冲突，保持未知而非宣称本机不存在。
    @Test func conflictingCloudIdentitySourcesRemainExplicit() async throws {
        let id = UUID()
        let official = #"{"key":"mobile-app","value":{"iCloudId":"other-cloud"}}"#
        let fixture = displayEvidenceFixture(id: id, metadata: "[" + displayMarkerJSON(cloud: "marker-cloud") + "," + official + "]")
        defer { fixture.close() }
        let evidence = try await #require(fixture.manager.client).localPhotoDisplayEvidenceRecord(id)
        #expect(evidence.hasConflictingIdentitySources && evidence.cloudIDs.count == 2)
    }

    /// 新source只能用于Photos展示；fresh拥有者/类型/状态与本机版本门禁仍生效。
    @Test func exactCloudIdentityCannotBecomeByteOrOrganizationProof() throws {
        let id = UUID(), owner = UUID()
        let checksum = Data(repeating: 1, count: 20).base64EncodedString()
        let remote = LocalMediaRemoteAsset(id: id, ownerId: owner, type: "IMAGE", isTrashed: false,
                                           isOffline: false, isEdited: false, checksum: checksum, updatedAt: Date(timeIntervalSince1970: 100))
        let local = localMediaSnapshot().identity
        #expect(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: owner.uuidString,
                                               local: local, source: .exactCloudIdentity) == nil)
        #expect(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: owner.uuidString,
                                               local: local, source: .exactCloudIdentity, expectedChecksum: checksum, prefersCurrentPhotos: true) == nil)
        let display = try #require(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: owner.uuidString,
                                                                  local: local, source: .exactCloudIdentity, prefersCurrentPhotos: true))
        #expect(display.source == .exactCloudIdentity)
        #expect(try JSONDecoder().decode(LocalMediaAssociation.self, from: JSONEncoder().encode(display)) == display)
        #expect(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: UUID().uuidString,
                                               local: local, source: .exactCloudIdentity, prefersCurrentPhotos: true) == nil)
        let video = LocalPhotoIdentity(localIdentifier: local.localIdentifier, modificationDate: local.modificationDate, mediaKind: .video)
        #expect(LocalMediaAssociation.verified(remote: remote, requestedID: id, ownerID: owner.uuidString,
                                               local: video, source: .exactCloudIdentity, prefersCurrentPhotos: true) == nil)
        let trashed = LocalMediaRemoteAsset(id: id, ownerId: owner, type: "IMAGE", isTrashed: true,
                                            isOffline: false, isEdited: false, checksum: checksum, updatedAt: remote.updatedAt)
        #expect(LocalMediaAssociation.verified(remote: trashed, requestedID: id, ownerID: owner.uuidString,
                                               local: local, source: .exactCloudIdentity, prefersCurrentPhotos: true) == nil)
    }

    /// sidecar并发merge与legacy全份save可交错，文件及强来源均不被弱展示关系覆盖。
    @Test func displaySidecarNeverOverwritesLegacyOrStrongerRelationship() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("display-sidecar-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ChecksumLookupHTTPFixture(exchanges: [])
        defer { fixture.close() }
        let scope = try #require(fixture.manager.backupScope)
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        let legacy = LocalMediaAssociationStore(directory: legacyDirectory)
        let sidecar = LocalPhotoDisplayAssociationStore(directory: directory.appendingPathComponent("display", isDirectory: true))
        let permit = LocalMediaSavePermit(), id = UUID()
        let strong = displayStoredAssociation(id: id, localID: "strong-local", source: .checksum)
        let document = LocalMediaAssociationDocument(scope: scope, enabled: true, access: .full, associations: [strong], followsBackup: true)
        #expect(try await legacy.save(document, scope: scope, permit: permit))
        let legacyFile = legacyDirectory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
        let before = try Data(contentsOf: legacyFile)
        let weak = displayStoredAssociation(id: id, localID: "weak-local", source: .exactCloudIdentity)
        let others = (0 ..< 8).map { displayStoredAssociation(id: UUID(), localID: "synthetic-\($0)", source: .exactCloudIdentity) }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await legacy.save(document, scope: scope, permit: permit) }
            for value in [weak] + others {
                group.addTask { try await sidecar.merge(value, scope: scope, access: .full, permit: permit) }
            }
            for try await saved in group {
                #expect(saved)
            }
        }
        let legacyAfterConcurrentWrites = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as? NSDictionary
        let legacyBeforeConcurrentWrites = try JSONSerialization.jsonObject(with: before) as? NSDictionary
        #expect(legacyAfterConcurrentWrites == legacyBeforeConcurrentWrites && legacyAfterConcurrentWrites != nil)
        #expect(try await legacy.load(scope: scope)?.associations == [strong])
        #expect(try await sidecar.load(scope: scope, access: .full).count == 9)
        #expect(try await sidecar.load(scope: scope, access: .limited).isEmpty)
        let controller = LocalMediaMatchController(inventory: DisplayEvidenceInventory(), persistence: legacy,
                                                   displayPersistence: sidecar, observeChanges: false)
        let restored = try #require(controller.restoreAndRefresh(using: fixture.manager, scope: scope))
        await restored.value
        #expect(controller.association(assetID: id.uuidString, revision: strong.remoteRevision) == strong)
        await controller.beginBackupMatching(using: fixture.manager)
        #expect(try await legacy.load(scope: scope)?.associations == [strong])
        let legacyBeforeSidecarRemoval = try Data(contentsOf: legacyFile)
        #expect(try await sidecar.remove(id, scope: scope, permit: permit))
        #expect(try Data(contentsOf: legacyFile) == legacyBeforeSidecarRemoval)
        let reloadedSidecar = LocalPhotoDisplayAssociationStore(directory: directory.appendingPathComponent("display", isDirectory: true))
        #expect(try await reloadedSidecar.load(scope: scope, access: .full).allSatisfy { $0.remoteID != id })
        let badDocument = LocalMediaAssociationDocument(scope: scope, enabled: true, access: .full, associations: [weak])
        await #expect(throws: LocalMediaMetadataError.invalidMetadata) { _ = try await legacy.save(badDocument, scope: scope, permit: permit) }
        let revoked = LocalMediaSavePermit(); revoked.invalidate()
        #expect(try await sidecar.merge(displayStoredAssociation(id: UUID(), localID: "revoked", source: .exactCloudIdentity),
                                        scope: scope, access: .full, permit: revoked) == false)
        #expect(try await sidecar.load(scope: scope, access: .full).count == 8)
    }
}

private nonisolated func displayMarkerJSON(cloud: String, byteVerified: Bool = false) -> String {
    #"{"key":"remmich-icloud-match","value":{"version":1,"method":"icloud-id","iCloudId":"\#(cloud)", "byteVerified":\#(byteVerified)}}"#
}

@MainActor private func displayEvidenceFixture(id: UUID, metadata: String) -> ChecksumLookupHTTPFixture {
    let canonical = id.uuidString.lowercased()
    let asset = #"{"id":"\#(canonical)","ownerId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","type":"IMAGE","isTrashed":false,"isOffline":false,"isEdited":false,"checksum":"AQEBAQEBAQEBAQEBAQEBAQEBAQE=","updatedAt":"2026-11-28T00:00:00Z"}"#
    return ChecksumLookupHTTPFixture(exchanges: [.init(method: "GET", path: "assets/" + canonical, status: 200, json: asset),
                                                 .init(method: "GET", path: "assets/" + canonical + "/metadata", status: 200, json: metadata)])
}

private nonisolated func displayStoredAssociation(id: UUID, localID: String, source: LocalMediaAssociation.Source) -> LocalMediaAssociation {
    .init(remoteID: id, remoteRevision: Date(timeIntervalSince1970: 100),
          localIdentity: .init(localIdentifier: localID, modificationDate: Date(timeIntervalSince1970: 50), mediaKind: .image),
          checksum: Data(repeating: 1, count: 20).base64EncodedString(), source: source)
}

@MainActor private struct DisplayEvidenceInventory: LocalPhotoInventoryReading {
    let authorization = LocalPhotoLibraryAccess.full
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorization
    }

    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return []
    }
}
