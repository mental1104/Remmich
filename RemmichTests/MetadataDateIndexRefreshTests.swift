import Foundation
import Testing
@testable import Remmich

/// 日期定向刷新经真实同步器、SQLite和bootstrap验证；网络端口仅提供合成完整月快照，不访问服务或照片。
@Suite("Metadata date index refresh", .serialized)
nonisolated struct MetadataDateIndexRefreshTests {
    /// 历史月数量不变时普通增量确实保留旧记录；定向刷新必须改变真实SQLite日键和最终bootstrap顺序。
    @Test func unchangedHistoricalCountStillRequiresItsMonthToBeRefetched() async throws {
        let fixture = try DateIndexFixture()
        defer { fixture.cleanup() }
        let old = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(old, companion: companion)
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: fixture.scope)

        let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        buckets[dateIndexOldMonth] = [changed, companion]
        await source.replace(with: buckets)
        _ = try await synchronizer.synchronizeRecent(scope: fixture.scope)
        let ordinaryValue = try await store.snapshot(scope: fixture.scope)
        let ordinary = try #require(ordinaryValue)
        #expect(ordinary.assets.first { $0.id == dateIndexTargetID }?.capturedAt == old.capturedAt)
        let ordinaryBootstrap = LibraryTimelineBootstrapBuilder.build(from: ordinary)
        #expect(ordinaryBootstrap.photos.assetsByBucket[.init(rawValue: dateIndexOldMonth)]?.map(\.id) == [dateIndexCompanionID, dateIndexTargetID])

        await source.clearReads()
        let projection = try dateIndexProjection(changed)
        _ = try await synchronizer.synchronizeRecent(scope: fixture.scope, dateProjections: [projection])
        let refreshedValue = try await store.snapshot(scope: fixture.scope)
        let refreshed = try #require(refreshedValue)
        let target = try #require(refreshed.assets.first { $0.id == dateIndexTargetID })
        #expect(target.dayKey == "2019-06-25" && target.bucketKey == dateIndexOldMonth)
        #expect(target.capturedAt == changed.capturedAt && refreshed.assets.count == ordinary.assets.count)
        let refreshedBootstrap = LibraryTimelineBootstrapBuilder.build(from: refreshed)
        #expect(refreshedBootstrap.photos.assetsByBucket[.init(rawValue: dateIndexOldMonth)]?.map(\.id) == [dateIndexTargetID, dateIndexCompanionID])
        #expect(refreshed.groups.contains { $0.mediaScope == .photos && $0.level == "day" && $0.key == "2019-06-25" && $0.assetCount == 1 })
        #expect(!refreshed.groups.contains { $0.level == "day" && $0.key == "2019-06-15" })
        #expect(await source.reads().contains(.freshBucket(dateIndexOldMonth)))
        #expect(await source.reads().contains(.freshFactory))
        #expect(!refreshed.assets.contains { $0.id == dateIndexTargetID && $0.dayKey == "2019-06-15" })
    }

    /// 当前月最后一项移到旧年月时，旧桶来自accepted记录，新桶来自真实服务端月；不能遗留重复资产或删掉无关月份。
    @Test func movingIntoAnOlderYearRetiresTheAcceptedOldBucket() async throws {
        let fixture = try DateIndexFixture()
        defer { fixture.cleanup() }
        let current = try dateIndexAsset(dateIndexTargetID, instant: "2026-11-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(nil, companion: companion)
        buckets[dateIndexRecentMonth] = [current]
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: fixture.scope)
        let originalValue = try await store.snapshot(scope: fixture.scope)
        let original = try #require(originalValue)
        let unrelated = original.assets.filter { $0.bucketKey == dateIndexUntouchedMonth }

        let moved = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        buckets.removeValue(forKey: dateIndexRecentMonth)
        buckets[dateIndexOldMonth] = [companion, moved]
        await source.replace(with: buckets)
        let projection = try dateIndexProjection(moved)
        _ = try await synchronizer.synchronizeRecent(scope: fixture.scope, dateProjections: [projection])
        let refreshedValue = try await store.snapshot(scope: fixture.scope)
        let refreshed = try #require(refreshedValue)
        #expect(refreshed.assets.count == original.assets.count)
        #expect(refreshed.assets.filter { $0.id == dateIndexTargetID }.count == 1)
        let movedRecord = try #require(refreshed.assets.first { $0.id == dateIndexTargetID })
        #expect(movedRecord.bucketKey == dateIndexOldMonth && movedRecord.yearKey == "2019" && movedRecord.monthKey == "2019-06")
        #expect(!refreshed.assets.contains { $0.bucketKey == dateIndexRecentMonth })
        #expect(refreshed.assets.filter { $0.bucketKey == dateIndexUntouchedMonth } == unrelated)
        let bootstrap = LibraryTimelineBootstrapBuilder.build(from: refreshed)
        #expect(!bootstrap.photos.summaries.contains { $0.id.rawValue == dateIndexRecentMonth })
        #expect(bootstrap.photos.assetsByBucket[.init(rawValue: dateIndexOldMonth)]?.map(\.id) == [dateIndexTargetID, dateIndexCompanionID])
    }

    /// 错误月快照必须在接受新generation前失败；被stack/query隐藏的目标也不能靠插入一条猜测记录补齐。
    @Test(arguments: ["partial", "duplicate", "changed-date", "outside-query"])
    func invalidFreshBucketCannotReplaceTheAcceptedSnapshot(_ variant: String) async throws {
        let fixture = try DateIndexFixture()
        defer { fixture.cleanup() }
        let old = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(old, companion: companion)
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope)
        let before = try #require(beforeValue)
        let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        buckets[dateIndexOldMonth] = [changed, companion]
        await source.replace(with: buckets)
        let response: [TimelineAssetSummary]
        switch variant {
        case "partial": response = [changed]
        case "duplicate": response = [changed, changed]
        case "changed-date": response = [old, companion]
        default:
            let another = try dateIndexAsset(dateIndexHiddenID, instant: "2019-06-25T12:00:00.000Z")
            response = [another, companion]
        }
        await source.overrideFreshBucket(dateIndexOldMonth, with: response)
        let projection = try dateIndexProjection(changed)
        var rejected = false
        do {
            _ = try await synchronizer.synchronizeRecent(scope: fixture.scope, dateProjections: [projection])
        } catch let error as AssetMetadataError {
            rejected = true
            switch error {
            case .dateAssetNotVisible: #expect(variant == "outside-query")
            case .dateProjectionChanged: #expect(variant != "outside-query")
            default: Issue.record("Unexpected metadata error for the forced bucket fixture")
            }
        } catch {
            Issue.record("Unexpected error type for the forced bucket fixture")
        }
        #expect(rejected)
        // 确实到达指定fresh桶后被拒绝，不能把缺factory/前置配置错误当成这四类边界通过。
        #expect(await source.reads().contains(.freshBucket(dateIndexOldMonth)))
        let afterValue = try await store.snapshot(scope: fixture.scope)
        let after = try #require(afterValue)
        #expect(after.generation == before.generation && after.assets == before.assets && after.groups == before.groups)
        #expect(!after.assets.contains { $0.id == dateIndexHiddenID })
    }

    /// 两个forced月各自完整也可能重复无关迁移项；必须在任何generation写入前拒绝全局重复，避免groups与SQLite行数分裂。
    @Test func concurrentUnrelatedMoveCannotDuplicateCanonicalRows() async throws {
        let fixture = try DateIndexFixture()
        defer { fixture.cleanup() }
        let current = try dateIndexAsset(dateIndexTargetID, instant: "2026-11-15T12:00:00.000Z")
        let unrelatedOld = try dateIndexAsset(dateIndexHiddenID, instant: "2026-11-20T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(nil, companion: companion)
        buckets[dateIndexRecentMonth] = [current, unrelatedOld]
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope)
        let before = try #require(beforeValue)
        let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        let unrelatedNew = try dateIndexAsset(dateIndexHiddenID, instant: "2019-06-26T12:00:00.000Z")
        buckets[dateIndexRecentMonth] = [unrelatedOld]
        buckets[dateIndexOldMonth] = [changed, companion]
        await source.replace(with: buckets)
        // 旧月响应仍见X旧版本，新月响应已见X新版本；两份数组的count/月/桶内唯一性都合法。
        await source.overrideFreshBucket(dateIndexOldMonth, with: [changed, unrelatedNew])
        let projection = try dateIndexProjection(changed)
        var rejected = false
        do {
            _ = try await synchronizer.synchronizeRecent(scope: fixture.scope, dateProjections: [projection])
        } catch let error as AssetMetadataError {
            if case .dateProjectionChanged = error {
                rejected = true
            } else {
                Issue.record("Unexpected metadata error for cross-month duplicate")
            }
        } catch {
            Issue.record("Unexpected error type for cross-month duplicate")
        }
        #expect(rejected)
        #expect(await source.reads().contains(.freshBucket(dateIndexRecentMonth)))
        #expect(await source.reads().contains(.freshBucket(dateIndexOldMonth)))
        let afterValue = try await store.snapshot(scope: fixture.scope)
        let after = try #require(afterValue)
        #expect(after.generation == before.generation && after.assets == before.assets && after.groups == before.groups)
    }

    /// fresh响应被真实门闩挂起后退休账号/端点的发布上下文，validator必须拒绝而不接受旧generation。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    func retiredContextRejectsACompleteButLateBucket(_ reason: String) async throws {
        let fixture = try DateIndexFixture()
        defer { fixture.cleanup() }
        let old = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(old, companion: companion)
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: fixture.scope)
        let beforeValue = try await store.snapshot(scope: fixture.scope)
        let before = try #require(beforeValue)
        let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        buckets[dateIndexOldMonth] = [changed, companion]
        await source.replace(with: buckets)
        let gate = DateIndexReadGate()
        let context = DateIndexContext()
        await source.holdFreshBucket(dateIndexOldMonth, gate: gate)
        let projection = try dateIndexProjection(changed)
        let operation = Task {
            do {
                let result = try await synchronizer.synchronizeRecent(scope: fixture.scope, dateProjections: [projection],
                                                                      validateContext: { try await context.requireCurrent() })
                await gate.operationFinished()
                return result
            } catch {
                await gate.operationFinished()
                throw error
            }
        }
        defer { operation.cancel(); Task { await gate.close() } }
        try await withTaskCancellationHandler {
            #expect(await gate.waitForEntry())
            await context.retire(reason: reason)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await operation.value }
            let afterValue = try await store.snapshot(scope: fixture.scope)
            let after = try #require(afterValue)
            #expect(after.generation == before.generation && after.assets == before.assets && after.groups == before.groups)
            #expect(await context.retirementReason() == reason)
        } onCancel: {
            operation.cancel()
            Task { await gate.close() }
        }
    }

    /// Controller正在正常同步时接到日期需求，完成当前run后必须补一轮fresh读取并发布新日期bootstrap，不能被task守卫吞掉。
    @Test(.timeLimit(.minutes(1))) @MainActor
    func activeControllerPreservesTheFollowupDateRefresh() async throws {
        let fixture = try DateIndexFixture()
        let suite = "MetadataDateIndex-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        let old = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(old, companion: companion)
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: fixture.scope)
        let controller = LibraryIndexController(source: source, store: store, cacheRootURL: fixture.cacheURL, preferences: preferences)
        let manager = LibraryManagementController()
        manager.configure(session: dateIndexSession(), endpoint: dateIndexSession().apiURL)
        manager.metadataDateRefreshAvailable = true
        var publications: [LibraryTimelineBootstrap] = []
        controller.acceptedBootstrapDidChange = { publications.append($0) }
        let gate = DateIndexReadGate()
        await source.holdNormalBucket(dateIndexRecentMonth, gate: gate)
        defer { controller.suspend(); manager.configure(session: nil, endpoint: nil); Task { await gate.close() } }

        try await withTaskCancellationHandler {
            controller.start(session: dateIndexSession(), endpoint: dateIndexSession().apiURL)
            #expect(await gate.waitForEntry())
            #expect(controller.status == .indexing)
            let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
            buckets[dateIndexOldMonth] = [changed, companion]
            await source.replace(with: buckets)
            let projection = try dateIndexProjection(changed, generation: manager.generation)
            controller.syncNow(metadataDates: [projection], manager: manager)
            await gate.release()
            // 最多加入当前run和一轮后续run；按真实任务完成等待，不用sleep推测后台时序。
            for _ in 0 ..< 3 {
                _ = await controller.finishBackgroundSync(kind: .refresh)
                if !controller.hasActiveSyncWork {
                    break
                }
            }
            #expect(controller.status == .upToDate && !controller.hasActiveSyncWork)
            let afterValue = try await store.snapshot(scope: fixture.scope)
            let after = try #require(afterValue)
            #expect(after.assets.first { $0.id == dateIndexTargetID }?.dayKey == "2019-06-25")
            let final = try #require(publications.last)
            #expect(final.photos.assetsByBucket[.init(rawValue: dateIndexOldMonth)]?.map(\.id) == [dateIndexTargetID, dateIndexCompanionID])
            #expect(final.photos.generation == after.generation)
            #expect(await source.reads().filter { $0 == .freshFactory }.count == 1)
            #expect(await source.reads().contains(.freshBucket(dateIndexOldMonth)))
        } onCancel: {
            Task { @MainActor in controller.suspend(); await gate.close() }
        }
    }

    /// 真实Controller在fresh月读取中换号/只换路由后，旧响应不得发布；route场景保持AccountSession完全相同。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    @MainActor func controllerRetirementDoesNotPublishTheOldDate(_ reason: String) async throws {
        let fixture = try DateIndexFixture()
        let suite = "MetadataDateRetirement-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        let old = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-15T12:00:00.000Z")
        let companion = try dateIndexAsset(dateIndexCompanionID, instant: "2019-06-20T12:00:00.000Z")
        var buckets = try dateIndexBuckets(old, companion: companion)
        let source = DateIndexSource(buckets: buckets)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: fixture.scope)
        let controller = LibraryIndexController(source: source, store: store, cacheRootURL: fixture.cacheURL, preferences: preferences)
        let manager = LibraryManagementController()
        let originalSession = dateIndexSession()
        manager.configure(session: originalSession, endpoint: originalSession.apiURL)
        manager.metadataDateRefreshAvailable = true
        let changed = try dateIndexAsset(dateIndexTargetID, instant: "2019-06-25T12:00:00.000Z")
        buckets[dateIndexOldMonth] = [changed, companion]
        await source.replace(with: buckets)
        let projection = try dateIndexProjection(changed, generation: manager.generation)
        let gate = DateIndexReadGate()
        await source.holdFreshBucket(dateIndexOldMonth, gate: gate)
        var retired = false
        var publicationsAfterRetirement: [LibraryTimelineBootstrap] = []
        controller.acceptedBootstrapDidChange = {
            if retired {
                publicationsAfterRetirement.append($0)
            }
        }
        defer { controller.suspend(); manager.configure(session: nil, endpoint: nil); Task { await gate.close() } }

        try await withTaskCancellationHandler {
            controller.start(session: originalSession, endpoint: originalSession.apiURL)
            controller.syncNow(metadataDates: [projection], manager: manager)
            #expect(await gate.waitForEntry())
            retired = true
            let nextSession = reason == "account" ? dateIndexSession(user: dateIndexSecondOwner) : originalSession
            let nextEndpoint = reason == "endpoint" ? originalSession.apiURL.appending(path: "fallback") : originalSession.apiURL
            manager.configure(session: nextSession, endpoint: nextEndpoint)
            await source.retireForegroundReaders()
            if reason == "account" {
                let second = try dateIndexAsset(dateIndexSecondAssetID, instant: "2026-11-25T12:00:00.000Z", owner: dateIndexSecondOwner)
                await source.replace(with: [dateIndexRecentMonth: [second]])
            }
            controller.start(session: nextSession, endpoint: nextEndpoint)
            await gate.release()
            for _ in 0 ..< 3 {
                _ = await controller.finishBackgroundSync(kind: .refresh)
                if !controller.hasActiveSyncWork {
                    break
                }
            }
            #expect(controller.status == .upToDate && !controller.hasActiveSyncWork)
            if reason == "account" {
                let nextValue = try await store.snapshot(scope: MediaAccountScope(session: nextSession))
                let next = try #require(nextValue)
                #expect(next.assets.map(\.id) == [dateIndexSecondAssetID])
                #expect(publicationsAfterRetirement.allSatisfy { bootstrap in
                    bootstrap.photos.assetsByBucket.values.flatMap(\.self).allSatisfy { $0.ownerID == dateIndexSecondOwner }
                })
            } else {
                let nextValue = try await store.snapshot(scope: fixture.scope)
                let next = try #require(nextValue)
                #expect(next.assets.first { $0.id == dateIndexTargetID }?.capturedAt == old.capturedAt)
                #expect(publicationsAfterRetirement.allSatisfy { bootstrap in
                    bootstrap.photos.assetsByBucket.values.flatMap(\.self).first { $0.id == dateIndexTargetID }?.capturedAt == old.capturedAt
                })
            }
            #expect(!publicationsAfterRetirement.isEmpty)
        } onCancel: {
            Task { @MainActor in controller.suspend(); await gate.close() }
        }
    }
}

