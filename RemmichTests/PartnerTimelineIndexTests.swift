import Foundation
import Testing
@testable import Remmich

/// 真实SQLite/原索引同步器的伙伴查询作用域回归；只有合成服务端读取可控，不注入已接受索引或私有映射。
@Suite("Partner timeline accepted policy")
nonisolated struct PartnerTimelineIndexTests {
    /// 第三个旧月总数不变但成员换人，开启和关闭都必须fresh重读；证书、旧GET退休及accepted真实目录一致。
    @Test(arguments: [false, true])
    func equalCountHistoricalMembersChangeWithThePolicy(_ initiallyEnabled: Bool) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let original = try partnerIndexBuckets(partnerEnabled: initiallyEnabled)
        let next = try partnerIndexBuckets(partnerEnabled: !initiallyEnabled)
        let source = PartnerIndexSource(scope: fixture.scope, buckets: original, enabled: initiallyEnabled)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        await source.replace(buckets: next, enabled: !initiallyEnabled)
        await source.clearReads()
        let result = try await sync.synchronizeRecent(scope: fixture.scope)
        let cold = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let afterValue = try await cold.snapshot(scope: fixture.scope); let after = try #require(afterValue)
        #expect(after.assets.count == before.assets.count && after.generation > before.generation)
        let expected = !initiallyEnabled ? partnerIndexRemoteAsset : partnerIndexOwnAsset
        #expect(after.assets.filter { $0.bucketKey == partnerIndexOldMonth }.map(\.id) == [expected])
        let certificateValue = try await cold.loadPartnerTimelineCertificate(scope: fixture.scope); let certificate = try #require(certificateValue)
        let policy = try await source.partnerTimelinePolicy(scope: fixture.scope)
        #expect(certificate.matches(generation: after.generation, policy: policy, scope: fixture.scope))
        #expect(result.appliedPartnerPolicy == policy)
        let reads = await source.reads()
        let retired = try #require(reads.firstIndex(of: "retire")); let factory = try #require(reads.firstIndex(of: "fresh-factory"))
        #expect(retired < factory && reads.contains("fresh:\(partnerIndexOldMonth)"))
        #expect(!reads.contains("normal:\(partnerIndexOldMonth)"))
        let bootstrap = LibraryTimelineBootstrapBuilder.build(from: after)
        #expect(bootstrap.photos.assetsByBucket[.init(rawValue: partnerIndexOldMonth)]?.map(\.id) == [expected])
    }

    /// 新scope月份出现及旧月最后成员消失都走原替换/accept，不能只更新最新月或保留被撤销成员。
    @Test func replacesNewAndDisappearingMonthsAtomically() async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        var next = try partnerIndexBuckets(partnerEnabled: true)
        next.removeValue(forKey: partnerIndexOldMonth)
        next["2018-04-01"] = try [partnerIndexAsset(partnerIndexRemoteAsset, month: "2018-04", owner: partnerIndexPartner)]
        await source.replace(buckets: next, enabled: true)
        _ = try await sync.synchronizeRecent(scope: fixture.scope)
        let value = try await SQLiteLibraryIndexStore(databaseURL: fixture.database).snapshot(scope: fixture.scope)
        let snapshot = try #require(value)
        #expect(!snapshot.assets.contains { $0.bucketKey == partnerIndexOldMonth })
        #expect(snapshot.assets.first { $0.id == partnerIndexRemoteAsset }?.bucketKey == "2018-04-01")
        #expect(!snapshot.groups.contains { $0.level == "month" && $0.key == "2019-06" })
        #expect(snapshot.syncState.historicalCursor == nil)
    }

    /// 半桶、重复ID、错误月份在accept前失败；真实旧目录及旧代际凭据保留，不能给新策略签发成功。
    @Test(arguments: ["partial", "duplicate", "wrong-month"])
    func invalidFreshMonthsKeepTheOldAcceptedGeneration(_ variant: String) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        var next = try partnerIndexBuckets(partnerEnabled: true)
        if variant == "duplicate" {
            // 独立summary要求两项，坏payload也给两项；必须靠唯一性门拒绝，不能只因count不同通过测试。
            try next[partnerIndexOldMonth, default: []].append(partnerIndexAsset(partnerIndexSecondAsset, month: "2019-06"))
        }
        await source.replace(buckets: next, enabled: true)
        let broken: [TimelineAssetSummary]
        if variant == "partial" {
            broken = []
        } else if variant == "duplicate" {
            let value = try #require(next[partnerIndexOldMonth]?.first); broken = [value, value]
        } else {
            broken = try [partnerIndexAsset(partnerIndexRemoteAsset, month: "2018-04", owner: partnerIndexPartner)]
        }
        await source.overrideOldMonth(broken)
        do { _ = try await sync.synchronizeRecent(scope: fixture.scope); Issue.record("Incomplete partner months must not be accepted.") }
        catch PartnerTimelinePolicyError.incompleteMonths {}
        let cold = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let afterValue = try await cold.snapshot(scope: fixture.scope); let after = try #require(afterValue)
        #expect(after.generation == before.generation && after.assets.map(\.id) == before.assets.map(\.id))
        #expect(try await cold.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation == before.generation)
    }

    /// 使用现有validateContext在证书已落盘而accept尚未发生处模拟进程中断；另一变体在accept后全新构造恢复。
    @Test(arguments: ["before-accept", "after-accept"])
    func coldRestorationUsesTheAcceptedGenerationInsteadOfMemory(_ interruption: String) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        let changed = try partnerIndexBuckets(partnerEnabled: true)
        await source.replace(buckets: changed, enabled: true)
        if interruption == "before-accept" {
            do {
                _ = try await sync.synchronizeRecent(scope: fixture.scope, validateContext: {
                    // 读取实际原子JSON，而非测试计数器；只有新证书确实落盘后才触发模拟中断。
                    if let certificate = try await store.loadPartnerTimelineCertificate(scope: fixture.scope), certificate.generation != before.generation {
                        throw CancellationError()
                    }
                })
                Issue.record("The simulated pre-accept interruption must stop the run.")
            } catch is CancellationError {}
            let interruptedValue = try await store.snapshot(scope: fixture.scope); let interrupted = try #require(interruptedValue)
            #expect(interrupted.generation == before.generation)
            #expect(try await store.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation != before.generation)
        } else {
            _ = try await sync.synchronizeRecent(scope: fixture.scope)
        }
        let coldStore = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let coldSource = PartnerIndexSource(scope: fixture.scope, buckets: changed, enabled: true)
        let coldSync = LibraryIndexSynchronizer(source: coldSource, store: coldStore)
        _ = try await coldSync.synchronizeRecent(scope: fixture.scope)
        let value = try await coldStore.snapshot(scope: fixture.scope); let recovered = try #require(value)
        #expect(recovered.assets.filter { $0.bucketKey == partnerIndexOldMonth }.map(\.id) == [partnerIndexRemoteAsset])
        let reads = await coldSource.reads()
        #expect(reads.contains("fresh:\(partnerIndexOldMonth)") == (interruption == "before-accept"))
        let certificateValue = try await coldStore.loadPartnerTimelineCertificate(scope: fixture.scope); let certificate = try #require(certificateValue)
        let recoveredPolicy = try await coldSource.partnerTimelinePolicy(scope: fixture.scope)
        #expect(certificate.matches(generation: recovered.generation, policy: recoveredPolicy, scope: fixture.scope))
    }

    /// 损坏/缺失/错误代际凭据不能变成策略匹配，未知偏好也不能默认成false来复用旧月份。
    @Test(arguments: ["missing", "corrupt", "future-version", "wrong-generation", "unknown"])
    func unconfirmedCertificatesForceCompleteMetadataReads(_ variant: String) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let files = await store.databaseFiles(scope: fixture.scope)
        let path = files.catalog.deletingLastPathComponent().appending(path: "partner-timeline-policy.json")
        if variant == "missing" {
            try FileManager.default.removeItem(at: path)
        } else if variant == "corrupt" {
            try Data("invalid synthetic certificate".utf8).write(to: path, options: .atomic)
        } else if variant == "future-version" {
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
            var object = try #require(decoded as? [String: Any]); object["formatVersion"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        } else if variant == "wrong-generation" {
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
            var object = try #require(decoded as? [String: Any]); object["generation"] = 999_999
            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        } else {
            await source.makePreferenceUnknown()
        }
        await source.clearReads()
        let result = try await sync.synchronizeRecent(scope: fixture.scope)
        #expect(await source.reads().contains("fresh:\(partnerIndexOldMonth)"))
        #expect((result.appliedPartnerPolicy == nil) == (variant == "unknown"))
    }

    /// 证书不能通过公开写入口附到任意未知/已accepted代际，避免绕过“building后再accept”的持久顺序。
    @Test(arguments: ["accepted", "unknown"])
    func certificateCannotBeAttachedToAnUnstagedGeneration(_ variant: String) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        let target = variant == "accepted" ? before.generation : before.generation + 100
        let policy = try await source.partnerTimelinePolicy(scope: fixture.scope)
        do {
            try await store.stagePartnerTimelineCertificate(.init(generation: target, policy: policy), scope: fixture.scope)
            Issue.record("A policy certificate must target an actual building generation.")
        } catch let LibraryIndexStoreError.invalidGeneration(actual) { #expect(actual == target) }
        #expect(try await store.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation == before.generation)
    }

    /// 月读取在实际门内时策略再次变化，bookend必须在accept之前拒绝；之后重试只有读，不发送任何伙伴写。
    @Test(.timeLimit(.minutes(1))) func changedBookendCannotAcceptMixedPolicies() async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let original = try partnerIndexBuckets(partnerEnabled: false)
        let source = PartnerIndexSource(scope: fixture.scope, buckets: original, enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        try await source.replace(buckets: partnerIndexBuckets(partnerEnabled: true), enabled: true)
        let gate = PartnerIndexGate(); await source.holdFreshOld(gate)
        let operation = Task { try await sync.synchronizeRecent(scope: fixture.scope) }
        let observer = Task { _ = await operation.result; await gate.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await gate.waitForEntry())
                await source.replace(buckets: original, enabled: false); await gate.release()
                do { _ = try await operation.value; Issue.record("Changed partner policy must fail before accept.") }
                catch PartnerTimelinePolicyError.changedPolicy {}
            } onCancel: { operation.cancel(); Task { await gate.close() } }
        } catch { operation.cancel(); await gate.close(); _ = await operation.result; await observer.value; throw error }
        await observer.value
        let cold = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let afterValue = try await cold.snapshot(scope: fixture.scope); let after = try #require(afterValue)
        #expect(after.generation == before.generation && !after.assets.contains { $0.id == partnerIndexRemoteAsset })
        #expect(try await cold.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation == before.generation)
    }

    /// 普通旧run挂起时服务端策略变更，管理观察器的有限调度不能丢；旧run bookend失败后原唯一worker补一轮。
    @Test(.timeLimit(.minutes(1))) @MainActor func inflightRefreshRunsAgainWithoutRepeatingThePartnerWrite() async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: fixture.scope)
        let suite = "PartnerIndex-\(UUID().uuidString)"; let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = LibraryIndexController(source: source, store: store, cacheRootURL: fixture.root.appending(path: "cache"), preferences: preferences)
        let manager = LibraryManagementController(); manager.configure(session: partnerIndexSession(), endpoint: partnerIndexSession().apiURL)
        let gate = PartnerIndexGate(); await source.holdNormalNewest(gate)
        defer { controller.suspend(); manager.configure(session: nil, endpoint: nil); Task { await gate.close() } }
        try await withTaskCancellationHandler {
            controller.start(session: partnerIndexSession(), endpoint: partnerIndexSession().apiURL)
            let observation = Task { _ = await controller.finishBackgroundSync(kind: .refresh); await gate.operationFinished() }
            try #require(await gate.waitForEntry())
            try await source.replace(buckets: partnerIndexBuckets(partnerEnabled: true), enabled: true)
            manager.publishPartnerTimelineChange(ifGeneration: manager.generation)
            controller.syncNow(metadataDates: [], partnerTimelineRefresh: manager.takePartnerTimelineRefreshRequest(), manager: manager)
            await gate.release()
            for _ in 0 ..< 3 {
                _ = await controller.finishBackgroundSync(kind: .refresh)
                if !controller.hasActiveSyncWork {
                    break
                }
            }
            #expect(controller.status == .upToDate && !controller.hasActiveSyncWork)
            let value = try await store.snapshot(scope: fixture.scope); let accepted = try #require(value)
            #expect(accepted.assets.contains { $0.id == partnerIndexRemoteAsset })
            #expect(!accepted.assets.contains { $0.id == partnerIndexOwnAsset })
            let policy = try await source.partnerTimelinePolicy(scope: fixture.scope)
            #expect(controller.acceptedPartnerTimelinePolicy == policy)
            #expect(manager.revision == 1)
            await observation.value
        } onCancel: { Task { @MainActor in controller.suspend(); await gate.close() } }
    }

    /// 真实Controller在fresh旧月期间换账号或只换端点；旧任务不能给新scope写证书/accept，也不发布旧伙伴成员。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    @MainActor func retiredContextCannotAcceptTheOldPolicy(_ reason: String) async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let original = try partnerIndexBuckets(partnerEnabled: false)
        let source = PartnerIndexSource(scope: fixture.scope, buckets: original, enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        let suite = "PartnerRetirement-\(UUID().uuidString)"; let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = LibraryIndexController(source: source, store: store, cacheRootURL: fixture.root.appending(path: "cache"), preferences: preferences)
        let gate = PartnerIndexGate(); try await source.replace(buckets: partnerIndexBuckets(partnerEnabled: true), enabled: true)
        await source.holdFreshOld(gate)
        defer { controller.suspend(); Task { await gate.close() } }
        try await withTaskCancellationHandler {
            controller.start(session: partnerIndexSession(), endpoint: partnerIndexSession().apiURL)
            let observation = Task { _ = await controller.finishBackgroundSync(kind: .refresh); await gate.operationFinished() }
            try #require(await gate.waitForEntry())
            let nextSession = partnerIndexSession(user: reason == "account" ? partnerIndexSecondOwner : partnerIndexOwner)
            let nextScope = MediaAccountScope(session: nextSession)
            let nextBuckets = try reason == "account" ? [partnerIndexRecentMonth: [partnerIndexAsset(partnerIndexSecondAsset, month: "2026-11", owner: partnerIndexSecondOwner)]] : original
            await source.activate(scope: nextScope, buckets: nextBuckets, enabled: false)
            controller.start(session: nextSession, endpoint: reason == "endpoint" ? nextSession.apiURL.appending(path: "fallback") : nextSession.apiURL)
            await gate.release()
            for _ in 0 ..< 3 {
                _ = await controller.finishBackgroundSync(kind: .refresh)
                if !controller.hasActiveSyncWork {
                    break
                }
            }
            let nextValue = try await store.snapshot(scope: nextScope); let next = try #require(nextValue)
            #expect(!next.assets.contains { $0.id == partnerIndexRemoteAsset })
            #expect(controller.acceptedPartnerTimelinePolicy?.namespace == nextScope.cacheNamespace)
            if reason == "account" {
                let oldValue = try await store.snapshot(scope: fixture.scope); let old = try #require(oldValue)
                #expect(old.generation == before.generation)
                #expect(next.assets.allSatisfy { $0.ownerID == partnerIndexSecondOwner })
            }
            await observation.value
        } onCancel: { Task { @MainActor in controller.suspend(); await gate.close() } }
    }

    /// 真Queue恢复持久running GET，先退休后fresh/证书/accept；迟到回调不可重建job，cache/export保留。
    @Test func durableRetirementRejectsLateCallbacks() async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let queued = try PartnerIndexQueueFixture(root: fixture.root.appending(path: "queue"))
        await source.useRetirement { try await queued.queue.retirePartnerTimelineIndexPass(namespace: fixture.scope.cacheNamespace) }
        try await source.replace(buckets: partnerIndexBuckets(partnerEnabled: true), enabled: true); await source.clearReads()
        _ = try await sync.synchronizeRecent(scope: fixture.scope)
        let retired = try LibraryTransferJournal.load(from: queued.journal)
        #expect(Set(retired.jobs.map(\.id)) == [queued.cacheID, queued.exportID])
        let file = queued.root.appending(path: "late-synthetic.body"); try Data("old policy response".utf8).write(to: file)
        let response = try #require(HTTPURLResponse(url: queued.old.url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        await queued.queue.received(id: queued.old.id, nativeTaskID: 7, attemptID: queued.old.attemptID, transport: .foreground,
                                    response: response, fileURL: file, errorCode: nil)
        await queued.queue.completed(id: queued.old.id, nativeTaskID: 7, attemptID: queued.old.attemptID, transport: .foreground, errorCode: nil)
        let cold = try LibraryTransferJournal.load(from: queued.journal)
        #expect(Set(cold.jobs.map(\.id)) == [queued.cacheID, queued.exportID] && !FileManager.default.fileExists(atPath: file.path))
        #expect(cold.passes["index"] == nil && cold.passes["cache"] != nil && cold.passes["export"] != nil)
        let reads = await source.reads(); let retiredAt = try #require(reads.firstIndex(of: "retire")); let freshAt = try #require(reads.firstIndex(of: "fresh-summary"))
        #expect(retiredAt < freshAt)
        let snapshotValue = try await store.snapshot(scope: fixture.scope); let snapshot = try #require(snapshotValue)
        #expect(try await store.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation == snapshot.generation)
    }

    /// 真journal父目录被私有普通文件阻塞时必须抛I/O错误；不能给未持久清退签发新证书或accept。
    @Test func failedRetirementCannotPrepareCertificate() async throws {
        let fixture = try PartnerIndexFixture(); defer { fixture.cleanup() }
        let source = try PartnerIndexSource(scope: fixture.scope, buckets: partnerIndexBuckets(partnerEnabled: false), enabled: false)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.database); let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope); let before = try #require(beforeValue)
        let queued = try PartnerIndexQueueFixture(root: fixture.root.appending(path: "queue"))
        // 只破坏本例Queue元数据目录；createDirectory不能覆盖普通文件，不依赖运行用户权限或原子rename实现。
        try FileManager.default.removeItem(at: queued.root); try Data("synthetic blocked directory".utf8).write(to: queued.root)
        await source.useRetirement { try await queued.queue.retirePartnerTimelineIndexPass(namespace: fixture.scope.cacheNamespace) }
        try await source.replace(buckets: partnerIndexBuckets(partnerEnabled: true), enabled: true)
        do { _ = try await sync.synchronizeRecent(scope: fixture.scope); Issue.record("Failed durable retirement must stop indexing.") }
        catch is CocoaError {}
        let cold = SQLiteLibraryIndexStore(databaseURL: fixture.database)
        let afterValue = try await cold.snapshot(scope: fixture.scope); let after = try #require(afterValue)
        #expect(after.generation == before.generation && !after.assets.contains { $0.id == partnerIndexRemoteAsset })
        #expect(try await cold.loadPartnerTimelineCertificate(scope: fixture.scope)?.generation == before.generation)
    }
}

