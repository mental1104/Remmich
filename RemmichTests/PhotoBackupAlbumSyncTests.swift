import Foundation
import Photos
import SQLite3
import Synchronization
import Testing
@testable import Remmich

/// 真实匹配Controller冷恢复→当前GET metadata证明→组织Controller/SQLite→HTTP；系统边界和服务响应为合成值。
@Suite("Explicit linked backup albums")
struct PhotoBackupAlbumSyncTests {
    /// 服务端已有交集没有上传任务；两种匹配provenance都能补入，metadata不要求本机hash，重复预览只核查不重加。
    @Test(.timeLimit(.minutes(1)), arguments: [LocalMediaAssociation.Source.mobileMetadata, .checksum], [PhotoBackupSource.Kind.photo, .video])
    @MainActor func serverExistingAssetsUseFreshCurrentAssociations(_ provenance: LocalMediaAssociation.Source, kind: PhotoBackupSource.Kind) async throws {
        try await withAlbumSyncFixture(kind: kind, provenance: provenance) { fixture in
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.targets.count == 2 && fixture.sync.previewCount == 1)
            #expect(fixture.sync.state.operations.first?.assets.first?.proof == (provenance == .mobileMetadata ? .metadataAssociation : .checksumAssociation))
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            let cold = try await fixture.coldState()
            #expect(cold.operations.first?.phase == .confirmed && cold.mappings.first?.targetID == albumSyncTarget2)
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2))
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget1) == false)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            try await fixture.mapAndPrepare(saveMapping: false)
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(fixture.photos.hashReads == 0 && fixture.photos.authorizationRequests == 0)
            #expect(await fixture.server.onlyMetadataAndMembershipRoutes())
        }
    }

    /// 改变当前metadata/remote revision/owner/checksum均不能靠旧UUID入组；当前source版本不等也失效。
    @Test(.timeLimit(.minutes(1)), arguments: ["metadata", "revision", "owner", "checksum", "source"])
    @MainActor func staleAssociationCannotAuthorizeOrganization(_ mode: String) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setMismatch(mode)
            if mode == "source" {
                fixture.photos.modified = Date(timeIntervalSince1970: 101)
            }
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 0 && fixture.sync.unmatched == 1)
            #expect(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup) == nil)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
            #expect(fixture.photos.hashReads == 0)
        }
    }

    /// 当前照片同时在已保存排除相簿，即使服务器已存在且本机已匹配，也不能自动补入任何映射目标。
    @Test(.timeLimit(.minutes(1))) @MainActor func exclusionAlsoAppliesToServerExistingAssets() async throws {
        try await withAlbumSyncFixture { fixture in
            fixture.photos.excluded = true
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 0 && fixture.sync.state.operations.isEmpty)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
        }
    }

    /// 同一已存在照片保留两本地相簿的成员关系；两个明确映射均需实际PUT和独立确认，不能全库去重后丢掉第二关系。
    @Test(.timeLimit(.minutes(1))) @MainActor func sharedLocalMemberIsAddedToBothExplicitTargets() async throws {
        try await withAlbumSyncFixture(includeSecond: true) { fixture in
            await fixture.run(fixture.sync.setMapping(localID: "include", targetID: albumSyncTarget1, using: fixture.manager, backup: fixture.backup))
            await fixture.run(fixture.sync.setMapping(localID: "include2", targetID: albumSyncTarget2, using: fixture.manager, backup: fixture.backup))
            await fixture.run(fixture.sync.prepare(using: fixture.manager, backup: fixture.backup))
            #expect(fixture.sync.previewCount == 2)
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            let cold = try await fixture.coldState()
            #expect(cold.operations.count == 2 && cold.operations.allSatisfy { $0.phase == .confirmed })
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget1))
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 2)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            #expect(fixture.photos.hashReads == 0 && fixture.photos.authorizationRequests == 0)
        }
    }

    /// 用户确认前服务端/本地证据变更也须重核；不能因预览曾合法便用旧计划写关系。
    @Test(.timeLimit(.minutes(1)), arguments: ["metadata", "revision", "owner", "checksum", "source", "target", "locked", "offline", "trashed"])
    @MainActor func previewDoesNotAuthorizeLaterChangedEvidence(_ mode: String) async throws {
        try await withAlbumSyncFixture { fixture in
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 1)
            await fixture.server.setMismatch(mode)
            if mode == "source" {
                fixture.photos.modified = Date(timeIntervalSince1970: 101)
            }
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
            #expect(try await fixture.coldState().operations.first?.phase != .confirmed)
            #expect(fixture.photos.hashReads == 0)
        }
    }

    /// Live按逻辑PhotoKit源使用still一UUID，motion没有成员写入；组织确认不冒充原片/配对备份完成。
    @Test(.timeLimit(.minutes(1))) @MainActor func livePhotoOnlyAddsItsStill() async throws {
        try await withAlbumSyncFixture(kind: .livePhoto) { fixture in
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(await fixture.server.putCount(albumSyncMotion) == 0)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            #expect(fixture.photos.hashReads == 0)
        }
    }

    /// 双原图第二份无权限只保留第一份组织回执；冷恢复先核成员再补JPEG，不重加RAW，也不改上传完成。
    @Test(.timeLimit(.minutes(1))) @MainActor func rawJPEGPartialOrganizationResumesWithoutReaddingRAW() async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG) { fixture in
            await fixture.server.setMode(.denyJPEG)
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            let partial = try await fixture.coldState()
            #expect(partial.operations.first?.phase == .failed && partial.operations.first?.confirmedAssetIDs == [albumSyncPrimary])
            #expect(fixture.sync.confirmed == 0 && fixture.sync.previewCount == 1)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.first?.stage == .completed)
            await fixture.server.setMode(.normal)
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(restored.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(await fixture.server.putCount(albumSyncJPEG) == 2)
            #expect(restored.confirmed == 1 && fixture.photos.hashReads == 0)
        }
    }

    /// 历史双确认不能代替本轮重核：第二份fresh GET真正挂起时取消，冷账本不得在只核过RAW后提前再次confirmed。
    @Test(.timeLimit(.minutes(1))) @MainActor func historicalPairReceiptsCannotCompleteHalfOfAFreshPass() async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG) { fixture in
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            await fixture.server.removeMember(albumSyncJPEG, target: albumSyncTarget2)
            try await fixture.mapAndPrepare(saveMapping: false)
            await fixture.server.setMode(.heldJPEGRead)
            await fixture.server.beginObservedWork()
            let old = try #require(fixture.track(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup)))
            try #require(await fixture.server.waitUntilHeld())
            let held = try await fixture.coldState()
            #expect(held.operations.first?.phase == .queued)
            #expect(held.operations.first?.confirmedAssetIDs == [albumSyncPrimary, albumSyncJPEG])
            fixture.sync.cancel()
            await fixture.server.release()
            await old.value
            #expect(try await fixture.coldState().operations.first?.phase != .confirmed)
            #expect(await fixture.server.putCount(albumSyncJPEG) == 1)
            await fixture.server.setMode(.normal)
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(restored.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(await fixture.server.putCount(albumSyncJPEG) == 2)
        }
    }

    /// duplicate与响应丢失但实际已加入都须fresh核成员；成功HTTP却未入组保留unknown，不能用200冒充成功。
    @Test(.timeLimit(.minutes(1)), arguments: [AlbumSyncHTTPServer.Mode.duplicate, .errorAfterCommit, .missingAfterSuccess])
    @MainActor private func acknowledgementsAndUnknownOutcomesRequireFreshMembership(_ mode: AlbumSyncHTTPServer.Mode) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setMode(mode)
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            let cold = try await fixture.coldState()
            #expect(cold.operations.first?.phase == (mode == .missingAfterSuccess ? .unknown : .confirmed))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            await fixture.server.setMode(.normal)
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(restored.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == (mode == .missingAfterSuccess ? 2 : 1))
        }
    }

    /// HTTP已发送后真正取消/换号；旧回调不落成功，sending可冷读为unknown，再恢复先查实际成员而非重放PUT。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func lateHTTPCannotPublishAfterCancellationOrAccountRetirement(_ account: Bool) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setMode(.heldAfterCommit)
            try await fixture.mapAndPrepare()
            await fixture.server.beginObservedWork()
            let old = try #require(fixture.track(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup)))
            try #require(await fixture.server.waitUntilHeld())
            let other = AccountSession(apiURL: fixture.endpoint, accessToken: "album-sync-fixture", userID: albumSyncTarget1.uuidString,
                                       userEmail: "other@example.invalid", name: "Other", isAdmin: false, serverVersion: fixture.session.serverVersion)
            let otherScope = MediaAccountScope(session: other)
            if account {
                try await fixture.store.prepare(scope: otherScope)
                try await fixture.store.savePhotoBackups(.init(namespace: otherScope.cacheNamespace), scope: otherScope)
                try await fixture.store.savePhotoBackupAlbumSyncPlan(.init(namespace: otherScope.cacheNamespace), scope: otherScope)
                fixture.manager.configure(session: other, endpoint: fixture.endpoint)
                fixture.matching.configure(using: fixture.manager, scope: otherScope)
                await fixture.backup.load(using: fixture.manager)
            }
            fixture.sync.cancel()
            await fixture.server.release()
            await old.value
            #expect(try await fixture.coldState().operations.first?.phase == .sending)
            if account {
                #expect(fixture.backup.selected.isEmpty && fixture.backup.jobs.isEmpty)
                #expect(try await fixture.store.loadPhotoBackupAlbumSync(scope: otherScope).operations.isEmpty)
            }
            await fixture.restoreAccount()
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            #expect(restored.state.operations.first?.phase == .unknown)
            await fixture.server.setMode(.normal)
            await fixture.run(restored.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
        }
    }

    /// 未保存草稿和Photos权限撤销阻断组织入口；不会把页面选择偷偷写入保存规则。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func draftAndPermissionCannotBeSavedAsOrganizationConsent(_ denied: Bool) async throws {
        try await withAlbumSyncFixture { fixture in
            try await fixture.mapAndPrepare()
            if denied {
                fixture.photos.authorization = .denied
            } else {
                fixture.backup.excluded = ["draft"]
            }
            #expect(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup) == nil)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).excludedAlbumIDs == ["exclude"])
        }
    }

    /// 没有上传任务的服务器双原图交集，必须经两份真实SHA1流和两次fresh解析；组织不增加上传任务。
    @Test(.timeLimit(.minutes(1))) @MainActor func existingRAWJPEGUsesBothLocalByteStreamsAndFreshRemoteIDs() async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            try await fixture.mapAndPrepare()
            let preview = try await fixture.coldState()
            let operation = try #require(preview.operations.first)
            #expect(preview.version == 3 && !preview.automaticEnabled && fixture.sync.previewCount == 1)
            #expect(operation.assets.map(\.proof) == [.rawJPEGChecksum, .rawJPEGChecksum])
            #expect(operation.assets.map(\.assetID) == [albumSyncPrimary, albumSyncJPEG])
            #expect(operation.assets.map(\.checksum) == [albumSyncLocalRawDigest, albumSyncLocalJPEGDigest])
            #expect(operation.assets.allSatisfy { $0.revision == albumSyncRevision })
            let previewLookups = await fixture.server.lookupCount()
            #expect(fixture.photos.rawReadRoles == [.raw, .jpeg] && previewLookups == 1)
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            let cold = try await fixture.coldState()
            #expect(cold.operations.first?.phase == .confirmed && cold.operations.first?.confirmedAssetIDs == [albumSyncPrimary, albumSyncJPEG])
            let confirmedLookups = await fixture.server.lookupCount()
            #expect(fixture.photos.rawReadRoles == [.raw, .jpeg, .raw, .jpeg] && confirmedLookups == 2)
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2))
            #expect(await fixture.server.member(albumSyncJPEG, target: albumSyncTarget2))
            #expect(await fixture.server.onlyMetadataAndMembershipRoutes(allowChecksum: true))
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            #expect(fixture.photos.hashReads == 0 && fixture.photos.authorizationRequests == 0)
        }
    }

    /// 缺一UUID、双角色同UUID、回收站/未知状态/locked/类型/owner/摘要矛盾都不能拿单图或metadata入组。
    @Test(.timeLimit(.minutes(1)), arguments: ["missing-raw", "same-uuid", "trashed-duplicate", "locked", "offline", "owner", "checksum", "type", "unknown-online", "unknown-version", "id"])
    @MainActor func incompleteOrUnsafeRAWIntersectionNeverEntersAPlan(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            await fixture.server.setMismatch(mode)
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 0 && fixture.sync.unmatched == 1)
            #expect(try await fixture.coldState().operations.isEmpty)
            let lookups = await fixture.server.lookupCount(), rawPuts = await fixture.server.putCount(albumSyncPrimary), jpegPuts = await fixture.server.putCount(albumSyncJPEG)
            #expect(fixture.photos.rawReadRoles == [.raw, .jpeg] && lookups == 1)
            #expect(rawPuts == 0 && jpegPuts == 0)
            #expect(await fixture.server.onlyMetadataAndMembershipRoutes(allowChecksum: true))
        }
    }

    /// 本机只读云端不足、编辑或两份流之间换版均停止证明，不查服务器、更不偷偷开启iCloud。
    @Test(.timeLimit(.minutes(1)), arguments: ["cloud-only", "edited", "version", "same-bytes"])
    @MainActor func incompleteLocalRAWProofStopsBeforeServerLookup(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            fixture.photos.rawReadFailure = mode == "cloud-only" ? .networkRequired : nil
            fixture.photos.rawAdjusted = mode == "edited"
            fixture.photos.rawChangeOnJPEG = mode == "version"
            fixture.photos.rawSameBytes = mode == "same-bytes"
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 0)
            #expect(try await fixture.coldState().operations.isEmpty)
            #expect(await fixture.server.lookupCount() == 0)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
            #expect(fixture.photos.authorizationRequests == 0)
        }
    }

    /// 首份真实SHA1流结束后权限/上下文变化，reader必须停止，不继续读取JPEG或发布部分证明。
    @Test(.timeLimit(.minutes(1)), arguments: ["permission", "context"])
    @MainActor func RAWReaderStopsAtEachActualAsyncBoundary(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            var permission = PHAuthorizationStatus.authorized, current = true
            let reader = PhotoKitRawJPEGChecksumReader(source: { _ in try fixture.photos.rawObservation() }, bytes: { _, resource in
                let digest = try await fixture.photos.rawBytes(resource)
                if resource.format == .raw {
                    if mode == "permission" {
                        permission = .denied
                    } else {
                        current = false
                    }
                }
                return digest
            }, authorization: { permission })
            await #expect(throws: LocalPhotoChecksumError.self) {
                _ = try await reader.checksumPair(for: fixture.photos.source, validateContext: {
                    guard current else { throw LocalPhotoChecksumError.sourceChanged }
                })
            }
            #expect(fixture.photos.rawReadRoles == [.raw])
            #expect(await fixture.server.lookupCount() == 0)
        }
    }

    /// 已读完双原图后的授权级别改变也会退休proof，不能用仍可见的相同照片跨Photos授权代际继续组织。
    @Test(.timeLimit(.minutes(1))) @MainActor func RAWProofRetainsItsOriginalPhotosAccessBoundary() async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            var permission = PHAuthorizationStatus.authorized
            let reader = PhotoKitRawJPEGChecksumReader(source: { _ in try fixture.photos.rawObservation() },
                                                       bytes: { _, resource in try await fixture.photos.rawBytes(resource) }, authorization: { permission })
            let value = try await reader.checksumPair(for: fixture.photos.source, validateContext: {})
            let proof = try #require(value)
            permission = .limited
            #expect(throws: LocalPhotoChecksumError.self) { try reader.validateCurrent(proof, validateContext: {}) }
        }
    }

    /// 预览证明不能授权后来的变版/locked/校验和错误；确认前重新读取两份本机字节和远端详情。
    @Test(.timeLimit(.minutes(1)), arguments: ["locked", "checksum", "source", "revision"])
    @MainActor func RAWPreviewMustBeReprovedBeforeMembershipWrites(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == 1)
            if mode == "source" {
                fixture.photos.modified = fixture.photos.modified.addingTimeInterval(1)
            } else {
                await fixture.server.setMismatch(mode)
            }
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .failed)
            let rawPuts = await fixture.server.putCount(albumSyncPrimary), jpegPuts = await fixture.server.putCount(albumSyncJPEG)
            #expect(rawPuts == 0 && jpegPuts == 0)
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
        }
    }

    /// 实际第二原图fresh GET挂起后取消/换号，不允许部分双图证明落入计划或新账号SQLite。
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "account", "permission"])
    @MainActor func RAWPairPreparationRetiresAtTheActualSecondAssetRead(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            await fixture.run(fixture.sync.setMapping(localID: "include", targetID: albumSyncTarget2, using: fixture.manager, backup: fixture.backup))
            await fixture.server.setMode(.heldJPEGRead)
            let work = fixture.track(fixture.sync.prepare(using: fixture.manager, backup: fixture.backup))
            try #require(await fixture.server.waitUntilHeld(), "RAW preparation must reach the actual JPEG details request")
            if mode == "cancel" {
                fixture.sync.cancel()
            } else if mode == "permission" {
                fixture.photos.authorization = .denied
            } else {
                let other = AccountSession(apiURL: fixture.endpoint, accessToken: "other-synthetic", userID: albumSyncPrimary.uuidString,
                                           userEmail: "other@example.invalid", name: "Other", isAdmin: false,
                                           serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
                fixture.manager.configure(session: other, endpoint: nil)
            }
            await fixture.server.release(); await work?.value; await fixture.server.waitForIdle()
            #expect(try await fixture.coldState().operations.isEmpty)
            let puts = await fixture.server.putCount(albumSyncPrimary)
            #expect(fixture.sync.previewCount == 0 && puts == 0)
        }
    }

    /// 普通照片/视频/Live仅用同源completed的已算SHA1作fallback；旧nil不能以单UUID组织，Live motion保留。
    @Test(.timeLimit(.minutes(1)), arguments: [PhotoBackupSource.Kind.photo, .video, .livePhoto], [true, false])
    @MainActor func completedPrimaryChecksumIsRequiredWithoutAnAssociation(_ kind: PhotoBackupSource.Kind, _ checksum: Bool) async throws {
        try await withAlbumSyncFixture(kind: kind, primaryReceiptChecksum: checksum) { fixture in
            try await fixture.mapAndPrepare()
            #expect(fixture.sync.previewCount == (checksum ? 1 : 0))
            if checksum {
                let preview = try await fixture.coldState()
                #expect(preview.operations.first?.assets.first?.proof == .originalReceipt && preview.operations.first?.assets.first?.revision == nil)
                await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
                #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
                #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2))
            }
            let job = try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.first
            #expect(job?.stage == .completed && job?.motionAssetID == (kind == .livePhoto ? albumSyncMotion : nil))
            #expect(fixture.photos.hashReads == 0 && fixture.photos.rawReadRoles.isEmpty)
            #expect(await fixture.server.lookupCount() == 0)
        }
    }

    /// 自动意愿不能把人工失败/未知/发送/取消/已确认或部分回执历史重排queued；安全未尝试queued仍可消费。
    @Test(.timeLimit(.minutes(1)), arguments: ["failed", "unknown", "sending", "cancelled", "confirmed", "partial", "queued"])
    @MainActor func automaticPreparePreservesUnsafeHistory(_ mode: String) async throws {
        try await withAlbumSyncFixture { fixture in
            try await fixture.mapAndPrepare()
            var state = try await fixture.coldState()
            if mode == "partial" {
                state.operations[0].confirmedAssetIDs = Set(state.operations[0].assets.map(\.assetID))
            } else {
                state.operations[0].phase = try #require(PhotoBackupAlbumSyncOperation.Phase(rawValue: mode))
            }
            if mode == "confirmed" {
                state.operations[0].confirmedAssetIDs = Set(state.operations[0].assets.map(\.assetID))
            }
            try await fixture.store.savePhotoBackupAlbumSyncOperation(state.operations[0], scope: fixture.scope)
            _ = try await fixture.store.setPhotoBackupAlbumSyncAutomaticEnabled(true, scope: fixture.scope)
            await fixture.run(fixture.sync.prepare(using: fixture.manager, backup: fixture.backup, automatic: true))
            let cold = try await fixture.coldState()
            #expect(fixture.sync.previewCount == (mode == "queued" ? 1 : 0))
            #expect(cold.operations[0].phase == state.operations[0].phase && cold.operations[0].confirmedAssetIDs == state.operations[0].confirmedAssetIDs)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
        }
    }

    /// 独立SQLite触发器证明开关只写header；旧计划不能覆盖刚开的/关的意愿或丢弃双原图/创建历史。
    @Test(.timeLimit(.minutes(1))) @MainActor func automaticPreferenceIsHeaderOnlyAndSurvivesAStalePlan() async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Pending intent", using: fixture.manager, backup: fixture.backup))
            let stale = try await fixture.coldState()
            let probe = try await AlbumSyncSQLProbe(fixture.store.databaseFiles(scope: fixture.scope).catalog)
            try probe.execute("CREATE TABLE pair_write_events(kind TEXT)")
            try probe.execute("CREATE TRIGGER pair_update AFTER UPDATE ON photo_backup_album_sync_operations BEGIN INSERT INTO pair_write_events VALUES('update'); END")
            try probe.execute("CREATE TRIGGER pair_insert AFTER INSERT ON photo_backup_album_sync_operations BEGIN INSERT INTO pair_write_events VALUES('insert'); END")
            try probe.execute("CREATE TRIGGER pair_delete AFTER DELETE ON photo_backup_album_sync_operations BEGIN INSERT INTO pair_write_events VALUES('delete'); END")
            let before = try probe.rows("SELECT payload FROM photo_backup_album_sync_operations ORDER BY position")
            let enabled = try await fixture.store.setPhotoBackupAlbumSyncAutomaticEnabled(true, scope: fixture.scope)
            #expect(enabled.automaticEnabled && enabled.version == 3 && enabled.creations.count == 1 && enabled.operations.count == 1)
            #expect(try probe.rows("SELECT payload FROM photo_backup_album_sync_operations ORDER BY position") == before)
            #expect(try probe.rows("SELECT kind FROM pair_write_events").isEmpty)
            try await fixture.store.savePhotoBackupAlbumSyncPlan(stale, scope: fixture.scope)
            #expect(try await fixture.coldState().automaticEnabled)
            try probe.execute("DELETE FROM pair_write_events")
            let second = try probe.rows("SELECT payload FROM photo_backup_album_sync_operations ORDER BY position")
            _ = try await fixture.store.setPhotoBackupAlbumSyncAutomaticEnabled(false, scope: fixture.scope)
            #expect(try await fixture.coldState().automaticEnabled == false)
            #expect(try probe.rows("SELECT payload FROM photo_backup_album_sync_operations ORDER BY position") == second)
            #expect(try probe.rows("SELECT kind FROM pair_write_events").isEmpty)
        }
    }

    /// 缺v3自动字段/创建资料、旧版本装新证明或未来版本均拒绝；cold/plan/setter失败后原始JSON不变。
    @Test(.timeLimit(.minutes(1)), arguments: ["missing-auto", "missing-creations", "v2-proof", "future"])
    @MainActor func invalidPairHeaderCannotBeOverwrittenByAnyWritePath(_ mode: String) async throws {
        try await withAlbumSyncFixture(kind: .rawJPEG, rawExisting: true) { fixture in
            try await fixture.mapAndPrepare()
            let saved = try await fixture.coldState()
            let bytes = try JSONEncoder().encode(saved.header)
            let decoded = try JSONSerialization.jsonObject(with: bytes)
            var object = try #require(decoded as? [String: Any])
            if mode == "missing-auto" {
                object.removeValue(forKey: "automaticEnabled")
            }
            if mode == "missing-creations" {
                object.removeValue(forKey: "creations")
            }
            if mode == "v2-proof" {
                object["version"] = 2; object.removeValue(forKey: "automaticEnabled")
            }
            if mode == "future" {
                object["version"] = PhotoBackupAlbumSyncState.currentVersion + 1
            }
            let corrupted = try String(decoding: JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
            let probe = try await AlbumSyncSQLProbe(fixture.store.databaseFiles(scope: fixture.scope).catalog)
            try probe.execute("UPDATE photo_backup_album_sync_headers SET payload=?", [corrupted])
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.coldState() }
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(saved, scope: fixture.scope) }
            await #expect(throws: PhotoBackupStateError.self) { _ = try await fixture.store.setPhotoBackupAlbumSyncAutomaticEnabled(false, scope: fixture.scope) }
            #expect(try probe.rows("SELECT payload FROM photo_backup_album_sync_headers") == [[corrupted]])
        }
    }

    /// 完整计划不能丢弃已有未知记录，热写不能改主体身份；失败后通过新SQLite核原恢复资料仍在。
    @Test(.timeLimit(.minutes(1))) @MainActor func ledgerRejectsHistoryLossAndIdentityReplacement() async throws {
        try await withAlbumSyncFixture { fixture in
            try await fixture.mapAndPrepare()
            let initial = try await fixture.coldState()
            let empty = PhotoBackupAlbumSyncState(namespace: fixture.scope.cacheNamespace, mappings: initial.mappings)
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(empty, scope: fixture.scope) }
            let old = try #require(initial.operations.first)
            let replacement = PhotoBackupAlbumSyncOperation(id: old.id, localAlbumID: old.localAlbumID, targetID: albumSyncTarget1, source: old.source, assets: old.assets)
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncOperation(replacement, scope: fixture.scope) }
            #expect(try await fixture.coldState().operations.first?.targetID == albumSyncTarget2)
            let future = PhotoBackupAlbumSyncState(namespace: fixture.scope.cacheNamespace, version: PhotoBackupAlbumSyncState.currentVersion + 1)
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(future, scope: fixture.scope) }
            #expect(try await fixture.coldState().operations.count == 1)
        }
    }

    /// 同名两目标不能被自动认领；先保存预览零POST，再精确201/fresh核新UUID/持久映射，照片另行确认补入。
    @Test(.timeLimit(.minutes(1))) @MainActor func explicitCreationRequiresPreviewAndMapsOnlyIts201Identity() async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: " 同名目标 ", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let intent = try #require(preview.creations.first)
            #expect(preview.version == PhotoBackupAlbumSyncState.currentVersion && intent.phase == .prepared && intent.name == "同名目标")
            #expect(preview.mappings.isEmpty)
            #expect(await fixture.server.creationCount() == 0)
            await fixture.run(fixture.sync.createAndMap(intent.id, using: fixture.manager, backup: fixture.backup))
            let mapped = try await fixture.coldState()
            let target = try #require(mapped.mappings.first?.targetID)
            #expect(target != albumSyncTarget1 && target != albumSyncTarget2)
            #expect(mapped.creations.first?.receiptID == target && mapped.creations.first?.mappedTargetID == target && mapped.creations.first?.phase == .mapped)
            #expect(await fixture.server.creationCount() == 1)
            #expect(await fixture.server.member(albumSyncPrimary, target: target) == false)
            await fixture.run(fixture.sync.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(await fixture.server.member(albumSyncPrimary, target: target))
            #expect(try await fixture.store.loadPhotoBackups(scope: fixture.scope).jobs.isEmpty)
            #expect(fixture.photos.hashReads == 0 && fixture.photos.authorizationRequests == 0)
            #expect(await fixture.server.onlyMetadataAndMembershipRoutes(allowCreation: true))
        }
    }

    /// 201已落盘但fresh核查断网：冷恢复只读同一UUID完成，不创建第二本，也不借列表同名映射。
    @Test(.timeLimit(.minutes(1))) @MainActor func persisted201ReceiptRecoversWithGETOnly() async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Created", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.server.setMode(.createReadFailure)
            await fixture.run(fixture.sync.createAndMap(id, using: fixture.manager, backup: fixture.backup))
            let received = try await fixture.coldState()
            let receiptID = try #require(received.creations.first?.receiptID)
            #expect(received.creations.first?.phase == .received && received.mappings.isEmpty)
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.server.setMode(.normal)
            await fixture.run(restored.recoverCreation(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().mappings.first?.targetID == receiptID)
            #expect(await fixture.server.creationCount() == 1)
        }
    }

    /// 已提交但断线、错误成功状态或坏201都不能猜UUID；唯一新增列表项仍不认领，明确选已有目标才结束未知意图。
    @Test(.timeLimit(.minutes(1)), arguments: [AlbumSyncHTTPServer.Mode.createErrorAfterCommit, .createWrongStatus, .createMalformed])
    @MainActor private func unknownCreationCannotBeRepostedOrClaimedByName(_ mode: AlbumSyncHTTPServer.Mode) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Unique", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.server.setMode(mode)
            await fixture.run(fixture.sync.createAndMap(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().creations.first?.phase == .unknown)
            await fixture.server.setMode(.normal)
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(restored.recoverCreation(id, using: fixture.manager, backup: fixture.backup))
            #expect(restored.targets.count == 3 && restored.state.mappings.isEmpty && restored.state.creations.first?.receiptID == nil)
            await fixture.run(restored.createAndMap(id, using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.prepareCreation(localID: "include", name: "Again", using: fixture.manager, backup: fixture.backup))
            #expect(await fixture.server.creationCount() == 1)
            #expect(try await fixture.coldState().creations.count == 1)
            await fixture.run(restored.setMapping(localID: "include", targetID: albumSyncTarget2, using: fixture.manager, backup: fixture.backup))
            let resolved = try await fixture.coldState()
            #expect(resolved.creations.first?.phase == .mapped && resolved.creations.first?.mappedTargetID == albumSyncTarget2)
            #expect(await fixture.server.createdIDs().count == 1)
            #expect(await fixture.server.creationCount() == 1)
        }
    }

    /// 实际POST已提交后取消/换到B；旧201不落新上下文，A冷恢复仍未知且只GET，不因单个新相簿重建映射。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func creationCancellationRetainsUnprovenIntentWithoutReplay(_ account: Bool) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Interrupted", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.server.setMode(.heldCreateAfterCommit)
            await fixture.server.beginObservedWork()
            let old = try #require(fixture.track(fixture.sync.createAndMap(id, using: fixture.manager, backup: fixture.backup)))
            try #require(await fixture.server.waitUntilHeld())
            let other = AccountSession(apiURL: fixture.endpoint, accessToken: "album-sync-fixture", userID: albumSyncTarget1.uuidString,
                                       userEmail: "other@example.invalid", name: "Other", isAdmin: false, serverVersion: fixture.session.serverVersion)
            let otherScope = MediaAccountScope(session: other)
            if account {
                try await fixture.store.prepare(scope: otherScope)
                try await fixture.store.savePhotoBackups(.init(namespace: otherScope.cacheNamespace), scope: otherScope)
                try await fixture.store.savePhotoBackupAlbumSyncPlan(.init(namespace: otherScope.cacheNamespace), scope: otherScope)
                fixture.manager.configure(session: other, endpoint: fixture.endpoint)
                fixture.matching.configure(using: fixture.manager, scope: otherScope)
                await fixture.backup.load(using: fixture.manager)
            }
            fixture.sync.cancel()
            await fixture.server.release(); await old.value
            #expect(try await fixture.coldState().creations.first?.phase == .sending)
            if account {
                #expect(try await fixture.store.loadPhotoBackupAlbumSync(scope: otherScope).creations.isEmpty)
            }
            await fixture.restoreAccount()
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            #expect(restored.state.creations.first?.phase == .unknown)
            await fixture.server.setMode(.normal)
            await fixture.run(restored.recoverCreation(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().mappings.isEmpty)
            #expect(await fixture.server.creationCount() == 1)
        }
    }

    /// 明确403在发送后持久记拒绝；新一轮预览/确认才允许另一个创建意图，不自动重试，也保留原失败历史。
    @Test(.timeLimit(.minutes(1))) @MainActor func rejectedCreationNeedsANewExplicitPreview() async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Denied", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.server.setMode(.createRejected)
            await fixture.run(fixture.sync.createAndMap(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().creations.first?.phase == .rejected)
            #expect(await fixture.server.createdIDs().isEmpty)
            await fixture.server.setMode(.normal)
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Allowed", using: fixture.manager, backup: fixture.backup))
            let latest = try await fixture.coldState()
            let newID = try #require(latest.creations.last?.id)
            #expect(newID != id)
            #expect(await fixture.server.creationCount() == 1)
            await fixture.run(fixture.sync.createAndMap(newID, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().creations.last?.phase == .mapped)
            #expect(await fixture.server.creationCount() == 2)
        }
    }

    /// v1可读，首次预览升当前辅助格式；旧格式、丢历史或unknown回退prepared皆不能覆盖SQLite事实并触发重POST。
    @Test(.timeLimit(.minutes(1))) @MainActor func creationLedgerRejectsDowngradeLossAndSendRewind() async throws {
        try await withAlbumSyncFixture { fixture in
            #expect(try await fixture.coldState().version == 1)
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Intent", using: fixture.manager, backup: fixture.backup))
            var saved = try await fixture.coldState()
            #expect(saved.version == PhotoBackupAlbumSyncState.currentVersion)
            let oldFormat = PhotoBackupAlbumSyncState(namespace: fixture.scope.cacheNamespace)
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(oldFormat, scope: fixture.scope) }
            let lost = PhotoBackupAlbumSyncState(namespace: fixture.scope.cacheNamespace, version: 2)
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(lost, scope: fixture.scope) }
            saved.creations[0].phase = .sending
            try await fixture.store.savePhotoBackupAlbumSyncPlan(saved, scope: fixture.scope)
            saved.creations[0].phase = .unknown
            try await fixture.store.savePhotoBackupAlbumSyncPlan(saved, scope: fixture.scope)
            saved.creations[0].phase = .prepared
            await #expect(throws: PhotoBackupStateError.self) { try await fixture.store.savePhotoBackupAlbumSyncPlan(saved, scope: fixture.scope) }
            #expect(try await fixture.coldState().creations.first?.phase == .unknown)
            #expect(await fixture.server.creationCount() == 0)
        }
    }

    /// 用户取消尚未发送的预览后可重新命名预览；旧意图保留abandoned，全程零POST和零成员写入。
    @Test(.timeLimit(.minutes(1))) @MainActor func unattemptedCreationPreviewCanBeAbandonedWithoutPOST() async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "First", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.run(fixture.sync.abandonPreparedCreation(id, using: fixture.manager, backup: fixture.backup))
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Second", using: fixture.manager, backup: fixture.backup))
            let latest = try await fixture.coldState()
            #expect(latest.creations.count == 2 && latest.creations.first?.phase == .abandoned && latest.creations.last?.phase == .prepared)
            #expect(await fixture.server.creationCount() == 0)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
        }
    }

    /// 本人第三项editor也可组织自有照片；无members旧响应只保留明确本人owner能力，不改已有账户格式。
    @Test(.timeLimit(.minutes(1)), arguments: ["editor", "legacyOwner"])
    @MainActor func freshEditorAndLegacyOwnerTargetsCanReceiveMatchedAssets(_ role: String) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setSharedRole(role)
            await fixture.sync.load(using: fixture.manager, backup: fixture.backup)
            #expect(fixture.sync.targets.contains { UUID(uuidString: $0.id) == albumSyncTarget2 })
            try await fixture.mapAndPrepare()
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2))
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
            #expect(fixture.photos.hashReads == 0 && fixture.photos.authorizationRequests == 0)
        }
    }

    /// viewer、缺本人/未知角色/重复本人及无members的他人目标均不授权；不能拿旧ownerId或第二成员猜editor。
    @Test(.timeLimit(.minutes(1)), arguments: ["viewer", "missing", "future", "duplicate", "legacy"])
    @MainActor func unreadableOrUnprovenEditorRoleCannotAuthorizeMapping(_ role: String) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setSharedRole(role)
            await fixture.sync.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(fixture.sync.setMapping(localID: "include", targetID: albumSyncTarget2, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().mappings.isEmpty)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 0)
            #expect(await fixture.server.member(albumSyncPrimary, target: albumSyncTarget2) == false)
        }
    }

    /// 角色在确认前或实际PUT后撤销均不能落整组成功；恢复editor后只fresh补缺失，不重复已加入关系。
    @Test(.timeLimit(.minutes(1)), arguments: ["before", "after", "existing"])
    @MainActor func editorRevocationBeforeOrAfterPUTRequiresFreshRecovery(_ timing: String) async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.server.setSharedRole("editor")
            await fixture.sync.load(using: fixture.manager, backup: fixture.backup)
            try await fixture.mapAndPrepare()
            if timing == "existing" {
                await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
                try await fixture.mapAndPrepare(saveMapping: false)
                await fixture.server.setMode(.downgradeAfterContains)
            } else if timing == "after" {
                await fixture.server.setMode(.downgradeAfterMember)
            } else {
                await fixture.server.setSharedRole("viewer")
            }
            await fixture.run(fixture.sync.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase != .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == (timing == "before" ? 0 : 1))
            await fixture.server.setMode(.normal); await fixture.server.setSharedRole("editor")
            let restored = fixture.makeController()
            await restored.load(using: fixture.manager, backup: fixture.backup)
            await fixture.run(restored.prepare(using: fixture.manager, backup: fixture.backup))
            await fixture.run(restored.synchronize(using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().operations.first?.phase == .confirmed)
            #expect(await fixture.server.putCount(albumSyncPrimary) == 1)
        }
    }

    /// 创建恢复仍要求本次UUID当前本人owner；仅剩editor不能冒充创建owner身份，原201回执保留且不重POST。
    @Test(.timeLimit(.minutes(1))) @MainActor func creationIdentityDoesNotBecomeAnEditorPermissionClaim() async throws {
        try await withAlbumSyncFixture { fixture in
            await fixture.run(fixture.sync.prepareCreation(localID: "include", name: "Created", using: fixture.manager, backup: fixture.backup))
            let preview = try await fixture.coldState()
            let id = try #require(preview.creations.first?.id)
            await fixture.server.setMode(.createReadFailure)
            await fixture.run(fixture.sync.createAndMap(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().creations.first?.phase == .received)
            await fixture.server.setMode(.normal); await fixture.server.setSharedRole("createdEditor")
            await fixture.run(fixture.sync.recoverCreation(id, using: fixture.manager, backup: fixture.backup))
            #expect(try await fixture.coldState().mappings.isEmpty)
            #expect(try await fixture.coldState().creations.first?.phase == .received)
            #expect(await fixture.server.creationCount() == 1)
        }
    }
}