/// 固定合成UUID和月份；不读取真实账号、照片、文件名或EXIF。
private nonisolated let dateIndexOwner = "11111111-1111-4111-8111-111111111111"
private nonisolated let dateIndexSecondOwner = "22222222-2222-4222-8222-222222222222"
private nonisolated let dateIndexTargetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let dateIndexCompanionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let dateIndexHiddenID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
private nonisolated let dateIndexSecondAssetID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
private nonisolated let dateIndexRecentMonth = "2026-11-01"
private nonisolated let dateIndexOldMonth = "2019-06-01"
private nonisolated let dateIndexUntouchedMonth = "2019-05-01"

/// 解析独立声明的UTC测试输入；不调用被测日期模型的解析/编码函数。
private nonisolated func dateIndexInstant(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

/// id/owner为合成身份，instant为独立声明UTC瞬间；返回无stack、timeline可见的真实领域成员。
private nonisolated func dateIndexAsset(_ id: String, instant: String, owner: String = dateIndexOwner) throws -> TimelineAssetSummary {
    let captured = try dateIndexInstant(instant)
    return .init(id: id, ownerID: owner, capturedAt: captured, uploadedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 4.0 / 3.0,
                 isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
                 thumbhash: nil, thumbnailRevision: Date(timeIntervalSince1970: 1_800_000_000))
}

/// asset是预期已派生的合成成员；通过独立JSON和真实confirmed方法获得投影，不能绕过领域校验构造假成功。
private nonisolated func dateIndexProjection(_ asset: TimelineAssetSummary, generation: UUID = UUID()) throws -> AssetMetadataDateProjection {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: asset.capturedAt)
    let json = #"{"id":"\#(asset.id)","ownerId":"\#(asset.ownerID)","type":"IMAGE","visibility":"timeline","isTrashed":false,"originalFileName":"synthetic.jpg","fileCreatedAt":"\#(timestamp)","localDateTime":"\#(timestamp)","exifInfo":{"dateTimeOriginal":"\#(timestamp)","timeZone":"UTC","latitude":30,"longitude":120,"rating":null}}"#
    let snapshot = try JSONDecoder().decode(AssetMetadataSnapshot.self, from: Data(json.utf8))
    return try #require(AssetMetadataDateProjection.confirmed(snapshot, expectedInstant: asset.capturedAt, accountGeneration: generation))
}