private nonisolated let partnerIndexOwner = "11111111-1111-4111-8111-111111111111"
private nonisolated let partnerIndexPartner = "22222222-2222-4222-8222-222222222222"
private nonisolated let partnerIndexSecondOwner = "77777777-7777-4777-8777-777777777777"
private nonisolated let partnerIndexOwnAsset = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let partnerIndexRemoteAsset = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let partnerIndexSecondAsset = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
private nonisolated let partnerIndexRecentMonth = "2026-11-01"
private nonisolated let partnerIndexOldMonth = "2019-06-01"

/// month为独立UTC年月，id/owner为合成身份；静态无stack照片只提供索引元数据，不读图片或Photos。
private nonisolated func partnerIndexAsset(_ id: String, month: String, owner: String = partnerIndexOwner) throws -> TimelineAssetSummary {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
    let date = try #require(formatter.date(from: "\(month)-10T12:00:00Z"))
    return .init(id: id, ownerID: owner, capturedAt: date, uploadedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 4.0 / 3.0,
                 isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
                 thumbhash: nil, thumbnailRevision: Date(timeIntervalSince1970: 1_800_000_000))
}

/// 三个月保证2019旧月在正常prefix2以外；开关只替换旧月的一个ID/owner，总数故意完全相同。
private nonisolated func partnerIndexBuckets(partnerEnabled: Bool) throws -> [String: [TimelineAssetSummary]] {
    try [partnerIndexRecentMonth: [partnerIndexAsset("dddddddd-dddd-4ddd-8ddd-dddddddddddd", month: "2026-11")],
         "2026-10-01": [partnerIndexAsset("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", month: "2026-10")],
         partnerIndexOldMonth: [partnerIndexAsset(partnerEnabled ? partnerIndexRemoteAsset : partnerIndexOwnAsset, month: "2019-06", owner: partnerEnabled ? partnerIndexPartner : partnerIndexOwner)]]
}