/// 本例独占SQLite观察连接；真实SQL触发器/原始payload用于检查header-only写入及坏格式保全，不访问生产库。
private final nonisolated class AlbumSyncSQLProbe {
    private let handle: OpaquePointer

    /// url为测试账号catalog，只读/写该合成文件；打开失败立即终止，不新建生产目录。
    init(_ url: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else { sqlite3_close(opened); throw PhotoBackupStateError.invalidJournal }
        handle = opened
    }

    /// 只释放本例观察连接，生产store actor仍持有自己的连接。
    deinit { sqlite3_close(handle) }
    /// sql/values固定为合成SQL和绑定文本，必须执行到DONE，不能用SQL字符串插值绑定JSON。
    func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
    }

    /// 返回实际文本列用于字节比较；NULL仅在审计查询中表示空串，不把坏JSON转换为业务状态。
    func rows(_ sql: String) throws -> [[String]] {
        let statement = try prepare(sql, []); defer { sqlite3_finalize(statement) }
        var output: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return output
            }
            try #require(status == SQLITE_ROW)
            output.append((0 ..< sqlite3_column_count(statement)).map { index in sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" })
        }
    }

    /// 编译固定SQL并用TRANSIENT拷贝参数；失败不能隐藏为没有写入或空结果。
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(prepared, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                sqlite3_finalize(prepared); throw PhotoBackupStateError.invalidJournal
            }
        }
        return prepared
    }
}