/// target可缺省以准备跨月输入，companion为旧月另一项；总共四个月确保旧月不在正常prefix2范围内。
private nonisolated func dateIndexBuckets(_ target: TimelineAssetSummary?, companion: TimelineAssetSummary) throws -> [String: [TimelineAssetSummary]] {
    let newest = try dateIndexAsset("33333333-3333-4333-8333-333333333333", instant: "2026-11-10T12:00:00.000Z")
    let second = try dateIndexAsset("44444444-4444-4444-8444-444444444444", instant: "2026-10-10T12:00:00.000Z")
    let untouched = try dateIndexAsset("55555555-5555-4555-8555-555555555555", instant: "2019-05-10T12:00:00.000Z")
    return [dateIndexRecentMonth: [newest], "2026-10-01": [second],
            dateIndexOldMonth: (target.map { [$0] } ?? []) + [companion], dateIndexUntouchedMonth: [untouched]]
}

/// user为固定合成账号；仅提供Index/manager身份，不会发起HTTP或触达Keychain。
private nonisolated func dateIndexSession(user: String = dateIndexOwner) -> AccountSession {
    .init(apiURL: URL(string: "https://metadata-date-index.invalid/api")!, accessToken: "synthetic-date-token", userID: user,
          userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// 每例独立临时SQLite文件和缓存根；cleanup只移除本例创建的目录。
private nonisolated struct DateIndexFixture: Sendable {
    let root: URL
    let databaseURL: URL
    let cacheURL: URL
    let scope = MediaAccountScope(session: dateIndexSession())

    /// 在系统测试临时目录建立随机子目录，不打开或复制任何现有账号库。
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MetadataDateIndex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "index.sqlite3")
        cacheURL = root.appending(path: "cache", directoryHint: .isDirectory)
    }

    /// 仅清理本例私有文件，不清空数据库表或其他fixture。
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 记录实际普通/foreground读取路径，断言生产同步器没有用旧读通道冒充fresh。
private nonisolated enum DateIndexRead: Equatable, Sendable {
    case normalSummary, normalBucket(String), freshFactory, freshSummary, freshBucket(String)
}

/// 合成服务端边界；普通响应可被挂起成旧快照，foreground reader绑定代际并提供独立完整月响应。
private actor DateIndexSource: TimelineReading, ManagementTimelineProviding {
    private var buckets: [String: [TimelineAssetSummary]]
    private var overrides: [String: [TimelineAssetSummary]] = [:]
    private var captured: [DateIndexRead] = []
    private var generation = 0
    private var normalHolds: [String: DateIndexReadGate] = [:]
    private var freshHolds: [String: DateIndexReadGate] = [:]

    /// buckets为真实query应返回的合成完整月；summary数量始终来自它，不能被错误payload同步“修正”。
    init(buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    /// 更新模拟服务端当前数据，不改变已经捕获并挂起的旧响应。
    func replace(with buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets; overrides = [:]
    }

    /// bucket/values仅替换fresh成员响应，保留真实summary count，以覆盖截断/重复/不匹配回执。
    func overrideFreshBucket(_ bucket: String, with values: [TimelineAssetSummary]) {
        overrides[bucket] = values
    }

    /// 将一次普通读取挂在明确门闩上；门闩只控制到达/释放，不猜测时间。
    func holdNormalBucket(_ bucket: String, gate: DateIndexReadGate) {
        normalHolds[bucket] = gate
    }

    /// 将一次前台读取挂起，供context/route退休与后续需求测试使用。
    func holdFreshBucket(_ bucket: String, gate: DateIndexReadGate) {
        freshHolds[bucket] = gate
    }

    /// 模拟仓库端点/账号退休，所有先前创建的foreground reader均失去读取权。
    func retireForegroundReaders() {
        generation += 1
    }

    /// 清除历史调用记录，仅用于限定本次targeted pass的真实端口断言。
    func clearReads() {
        captured = []
    }

    /// 返回实际端口调用快照，不向同步器提供预期结果。
    func reads() -> [DateIndexRead] {
        captured
    }

    /// query必须保持主时间线既有过滤；返回普通通道当前完整summary。
    func bucketSummaries(query: TimelineQuery) throws -> [TimelineBucketSummary] {
        try requireDefaultQuery(query)
        captured.append(.normalSummary)
        return summaries()
    }

    /// 普通响应在挂起前捕获；之后服务端变化不能把旧在途响应伪装成fresh。
    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        try requireDefaultQuery(query)
        captured.append(.normalBucket(bucketID.rawValue))
        let values = buckets[bucketID.rawValue, default: []]
        if let gate = normalHolds.removeValue(forKey: bucketID.rawValue) {
            await gate.enterAndWait()
        }
        return values
    }

    /// 本测试不生成回忆，不能从空回忆旁路给索引添加资产。
    func memories() -> [TimelineMemorySummary] {
        []
    }

    /// 记录真实factory调用并绑定当前代际，不把普通reader原样作为fresh交付。
    func managementTimelineReader() -> any TimelineReading {
        captured.append(.freshFactory)
        return FreshReader(source: self, generation: generation)
    }

    /// 当前真实summary不受错误成员payload影响，旧factory须在前后两次读取都保持有效。
    private func freshSummaries(query: TimelineQuery, owner: Int) throws -> [TimelineBucketSummary] {
        try requireDefaultQuery(query)
        guard owner == generation else { throw CancellationError() }
        captured.append(.freshSummary)
        return summaries()
    }

    /// 捕获本次真实成员后可挂起；即便任务取消不合作，factory退休仍拒绝旧返回值。
    private func freshAssets(in bucket: TimelineBucketID, query: TimelineQuery, owner: Int) async throws -> [TimelineAssetSummary] {
        try requireDefaultQuery(query)
        guard owner == generation else { throw CancellationError() }
        captured.append(.freshBucket(bucket.rawValue))
        let values = overrides[bucket.rawValue] ?? buckets[bucket.rawValue, default: []]
        if let gate = freshHolds.removeValue(forKey: bucket.rawValue) {
            await gate.enterAndWait()
        }
        guard owner == generation else { throw CancellationError() }
        return values
    }

    /// 生成完整月份统计，顺序由被测同步器决定。
    private func summaries() -> [TimelineBucketSummary] {
        buckets.map { .init(id: .init(rawValue: $0.key), assetCount: $0.value.count) }
    }

    /// 不允许测试通过篡改visibility/stack/partner过滤获得目标成员。
    private func requireDefaultQuery(_ query: TimelineQuery) throws {
        guard query == TimelineQuery() else { throw URLError(.badServerResponse) }
    }

    /// 独立foreground端口只向原actor委托带代际的方法，不持有数据库或伪造成员。
    private nonisolated struct FreshReader: TimelineReading {
        let source: DateIndexSource
        let generation: Int

        /// query保留主时间线原过滤，返回当前代际的实际summary。
        func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
            try await source.freshSummaries(query: query, owner: generation)
        }

        /// bucketID/query指定实际完整月；原actor检查退休与挂起后的代际。
        func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
            try await source.freshAssets(in: bucketID, query: query, owner: generation)
        }

        /// 日期刷新不需要回忆，返回空集合不添加任何资产。
        func memories() async throws -> [TimelineMemorySummary] {
            []
        }
    }
}