/// 固定.invalid账号仅用于scope和原索引Controller，不触达网络/Keychain。
private nonisolated func partnerIndexSession(user: String = partnerIndexOwner) -> AccountSession {
    .init(apiURL: URL(string: "https://partner-index.invalid/api")!, accessToken: "synthetic-partner-token", userID: user,
          userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 每例只拥有自己的SQLite及账号目录；冷恢复使用新的store/source对象，不从热内存返回证书。
private nonisolated struct PartnerIndexFixture: Sendable {
    let root: URL
    let database: URL
    let scope = MediaAccountScope(session: partnerIndexSession())
    /// 只建立本例随机子目录，不复用真实索引或缓存目录。
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PartnerPolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); database = root.appending(path: "index.sqlite3")
    }

    /// 只移除本例私有临时目录，不操作真实账号或现存索引。
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 通过原journal领域方法建立隔离旧传输，不碰私有Queue映射、真实native会话或网络。
private nonisolated struct PartnerIndexQueueFixture: Sendable {
    let root: URL
    let journal: URL
    let old: LibraryTransferJournal.Job
    let cacheID: UUID
    let exportID: UUID
    let queue: LibraryTransferQueue

    /// root由本例所有；三类任务由同一合成owner正常创建并原子持久化，旧index记录用于递送迟到回调。
    init(root: URL) throws {
        self.root = root; journal = root.appending(path: "journal.json")
        let session = partnerIndexSession(); let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        var value = LibraryTransferJournal(); _ = value.activate(owner)
        var old = try value.job(url: session.apiURL.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        old.state = .running; old.nativeTaskID = 7; old.attemptID = UUID(); old.transport = .foreground; value.update(old); self.old = old
        cacheID = try value.job(url: session.apiURL.appending(path: "assets/synthetic/thumbnail"), kind: .thumbnail, owner: owner).id
        exportID = try value.job(url: session.apiURL.appending(path: "assets/synthetic/original"), kind: .export, owner: owner).id
        try value.save(to: journal); queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] })
    }
}