/// 真实URLSession请求的有限值快照；读取实际JSON或stream，不在替身中补造客户端正文。
private nonisolated struct AlbumSyncRequest: Sendable {
    let url: URL
    let method: String
    let authorization: String?
    let body: Data?
    /// request来自本例私有会话；正文最多64KiB，任何媒体/未知路由将由服务器拒绝。
    init(_ request: URLRequest) throws {
        guard let url = request.url else { throw URLError(.badURL) }
        self.url = url; method = request.httpMethod ?? ""; authorization = request.value(forHTTPHeaderField: "Authorization")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = data
        } else {
            body = nil
        }
    }
}

/// JSON成员服务的逐项故障/恢复边界；仅固定详情/查重/关系/明确创建合同，任何上传/媒体下载/删除均失败。
private actor AlbumSyncHTTPServer {
    /// 模拟逐项回执、提交后失联以及真实读取/写入等待门，不改变客户端控制流。
    enum Mode: String, Sendable { case normal, duplicate, errorAfterCommit, missingAfterSuccess, denyJPEG, heldAfterCommit, heldJPEGRead
        case createErrorAfterCommit, createWrongStatus, createMalformed, createRejected, heldCreateAfterCommit, createReadFailure
        case downgradeAfterMember, downgradeAfterContains
    }

    /// 交付给真实URLProtocol的HTTP状态与JSON字节。
    struct Reply: Sendable { let status: Int; let data: Data }
    let endpoint: URL
    let kind: PhotoBackupSource.Kind
    private var mode = Mode.normal
    private var mismatch = ""
    private var members: Set<String> = []
    private var puts: [UUID: Int] = [:]
    private var events: [(String, String)] = []
    private var held = false
    private var workEnded = false
    private var aborted = false
    private var gate: CheckedContinuation<Void, Never>?
    private var heldObservers: [CheckedContinuation<Bool, Never>] = []
    private var active = 0
    private var idleObservers: [CheckedContinuation<Void, Never>] = []
    private var created: [UUID: String] = [:]
    private var creates = 0
    private var sharedRole: String?
    private var rawChecksum = albumSyncDigest
    private var jpegChecksum = albumSyncJPEGDigest
    private var lookups = 0

    /// endpoint与kind固定本例公开请求/媒体类型；全部资产与身份都为合成值。
    init(endpoint: URL, kind: PhotoBackupSource.Kind) {
        self.endpoint = endpoint; self.kind = kind
    }

    /// 故障只影响隔离HTTP响应，不写生产controller/store字段。
    func setMode(_ value: Mode) {
        mode = value
    }

    /// 仅改变外部fresh证据，用于检验旧关联不能授权当前关系写入。
    func setMismatch(_ value: String) {
        mismatch = value
    }

    /// 第二目标改为共享目标；本人刻意位于第三项，不让客户端依赖数组位置提升权限。
    func setSharedRole(_ role: String) {
        sharedRole = role
    }

    /// raw/jpeg是独立合成字节的规范摘要；只改变服务数据，不采纳待测reader产出的结果。
    func setDigests(raw: String, jpeg: String) {
        rawChecksum = raw; jpegChecksum = jpeg
    }

    /// 实际bulk请求次数，区分双查重与metadata单UUID捷径。
    func lookupCount() -> Int {
        lookups
    }

    /// 查询HTTP服务实际关系，不能用Controller内存列表当作服务已写入。
    func member(_ asset: UUID, target: UUID) -> Bool {
        members.contains(key(asset, target))
    }

    /// 模拟独立客户端移除一条既有关系；下一次组织必须重新核查，不能拿历史确认跳过。
    func removeMember(_ asset: UUID, target: UUID) {
        members.remove(key(asset, target))
    }

    /// 实际PUT次数区分核查恢复与盲目重发。
    func putCount(_ id: UUID) -> Int {
        puts[id] ?? 0
    }

    /// 独立服务端创建次数/真实UUID集合；不能用客户端状态推断POST是否提交。
    func creationCount() -> Int {
        creates
    }

    /// 返回本例服务真实已创建UUID，不与客户端预期对象共享可变引用。
    func createdIDs() -> [UUID] {
        Array(created.keys)
    }

    /// 组织过程不得使用创建、上传、原片/预览下载或删除接口。
    func onlyMetadataAndMembershipRoutes(allowCreation: Bool = false, allowChecksum: Bool = false) -> Bool {
        events.allSatisfy { event in
            let id = "[0-9A-Fa-f-]{36}"
            let metadata = event.1 == "/api/albums" || event.1.range(of: "^/api/albums/" + id + "$", options: .regularExpression) != nil
                || event.1.range(of: "^/api/assets/" + id + "(/metadata/mobile-app)?$", options: .regularExpression) != nil
            return event.0 == "GET" && metadata || event.0 == "PUT" && event.1.hasSuffix("/assets")
                || allowCreation && event.0 == "POST" && event.1 == "/api/albums"
                || allowChecksum && event.0 == "POST" && event.1 == "/api/assets/bulk-upload-check"
        }
    }

    /// 同目标/资产UUID唯一关系；名称与数组顺序不参与身份。
    private func key(_ asset: UUID, _ target: UUID) -> String {
        target.uuidString + "/" + asset.uuidString
    }

    /// 官方当前相簿投影，两个同名目标靠UUID区分；owner来自有序albumUsers。
    private func album(_ id: UUID) -> [String: Any] {
        if let sharedRole, id == albumSyncTarget2 || (created[id] != nil && sharedRole == "createdEditor") {
            if sharedRole == "legacy" || sharedRole == "legacyOwner" {
                return ["id": id.uuidString, "albumName": "同名目标", "ownerId": sharedRole == "legacyOwner" ? albumSyncOwner : albumSyncMotion.uuidString]
            }
            var members: [[String: Any]] = [["role": "owner", "user": ["id": albumSyncMotion.uuidString]], ["role": "editor", "user": ["id": albumSyncTarget1.uuidString]]]
            if sharedRole != "missing" {
                members.append(["role": ["duplicate", "createdEditor"].contains(sharedRole) ? "editor" : sharedRole, "user": ["id": albumSyncOwner]])
            }
            if sharedRole == "duplicate" {
                members.append(["role": "viewer", "user": ["id": albumSyncOwner]])
            }
            return ["id": id.uuidString, "albumName": created[id] ?? "同名目标", "albumUsers": members]
        }
        return ["id": id.uuidString, "albumName": created[id] ?? "同名目标", "albumUsers": [["role": "owner", "user": ["id": mismatch == "target" ? albumSyncPrimary.uuidString : albumSyncOwner]]]]
    }

    /// 将有限合成响应转为真正HTTP字节，不直接返回客户端业务DTO。
    private func json(_ object: Any) throws -> Reply {
        try .init(status: 200, data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// 真实请求鉴权/路径/JSON经过有限路由；PUT未知结果/取消可在server已写关系后发生。
    func response(_ request: AlbumSyncRequest) async throws -> Reply {
        active += 1
        guard !aborted, request.authorization == "Bearer album-sync-fixture", request.url.host == endpoint.host else { throw URLError(.userAuthenticationRequired) }
        events.append((request.method, request.url.path))
        let path = request.url.path
        let targets = [albumSyncTarget1, albumSyncTarget2] + created.keys.sorted { $0.uuidString < $1.uuidString }
        if request.method == "POST", path == "/api/assets/bulk-upload-check" {
            lookups += 1
            guard let body = request.body, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(object.keys) == ["assets"], let queries = object["assets"] as? [[String: String]], queries.count == 2,
                  let rawBytes = Data(base64Encoded: rawChecksum), let jpegBytes = Data(base64Encoded: jpegChecksum) else { throw URLError(.cannotDecodeRawData) }
            let rawHex = rawBytes.map { String(format: "%02x", $0) }.joined(), jpegHex = jpegBytes.map { String(format: "%02x", $0) }.joined()
            let results: [[String: Any]] = try queries.map { item in
                guard Set(item.keys) == ["id", "checksum"], let nonce = item["id"], UUID(uuidString: nonce) != nil,
                      let digest = item["checksum"], digest == rawHex || digest == jpegHex else { throw URLError(.cannotDecodeContentData) }
                if mismatch == "missing-raw", digest == rawHex {
                    return ["id": nonce, "action": "accept"]
                }
                let asset = digest == rawHex || mismatch == "same-uuid" ? albumSyncPrimary : albumSyncJPEG
                return ["id": nonce, "action": "reject", "reason": "duplicate", "assetId": asset.uuidString, "isTrashed": mismatch == "trashed-duplicate"]
            }
            return try json(["results": results])
        }
        if request.method == "POST", path == "/api/albums" {
            // 真正POST JSON只允许空相簿名/空assetIds，无用户、成员或自造幂等键。
            guard let body = request.body else { throw URLError(.cannotDecodeRawData) }
            let decoded = try JSONSerialization.jsonObject(with: body)
            guard let object = decoded as? [String: Any], Set(object.keys) == ["albumName", "assetIds"], let name = object["albumName"] as? String,
                  !name.isEmpty, let ids = object["assetIds"] as? [String], ids.isEmpty else { throw URLError(.cannotDecodeContentData) }
            creates += 1
            if mode == .createRejected {
                return .init(status: 403, data: Data())
            }
            let id = UUID(); created[id] = name
            if mode == .heldCreateAfterCommit {
                await holdResponse()
            }
            if mode == .createErrorAfterCommit {
                throw URLError(.networkConnectionLost)
            }
            let response: [String: Any] = mode == .createMalformed ? ["id": id.uuidString, "albumName": name] : album(id)
            let data = try json(response).data
            return .init(status: mode == .createWrongStatus ? 200 : 201, data: data)
        }
        if request.method == "GET", path == "/api/albums" {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.isEmpty {
                return try json(targets.map { album($0) })
            }
            guard query.count == 1, query.first?.name == "assetId", let text = query.first?.value, let asset = UUID(uuidString: text) else { throw URLError(.badURL) }
            let response = try json(targets.filter { members.contains(key(asset, $0)) }.map { album($0) })
            if mode == .downgradeAfterContains {
                sharedRole = "viewer"
            }
            return response
        }
        if request.method == "GET", let target = targets.first(where: { path == "/api/albums/" + $0.uuidString }) {
            if mode == .createReadFailure, created[target] != nil {
                return .init(status: 503, data: Data())
            }
            return try json(album(target))
        }
        if request.method == "GET", path == "/api/assets/" + albumSyncPrimary.uuidString + "/metadata/mobile-app" {
            return try json(["key": "mobile-app", "updatedAt": albumSyncRevision.ISO8601Format(), "value": ["iCloudId": "synthetic-cloud-id", "createdAt": Date(timeIntervalSince1970: mismatch == "metadata" ? 51 : 50).ISO8601Format()]])
        }
        if request.method == "GET", let asset = [albumSyncPrimary, albumSyncJPEG].first(where: { path == "/api/assets/" + $0.uuidString }) {
            if mode == .heldJPEGRead, asset == albumSyncJPEG {
                await holdResponse()
            }
            let offline: Any = mismatch == "unknown-online" ? NSNull() : mismatch == "offline"
            let revision: Any = mismatch == "unknown-version" ? NSNull() : albumSyncRevision.addingTimeInterval(mismatch == "revision" ? 1 : 0).ISO8601Format()
            return try json(["id": mismatch == "id" ? albumSyncJPEG.uuidString : asset.uuidString, "ownerId": mismatch == "owner" ? albumSyncTarget1.uuidString : albumSyncOwner,
                             "type": mismatch == "type" || kind == .video ? "VIDEO" : "IMAGE", "visibility": mismatch == "locked" ? "locked" : "timeline", "isTrashed": mismatch == "trashed", "isOffline": offline, "isEdited": false,
                             "isFavorite": false, "originalFileName": asset == albumSyncJPEG ? "synthetic.jpg" : "synthetic.dng",
                             "checksum": mismatch == "checksum" ? jpegChecksum : asset == albumSyncJPEG ? jpegChecksum : rawChecksum,
                             "updatedAt": revision,
                             "livePhotoVideoId": kind == .livePhoto ? albumSyncMotion.uuidString : NSNull(), "exifInfo": NSNull()])
        }
        if request.method == "PUT", let target = targets.first(where: { path == "/api/albums/" + $0.uuidString + "/assets" }) {
            // 解码真正客户端请求，未知字段或批量身份均拒绝。
            struct Body: Decodable { let ids: [UUID] }
            guard let body = request.body else { throw URLError(.cannotDecodeRawData) }
            let decoded = try JSONDecoder().decode(Body.self, from: body)
            let decodedObject = try JSONSerialization.jsonObject(with: body)
            let object = try #require(decodedObject as? [String: Any])
            guard Set(object.keys) == ["ids"], decoded.ids.count == 1, let id = decoded.ids.first, [albumSyncPrimary, albumSyncJPEG].contains(id) else { throw URLError(.cannotDecodeContentData) }
            puts[id, default: 0] += 1
            if target == albumSyncTarget2, let sharedRole, !["editor", "legacyOwner"].contains(sharedRole) {
                return try json([["id": id.uuidString, "success": false, "error": "no_permission"]])
            }
            if mode == .denyJPEG, id == albumSyncJPEG {
                return try json([["id": id.uuidString, "success": false, "error": "no_permission"]])
            }
            if mode != .missingAfterSuccess {
                members.insert(key(id, target))
            }
            if mode == .heldAfterCommit {
                await holdResponse()
            }
            if mode == .errorAfterCommit {
                throw URLError(.networkConnectionLost)
            }
            if mode == .duplicate {
                return try json([["id": id.uuidString, "success": false, "error": "duplicate"]])
            }
            if mode == .downgradeAfterMember, target == albumSyncTarget2 {
                sharedRole = "viewer"
            }
            return try json([["id": id.uuidString, "success": true]])
        }
        throw URLError(.unsupportedURL)
    }

    /// 已到达真实请求才打开观察门；取消由close/release解除，不用sleep假造请求进度。
    private func holdResponse() async {
        await withCheckedContinuation { continuation in
            gate = continuation; held = true; let pending = heldObservers; heldObservers = []; pending.forEach { $0.resume(returning: true) }
        }
    }

    /// Protocol响应已交付或丢弃后才减少活动数，清理不遗留仍等待的服务任务。
    func responseExited() {
        active -= 1
        if active == 0 {
            let pending = idleObservers; idleObservers = []; pending.forEach { $0.resume() }
        }
    }

    /// 等真实PUT进入取消门；业务提前失败则返回false，不能靠sleep猜已发送。
    func waitUntilHeld() async -> Bool {
        if held {
            return true
        }; if workEnded || aborted {
            return false
        }
        return await withCheckedContinuation { heldObservers.append($0) }
    }

    /// HTTP旧响应明确释放，不修改controller或SQLite成功状态。
    func release() {
        gate?.resume(); gate = nil
    }

    /// 提前业务结束唤醒门观察者，防回归失败悬挂。
    func workFinished() {
        workEnded = true; let pending = heldObservers; heldObservers = []; pending.forEach { $0.resume(returning: false) }
    }

    /// 前次业务/观察已退役后开始新门观察；只有实际PUT到达才能发布true。
    func beginObservedWork() {
        workEnded = false
    }

    /// 失败/超时释放全部门，未来请求直接失败。
    func abort() {
        aborted = true; release(); workFinished()
    }

    /// 等待已进入服务的协议响应完成清理。
    func waitForIdle() async {
        if active == 0 {
            return
        }; await withCheckedContinuation { idleObservers.append($0) }
    }
}

/// 私有URLProtocol完整拦截本例会话；Mutex处理取消与响应Task安装竞争，取消后不交付迟到字节。
private final nonisolated class AlbumSyncURLProtocol: URLProtocol, @unchecked Sendable {
    /// 一个请求的取消事实与响应Task安装在同一锁内，防止先取消后安装的竞态。
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let servers = Mutex<[String: AlbumSyncHTTPServer]>([:])
    private let loading = Mutex(Loading())
    /// 每例随机host注册，不使用进程全局URLProtocol注册。
    static func install(_ server: AlbumSyncHTTPServer, endpoint: URL) {
        servers.withLock { $0[endpoint.host!] = server }
    }

    /// 实际业务/响应退役后只移除本例host。
    static func remove(endpoint: URL) {
        _ = servers.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 未知host也拦截并失败，不流入真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 不修补或重建客户端URL/JSON。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 异步服务处理真实请求快照，任何退出路径都通知响应退役。
    override func startLoading() {
        do {
            let captured = try AlbumSyncRequest(request)
            guard let server = Self.servers.withLock({ $0[captured.url.host ?? ""] }) else { throw URLError(.badURL) }
            let task = Task { @Sendable [weak self, captured, server] in
                do {
                    let reply = try await server.response(captured)
                    if let self, !Task.isCancelled, !loading.withLock({ $0.stopped }) {
                        guard let response = HTTPURLResponse(url: captured.url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
                    }
                } catch {
                    if let self, !Task.isCancelled, !loading.withLock({ $0.stopped }) {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
                await server.responseExited()
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// URLSession取消会取消真正响应Task，server已提交关系仍由后续fresh核查发现。
    override func stopLoading() {
        loading.withLock { $0.stopped = true; return $0.task }?.cancel()
    }
}

private nonisolated let albumSyncPrimary = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private nonisolated let albumSyncJPEG = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private nonisolated let albumSyncMotion = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private nonisolated let albumSyncTarget1 = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private nonisolated let albumSyncTarget2 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private nonisolated let albumSyncOwner = "99999999-9999-4999-8999-999999999999"
private nonisolated let albumSyncDigest = Data(repeating: 1, count: 20).base64EncodedString()
private nonisolated let albumSyncJPEGDigest = Data(repeating: 2, count: 20).base64EncodedString()
private nonisolated let albumSyncRevision = Date(timeIntervalSince1970: 300)
private nonisolated let albumSyncLocalRawDigest = "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
private nonisolated let albumSyncLocalJPEGDigest = "WJwiM1o4HxItEpIl9cC6MFbtWBE="

/// kind/provenance选择合成媒体与冷匹配依据，includeSecond共享同源；rawExisting保留服务器双原图但不写上传回执。
/// 每例完整清理实际业务/HTTP门；所有媒体身份/摘要均为合成，未读相机图库或原片。
@MainActor private func withAlbumSyncFixture(kind: PhotoBackupSource.Kind = .photo, provenance: LocalMediaAssociation.Source = .mobileMetadata,
                                             includeSecond: Bool = false, rawExisting: Bool = false, primaryReceiptChecksum: Bool? = nil,
                                             operation: @MainActor (AlbumSyncFixture) async throws -> Void) async throws
{
    let fixture = try await AlbumSyncFixture(kind: kind, provenance: provenance, includeSecond: includeSecond, rawExisting: rawExisting, primaryReceiptChecksum: primaryReceiptChecksum)
    do { try await withTaskCancellationHandler { try await operation(fixture) } onCancel: { Task { @MainActor in await fixture.close() } } }
    catch { await fixture.close(); throw error }
    await fixture.close()
}

/// 一个系统metadata端口同时供真实匹配Controller与组织Controller观察；checksum方法若被调用会立即失败。
@MainActor private final class AlbumSyncPhotoPort: LocalPhotoInventoryReading, LocalPhotoMetadataReading, LocalPhotoChecksumReading {
    var authorization = LocalPhotoLibraryAccess.full
    var modified = Date(timeIntervalSince1970: 100)
    var excluded = false
    var hashReads = 0
    var authorizationRequests = 0
    var rawExisting = false
    var rawReadRoles: [PhotoBackupImageRole] = []
    var rawReadFailure: LocalPhotoChecksumError?
    var rawChangeOnJPEG = false
    var rawAdjusted = false
    var rawSameBytes = false
    let kind: PhotoBackupSource.Kind
    let pair: PhotoBackupRawJPEGSource?
    let includeSecond: Bool

    /// kind决定合成Photos逻辑对象，includeSecond增加第二个包含关系；RAW/JPEG完整资源描述由真实领域模型校验。
    init(kind: PhotoBackupSource.Kind, includeSecond: Bool) throws {
        self.kind = kind; self.includeSecond = includeSecond
        if kind == .rawJPEG {
            pair = try .init(originals: [.init(kind: .alternatePhoto, uniformTypeIdentifier: "com.adobe.raw-image", originalFilename: "synthetic.dng", pixelWidth: 3, pixelHeight: 2),
                                         .init(kind: .photo, uniformTypeIdentifier: "public.jpeg", originalFilename: "synthetic.jpg", pixelWidth: 3, pixelHeight: 2)], hasAdjustments: false, adjustmentTime: nil)
        } else {
            pair = nil
        }
    }

    /// 当前源版本来自同一可改变系统快照，测试不修改生产Controller字段伪造已匹配。
    var source: PhotoBackupSource {
        .init(localID: "synthetic-local", modifiedAt: modified, kind: kind, rawJPEG: pair)
    }

    /// 当前metadata只携带公开元数据与opaque cloudID，不携带字节摘要或文件路径。
    var snapshot: LocalPhotoSnapshot {
        .init(identity: .init(localIdentifier: source.localID, modificationDate: modified, mediaKind: kind == .video ? .video : kind == .livePhoto ? .livePhoto : .image),
              creationDate: Date(timeIntervalSince1970: 50), adjustmentTime: nil, hasAdjustments: false, latitude: nil, longitude: nil,
              pixelWidth: 3, pixelHeight: 2, duration: 0, mediaSubtypes: 0, resources: [], cloudIdentity: .resolved("synthetic-cloud-id"))
    }

    /// 组织不应请求权限；保留计数以证明未触发。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        authorizationRequests += 1; return authorization
    }

    /// 仅供既有匹配Controller端口契约，返回当前合成身份。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try validateContext(); return [source.localID]
    }

    /// 真实metadata reader接口；只返回当前请求对象且遵循外层账号/取消检查。
    func snapshots(for ids: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try validateContext(); return ids.contains(source.localID) ? [snapshot] : []
    }

    /// 原片/本机hash不可用于组织；调用即失败，不能让测试悄悄读取媒体来补证明。
    func checksum(for _: LocalPhotoSnapshot, validateContext: @MainActor () throws -> Void) async throws -> LocalPhotoChecksumOutcome {
        try validateContext(); hashReads += 1; throw LocalPhotoChecksumError.readFailed
    }

    /// RAW证明的公开系统观察；保留两原资源角色/UTI/尺寸和修改版本，不用metadata的单UUID代替。
    func rawObservation() throws -> LocalPhotoChecksumAsset? {
        guard let pair else { return nil }
        let resources = [pair.raw, pair.jpeg].map { original -> LocalPhotoChecksumResource in
            let photo = original.kind == .photo
            return .init(descriptor: .init(type: photo ? PHAssetResourceType.photo.rawValue : PHAssetResourceType.alternatePhoto.rawValue,
                                           role: photo ? .originalPhoto : .alternatePhoto, originalFilename: original.originalFilename,
                                           uniformTypeIdentifier: original.uniformTypeIdentifier, pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight),
                         format: original.format == .raw ? .raw : .image)
        }.sorted { $0.descriptor.type < $1.descriptor.type }
        let observed = LocalPhotoSnapshot(identity: snapshot.identity, creationDate: snapshot.creationDate, adjustmentTime: rawAdjusted ? modified : nil,
                                          hasAdjustments: rawAdjusted, latitude: nil, longitude: nil, pixelWidth: 3, pixelHeight: 2, duration: 0,
                                          mediaSubtypes: 0, resources: resources.map(\.descriptor), cloudIdentity: .unavailable)
        return .init(snapshot: observed, resources: resources)
    }

    /// 只替换PhotoKit的分块回调；真正生产SHA1流计算abc/def摘要，network始终false，不生成伪digest。
    func rawBytes(_ resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest {
        let role: PhotoBackupImageRole = resource.format == .raw ? .raw : .jpeg
        rawReadRoles.append(role)
        if let rawReadFailure {
            throw rawReadFailure
        }
        if role == .jpeg, rawChangeOnJPEG {
            modified = modified.addingTimeInterval(1)
        }
        let value = Data((role == .raw || rawSameBytes ? "abc" : "def").utf8)
        return try await LocalPhotoResourceSHA1Stream().read(start: { network, receive, complete in
            #expect(network == false)
            receive(Data(value.prefix(1))); receive(Data(value.dropFirst())); complete(nil); return 1
        }, cancel: { _ in })
    }

    /// 完整包含/排除集合缺失失败；同一逻辑对象可同时在排除相簿。
    func albums(_ ids: Set<String>) throws -> [PhotoBackupAlbumSnapshot] {
        guard ids == (includeSecond ? ["include", "include2", "exclude"] : ["include", "exclude"]) else { throw PhotoBackupAlbumSelectionError.unavailableAlbum }
        var snapshots: [PhotoBackupAlbumSnapshot] = [.init(id: "include", assets: [.init(source: source, capturedAt: nil)]), .init(id: "exclude", assets: excluded ? [.init(source: source, capturedAt: nil)] : [])]
        if includeSecond {
            snapshots.append(.init(id: "include2", assets: [.init(source: source, capturedAt: nil)]))
        }
        return snapshots
    }
}

/// 实际SQLite、匹配冷恢复和管理HTTP通道；没有上传Worker，服务端已有交集由真实当前metadata/asset GET重新确认。
@MainActor private final class AlbumSyncFixture {
    let root: URL
    let database: URL
    let endpoint: URL
    let session: AccountSession
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let manager: LibraryManagementController
    let matching: LocalMediaMatchController
    let photos: AlbumSyncPhotoPort
    let backup: PhotoBackupController
    let sync: PhotoBackupAlbumSyncController
    let server: AlbumSyncHTTPServer
    private var tasks: [Task<Void, Never>] = []
    private var observers: [Task<Void, Never>] = []
    private var closeTask: Task<Void, Never>?

    /// kind/provenance选择媒体/冷恢复依据，includeSecond扩展规则；rawExisting启用双流且无回执，primaryReceiptChecksum控制旧/新主体摘要。
    init(kind: PhotoBackupSource.Kind, provenance: LocalMediaAssociation.Source, includeSecond: Bool, rawExisting: Bool, primaryReceiptChecksum: Bool?) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AlbumSync-\(UUID())", directoryHint: .isDirectory)
        let endpoint = URL(string: "https://album-sync-\(UUID().uuidString.lowercased()).invalid/api")!
        let session = AccountSession(apiURL: endpoint, accessToken: "album-sync-fixture", userID: albumSyncOwner,
                                     userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session), database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database), photos = try AlbumSyncPhotoPort(kind: kind, includeSecond: includeSecond)
        photos.rawExisting = rawExisting
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        let selection = try PhotoBackupAlbumSelection(included: includeSecond ? ["include", "include2"] : ["include"], excluded: ["exclude"])
        let snapshots = try photos.albums(selection.included.union(selection.excluded)).map { PhotoBackupAlbumSnapshot(id: $0.id, assets: []) }
        try journal.applyAlbumScan(selection.scan(snapshots), allowCloud: true)
        if kind == .rawJPEG, !rawExisting {
            try journal.enqueue([photos.source]); let id = journal.jobs[0].id
            try journal.update(id) { try $0.begin(); try $0.exported(); try $0.recordImage(.init(assetID: albumSyncPrimary, checksum: albumSyncDigest, duplicate: true), role: .raw)
                try $0.recordImage(.init(assetID: albumSyncJPEG, checksum: albumSyncJPEGDigest, duplicate: true), role: .jpeg); try $0.imagesUploaded(); try $0.confirmVerifiedImages()
            }
        }
        if let primaryReceiptChecksum {
            try journal.enqueue([photos.source]); let id = journal.jobs[0].id
            try journal.update(id) {
                try $0.begin(); try $0.exported()
                if kind == .livePhoto {
                    try $0.recordMotion(albumSyncMotion)
                }
                try $0.recordPrimary(albumSyncPrimary, duplicate: true, checksum: primaryReceiptChecksum ? albumSyncDigest : nil)
                try $0.confirmVerifiedReceipt()
            }
        }
        try await store.prepare(scope: scope); try await store.savePhotoBackups(journal, scope: scope)
        let persistence = LocalMediaAssociationStore(directory: root.appending(path: "matches"))
        let values: [LocalMediaAssociation] = kind == .rawJPEG || primaryReceiptChecksum != nil ? [] : [.init(remoteID: albumSyncPrimary, remoteRevision: albumSyncRevision,
                                                                                                              localIdentity: photos.snapshot.identity, checksum: albumSyncDigest, source: provenance)]
        _ = try await persistence.save(.init(scope: scope, enabled: primaryReceiptChecksum == nil, access: .full, associations: values), scope: scope, permit: LocalMediaSavePermit())
        let manager = LibraryManagementController(configurationFactory: Self.configuration)
        let matching = LocalMediaMatchController(inventory: photos, metadata: photos, checksum: photos, persistence: persistence, observeChanges: false)
        manager.configure(session: session, endpoint: nil)
        await matching.restoreAndRefresh(using: manager, scope: scope)?.value
        let server = AlbumSyncHTTPServer(endpoint: endpoint, kind: kind)
        if rawExisting {
            await server.setDigests(raw: albumSyncLocalRawDigest, jpeg: albumSyncLocalJPEGDigest)
        }
        AlbumSyncURLProtocol.install(server, endpoint: endpoint)
        manager.configure(session: session, endpoint: endpoint); matching.configure(using: manager, scope: scope)
        let backup = PhotoBackupController(store: store, albumScanner: { try photos.albums($0) }, authorizationStatus: { photos.authorization == .full ? .authorized : .denied }, observeAutomaticPhotos: false)
        await backup.load(using: manager)
        let sync = Self.controller(matching: matching, photos: photos, database: database)
        self.root = root; self.database = database; self.endpoint = endpoint; self.session = session; self.scope = scope; self.store = store
        self.manager = manager; self.matching = matching; self.photos = photos; self.backup = backup; self.sync = sync; self.server = server
        await sync.load(using: manager, backup: backup)
    }

    /// 一个私有URLSession，无全局协议注册或真实网络后备。
    private nonisolated static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [AlbumSyncURLProtocol.self]; return value
    }

    /// 系统源端口可替换，持久化/规划/HTTP保持生产实现。
    private static func controller(matching: LocalMediaMatchController, photos: AlbumSyncPhotoPort, database: URL) -> PhotoBackupAlbumSyncController {
        let rawReader: (any PhotoBackupRawJPEGChecksumReading)? = if photos.rawExisting {
            PhotoKitRawJPEGChecksumReader(source: { _ in try photos.rawObservation() }, bytes: { _, resource in try await photos.rawBytes(resource) },
                                          authorization: { photos.authorization == .full ? .authorized : .denied })
        } else {
            nil
        }
        return .init(matching: matching, store: SQLiteLibraryIndexStore(databaseURL: database), scanner: { try photos.albums($0) },
                     names: { _ in ["include": "手机相簿", "include2": "第二本地相簿", "exclude": "排除相簿"] }, verifySource: { guard $0 == photos.source else { throw LocalMediaMetadataError.sourceChanged } },
                     authorization: { photos.authorization == .full ? .authorized : .denied }, observeChanges: false, rawJPEGReader: rawReader)
    }

    /// 新Controller与新SQLite连接真实冷恢复，不能沿用旧Controller内存完成状态。
    func makeController() -> PhotoBackupAlbumSyncController {
        Self.controller(matching: matching, photos: photos, database: database)
    }

    /// 记录真正业务Task并在早退时唤醒HTTP门观察者。
    @discardableResult func track(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        guard let task else { Issue.record("Expected an actual album organization task."); return nil }
        tasks.append(task); observers.append(Task { await task.value; await server.workFinished() }); return task
    }

    /// 返回的Task实际由Controller/Coordinator/管理通道执行，不使用测试自建完成标志。
    func run(_ task: Task<Void, Never>?) async {
        let current = track(task)
        let observer = current == nil ? nil : observers.last
        await current?.value
        await observer?.value
    }

    /// 明确选择第二个同名目标；重复组织可保留现有映射，不发创建或改名。
    func mapAndPrepare(saveMapping: Bool = true) async throws {
        if saveMapping {
            await run(sync.setMapping(localID: "include", targetID: albumSyncTarget2, using: manager, backup: backup))
        }
        await run(sync.prepare(using: manager, backup: backup))
    }

    /// 独立SQLite actor读取真实磁盘组织账本。
    func coldState() async throws -> PhotoBackupAlbumSyncState {
        try await SQLiteLibraryIndexStore(databaseURL: database).loadPhotoBackupAlbumSync(scope: scope)
    }

    /// 按实际冷恢复顺序重建本机匹配：先离线加载同账号文档，再接当前端点；不借自动扫描补入原片hash。
    func restoreAccount() async {
        manager.configure(session: session, endpoint: nil)
        await matching.restoreAndRefresh(using: manager, scope: scope)?.value
        manager.configure(session: session, endpoint: endpoint); matching.configure(using: manager, scope: scope)
        await backup.load(using: manager)
    }

    /// 取消/超时共用一个清理Task；旧HTTP可能已提交，先解除所有门再等待真实业务/协议退出。
    func close() async {
        if let closeTask {
            await closeTask.value; return
        }
        let cleanup = Task { await closeOnce() }; closeTask = cleanup; await cleanup.value
    }

    /// 只移除本例合成账号和HTTP映射；无设备图库或生产服务操作。
    private func closeOnce() async {
        sync.cancel(); tasks.forEach { $0.cancel() }; manager.configure(session: nil, endpoint: nil); matching.configure(using: manager, scope: nil)
        await server.abort()
        for task in tasks {
            await task.value
        }
        for task in observers {
            await task.value
        }
        await server.waitForIdle()
        AlbumSyncURLProtocol.remove(endpoint: endpoint)
        try? FileManager.default.removeItem(at: root)
    }
}