/// 可控发布上下文；退休发生在真实在途请求到达后，validator负责拒绝旧结果而非修改被测同步器。
private actor DateIndexContext {
    private var reason: String?

    /// 返回无；只有当前上下文有效，退休后抛CancellationError。
    func requireCurrent() throws {
        if reason != nil {
            throw CancellationError()
        }
    }

    /// reason标明本例是账号还是端点退休，不影响服务端合成payload。
    func retire(reason: String) {
        self.reason = reason
    }

    /// 返回本例实际执行的退休原因，避免参数化测试变成相同空路径。
    func retirementReason() -> String? {
        reason
    }
}

/// 请求到达/释放/结束的单次门闩；10秒watchdog只处理死锁失败，不用sleep推进业务步骤。
private actor DateIndexReadGate {
    private var entered = false
    private var released = false
    private var finished = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?

    /// 真实请求到达后记录并等待；提前release/cleanup也不能留下不可恢复的continuation。
    func enterAndWait() async {
        entered = true
        observer?.resume(returning: true); observer = nil
        watchdog?.cancel(); watchdog = nil
        guard !released else { return }
        await withCheckedContinuation { pending = $0 }
    }

    /// 等待真实请求到达；操作早失败或watchdog到期返回false并释放等待方，不能伪造业务成功。
    func waitForEntry() async -> Bool {
        if entered {
            return true
        }
        if finished || released {
            return false
        }
        return await withCheckedContinuation { continuation in
            observer = continuation
            watchdog = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                    await self?.close()
                } catch {}
            }
        }
    }

    /// 仅业务明确执行该步骤时释放响应；不会改变响应字段或取消标志。
    func release() {
        released = true; pending?.resume(); pending = nil
    }

    /// 实际业务已完成且从未到门时唤醒观察者，避免前置失败变成超时挂起。
    func operationFinished() {
        finished = true
        if !entered {
            observer?.resume(returning: false); observer = nil
        }
        watchdog?.cancel(); watchdog = nil
    }

    /// 失败/取消/清理一律唤醒所有等待方；旧响应能否发布仍由真实生产门禁决定。
    func close() {
        finished = true
        observer?.resume(returning: false); observer = nil
        release()
        watchdog?.cancel(); watchdog = nil
    }
}