/// 严格区分普通缓存与fresh端口；真实退休端口会更新合成缓存，正例不能靠普通reader误读新数据通过。
private actor PartnerIndexSource: TimelineReading, ManagementTimelineProviding, PartnerTimelinePolicyReading {
    private var scope: MediaAccountScope
    private var buckets: [String: [TimelineAssetSummary]]
    private var cached: [String: [TimelineAssetSummary]]
    private var enabled: Bool?
    private var overrides: [String: [TimelineAssetSummary]] = [:]
    private var captured: [String] = []
    private var generation = 0
    private var normalGate: PartnerIndexGate?
    private var freshGate: PartnerIndexGate?
    private var retirement: (@Sendable () async throws -> Void)?

    /// 初始化远端与旧缓存为同一快照；后续replace只改远端，必须调用真实退休端口才清旧缓存。
    init(scope: MediaAccountScope, buckets: [String: [TimelineAssetSummary]], enabled: Bool) {
        self.scope = scope; self.buckets = buckets; cached = buckets; self.enabled = enabled
    }

    /// 模拟服务端单向偏好/成员改变，保持旧缓存不变，供同计数回归。
    func replace(buckets: [String: [TimelineAssetSummary]], enabled: Bool) {
        self.buckets = buckets; self.enabled = enabled; overrides = [:]
    }

    /// 只破坏fresh成员响应，summary仍来自正确远端数量，不能让坏输入自己修正预期。
    func overrideOldMonth(_ values: [TimelineAssetSummary]) {
        overrides[partnerIndexOldMonth] = values
    }

    /// 缺字段必须保持未知，每轮都不可凭证书计数复用。
    func makePreferenceUnknown() {
        enabled = nil
    }

    /// 真实账户/端点退休使旧factory失效，并替换新scope的实际远端/缓存资料。
    func activate(scope: MediaAccountScope, buckets: [String: [TimelineAssetSummary]], enabled: Bool) {
        generation += 1; self.scope = scope; self.buckets = buckets; cached = buckets; self.enabled = enabled; overrides = [:]
    }

    /// 设置普通最新月的非合作实际门闩；不通过sleep伪造在途状态。
    func holdNormalNewest(_ gate: PartnerIndexGate) {
        normalGate = gate
    }

    /// 设置fresh旧月的实际门闩，供取消/路由与账号退休测试。
    func holdFreshOld(_ gate: PartnerIndexGate) {
        freshGate = gate
    }

    /// 返回读取顺序，便于独立证明退休早于fresh而非仅比最终值。
    func reads() -> [String] {
        captured
    }

    /// 清理仅测试端口日志，不修改任何被测目录或凭据。
    func clearReads() {
        captured = []
    }

    /// 测试可连接真Queue退休端口，只替换依赖来源，不替换同步器/证书或accept逻辑。
    func useRetirement(_ operation: @escaping @Sendable () async throws -> Void) {
        retirement = operation
    }

    /// 返回真实服务端策略，检查scope；没有媒体或HTTP写入端口。
    func partnerTimelinePolicy(scope: MediaAccountScope) throws -> PartnerTimelinePolicy {
        guard scope == self.scope else { throw CancellationError() }; captured.append("policy")
        return try .init(scope: scope, incoming: [.init(id: partnerIndexPartner, name: "Synthetic partner", email: nil, inTimeline: enabled)])
    }

    /// 保留产品端口语义：先退休旧GET，再让之后普通缓存读取属于新scope，原factory由独立代际保护。
    func retirePartnerTimelineIndexReads(scope: MediaAccountScope) async throws {
        guard scope == self.scope else { throw CancellationError() }
        let owner = generation; try await retirement?()
        guard owner == generation, scope == self.scope else { throw CancellationError() }; captured.append("retire"); cached = buckets
    }

    /// 普通端口只返回当前缓存，完整query仍须包含官方withPartners语义。
    func bucketSummaries(query: TimelineQuery) throws -> [TimelineBucketSummary] {
        try requireQuery(query); captured.append("normal-summary"); return summaries(cached)
    }

    /// 普通响应在入门之前捕获，之后远端变化不能把它伪装成新policy数据。
    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        try requireQuery(query); captured.append("normal:\(bucketID.rawValue)"); let values = cached[bucketID.rawValue, default: []]
        let owner = generation
        if bucketID.rawValue == partnerIndexRecentMonth, let gate = normalGate {
            normalGate = nil; await gate.enterAndWait()
        }
        guard owner == generation else { throw CancellationError() }; return values
    }

    /// 测试不生成回忆，避免任何间接插入照片的替代路径。
    func memories() -> [TimelineMemorySummary] {
        []
    }

    /// factory必须记录并绑定当前代际，不能将普通reader直接返回冒充fresh。
    func managementTimelineReader() -> any TimelineReading {
        captured.append("fresh-factory"); return Fresh(source: self, owner: generation)
    }

    /// fresh摘要来自当前真实服务端字典，不受错误payload覆盖影响。
    private func freshSummaries(_ query: TimelineQuery, owner: Int) throws -> [TimelineBucketSummary] {
        try requireQuery(query); guard owner == generation else { throw CancellationError() }; captured.append("fresh-summary"); return summaries(buckets)
    }

    /// fresh响应也在门前捕获，并在门后检查factory代际；故意不合作Task取消以验证同步器自身门禁。
    private func freshAssets(_ bucket: TimelineBucketID, query: TimelineQuery, owner: Int) async throws -> [TimelineAssetSummary] {
        try requireQuery(query); guard owner == generation else { throw CancellationError() }; captured.append("fresh:\(bucket.rawValue)")
        let values = overrides[bucket.rawValue] ?? buckets[bucket.rawValue, default: []]
        if bucket.rawValue == partnerIndexOldMonth, let gate = freshGate {
            freshGate = nil; await gate.enterAndWait()
        }
        guard owner == generation else { throw CancellationError() }; return values
    }

    /// query必须是索引已有默认范围，不改变收藏/归档/stack或借搜索旁路补成员。
    private func requireQuery(_ query: TimelineQuery) throws {
        guard query.albumID == nil, query.userID == nil, query.includesPartners, !query.includesTrashed,
              !query.includesStacks, query.visibility == .timeline, query.isFavorite == nil else { throw URLError(.badURL) }
    }

    /// 数量由独立服务端字典确定，不使用被测accepted结果生成预期。
    private func summaries(_ values: [String: [TimelineAssetSummary]]) -> [TimelineBucketSummary] {
        values.map { .init(id: .init(rawValue: $0.key), assetCount: $0.value.count) }
    }

    /// 只把fresh调用转回有代际检查的源actor；所有值仍来自合成HTTP/元数据边界。
    private nonisolated struct Fresh: TimelineReading {
        let source: PartnerIndexSource; let owner: Int
        /// query原样交给当前factory代际的服务端摘要端口。
        func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
            try await source.freshSummaries(query, owner: owner)
        }

        /// bucketID/query不变，真实源检查代际前后及完整payload。
        func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
            try await source.freshAssets(bucketID, query: query, owner: owner)
        }

        /// 空回忆不会为被测索引补造任何媒体。
        func memories() -> [TimelineMemorySummary] {
            []
        }
    }
}

/// 有限真实入场/释放门；结束/超时清理也唤醒观察者，不以时间流逝作为请求已进入的证明。
private actor PartnerIndexGate {
    private var entered = false
    private var closed = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    /// 实际读到达后才唤醒观察者，早释放/清理均不会遗留不可达等待。
    func enterAndWait() async {
        guard !closed else { return }; entered = true; observer?.resume(returning: true); observer = nil
        if !released {
            await withCheckedContinuation { held = $0 }
        }
    }

    /// true代表业务读取确实入场；业务先结束或清理时false，禁止靠sleep推测。
    func waitForEntry() async -> Bool {
        if entered {
            return true
        }; if closed {
            return false
        }; return await withCheckedContinuation { observer = $0 }
    }

    /// 操作若提前失败也唤醒观察者，不等待整分钟超时才发现路径未达到。
    func operationFinished() {
        if !entered {
            closed = true; observer?.resume(returning: false); observer = nil
        }
    }

    /// 明确释放一次当前读取，重复释放安全且早释放会被记录。
    func release() {
        released = true; held?.resume(); held = nil
    }

    /// 失败/取消清理同时释放读者与观察者。
    func close() {
        closed = true; observer?.resume(returning: false); observer = nil; release()
    }
}
