import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实元数据Store/manager/HTTP契约；只注入纯合成响应和时序，不用生产编码器造预期请求。
@Suite("Asset metadata management")
struct AssetMetadataStoreTests {
    /// kind覆盖日期/时区、零坐标/边界、评分set/rejected/clear/keep和组合写；其他资源字段绝不进入PUT。
    @Test(arguments: ["date", "location-equator", "location-meridian", "location-edge", "stars", "rejected", "clear", "combined"])
    @MainActor func preflightsAndConfirmsOnlyTheSelectedFields(_ kind: String) async throws {
        var patch = AssetMetadataPatch()
        var fields: [String] = []
        let hasDate = kind == "date" || kind == "combined"
        let hasLocation = kind.hasPrefix("location") || kind == "combined"
        let rating: String
        if hasDate {
            let instant = try #require(AssetMetadataDateValue.parse("2026-11-25T06:49:56.789Z"))
            patch.date = .init(instant: instant, offsetMinutes: 345)
            fields.append(#""dateTimeOriginal":"2026-11-25T12:34:56.789+05:45""#)
        }
        if hasLocation {
            let latitude: Double = kind == "location-edge" ? -90 : kind == "location-meridian" ? 30 : 0
            let longitude: Double = kind == "location-edge" ? 180 : kind == "location-meridian" ? 0 : 120
            patch.location = .init(latitude: latitude, longitude: longitude)
            fields.append(kind == "location-edge" ? #""latitude":-90,"longitude":180"# : kind == "location-meridian" ? #""latitude":30,"longitude":0"# : #""latitude":0,"longitude":120"#)
        }
        switch kind {
        case "stars": patch.rating = .set(5); rating = "5"; fields.append(#""rating":5"#)
        case "rejected": patch.rating = .set(-1); rating = "-1"; fields.append(#""rating":-1"#)
        case "clear", "combined": patch.rating = .clear; rating = "null"; fields.append(#""rating":null"#)
        default: rating = "0"
        }
        let updated = metadataJSON(date: hasDate ? "2026-11-25T06:49:56.789Z" : "2026-11-24T04:00:00.000Z",
                                   zone: hasDate ? "UTC+5:45" : "UTC+8",
                                   latitude: hasLocation ? (kind == "location-edge" ? -90 : kind == "location-meridian" ? 30 : 0) : 30,
                                   longitude: hasLocation ? (kind == "location-edge" ? 180 : kind == "location-meridian" ? 0 : 120) : 120,
                                   rating: rating, version: "after")
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(), metadataRead(),
                                                      .init(method: "PUT", path: metadataPath, status: 200, json: updated), metadataRead(updated)])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        #expect(store.snapshot?.exifInfo?.rating == 0)
        let plan = try store.prepare(patch, manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.hasFreshData && !store.isWorking && !fixture.manager.busy && store.error == nil && store.notice != nil)
        #expect(store.confirmedChanges == 1 && fixture.manager.revision == 1 && store.savedAccountGeneration == fixture.manager.generation)
        #expect(store.snapshot?.livePhotoVideoId == metadataPartnerID)
        let requests = await fixture.script.requests()
        try #require(requests.count == 4)
        #expect(requests.map(\.method) == ["GET", "GET", "PUT", "GET"])
        try assertMetadataBody(requests[2], expected: "{" + fields.joined(separator: ",") + "}")
        let confirmed = try #require(store.snapshot)
        #expect(patch.isConfirmed(by: confirmed))
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 4)
    }

    /// 预检读取发现字段/版本已变化时不得PUT；旧页面确认不会把其他客户端的新值覆盖掉。
    @Test @MainActor func remoteChangesBeforeWriteRequireANewReview() async throws {
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(), metadataRead(metadataJSON(rating: "5", version: "changed"))])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        let plan = try store.prepare(.init(rating: .set(1)), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(!store.hasFreshData && store.notice == nil && store.error == AssetMetadataError.changedRemotely.errorDescription)
        #expect(store.confirmedChanges == 0 && fixture.manager.revision == 0 && !fixture.manager.busy)
        #expect(await fixture.script.requests().map(\.method) == ["GET", "GET"])
    }

    /// 读取也要求精确200、正确身份和有效DTO；错误码/错误资源/畸形对象不能给后续写入授权。
    @Test(arguments: ["201", "403", "wrong-id", "invalid-object"])
    @MainActor func refusesUnconfirmedFreshReads(_ variant: String) async throws {
        let fixture = MetadataHTTPFixture(exchanges: [.init(method: "GET", path: metadataPath, status: Int(variant) ?? 200,
                                                            json: variant == "invalid-object" ? "{}" : metadataJSON(id: variant == "wrong-id" ? metadataOtherID : metadataID))])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        let task = try #require(store.reload(assetID: metadataID, manager: fixture.manager))
        await task.value
        #expect(!store.hasFreshData && store.snapshot == nil && store.error != nil && !store.isLoading)
        #expect(throws: AssetMetadataError.self) { try store.prepare(.init(rating: .clear), manager: fixture.manager) }
        #expect(fixture.manager.revision == 0)
        #expect(await fixture.script.requests().count == 1)
    }

    /// 错误成功码/HTTP拒绝/5xx/字段错误/缺少null回执都不能确认保存；不自动进行写后重试。
    @Test(arguments: ["status201", "401", "403", "409", "429", "503", "missing-rating", "wrong-rating", "wrong-owner", "wrong-id", "wrong-zone"])
    @MainActor func refusesRejectedOrUnconfirmedWrites(_ variant: String) async throws {
        let dateWrite = variant == "wrong-zone"
        let instant = try #require(AssetMetadataDateValue.parse("2026-11-25T06:49:56.789Z"))
        let patch = dateWrite ? AssetMetadataPatch(date: .init(instant: instant, offsetMinutes: 345))
            : AssetMetadataPatch(rating: .clear)
        let status = variant == "status201" ? 201 : Int(variant) ?? 200
        let reply = metadataJSON(id: variant == "wrong-id" ? metadataOtherID : metadataID,
                                 owner: variant == "wrong-owner" ? metadataOtherOwner : metadataOwner,
                                 date: dateWrite ? "2026-11-25T06:49:56.789Z" : "2026-11-24T04:00:00.000Z",
                                 zone: dateWrite ? "UTC" : "UTC+8",
                                 rating: variant == "missing-rating" ? nil : variant == "wrong-rating" ? "3" : "null", version: "after")
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(), metadataRead(), .init(method: "PUT", path: metadataPath, status: status, json: reply)])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        let plan = try store.prepare(patch, manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(!store.hasFreshData && !store.isWorking && store.notice == nil && store.error != nil && store.confirmedChanges == 0)
        #expect(fixture.manager.revision == ((400 ..< 500).contains(status) ? 0 : 1))
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 3)
    }

    /// 已确认写入后GET失败或值被其他客户端再次改动，仍保留保存回执，但不能声称已获得可继续编辑的fresh状态。
    @Test(arguments: [false, true])
    @MainActor func savedWriteAndFailedOrChangedReadbackRemainDistinct(_ changedAgain: Bool) async throws {
        let updated = metadataJSON(rating: "5", version: "after")
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(), metadataRead(), .init(method: "PUT", path: metadataPath, status: 200, json: updated),
                                                      .init(method: "GET", path: metadataPath, status: changedAgain ? 200 : 503,
                                                            json: changedAgain ? metadataJSON(rating: "1", version: "newer") : "{}"), metadataRead(updated)])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        let plan = try store.prepare(.init(rating: .set(5)), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.notice != nil && store.error != nil && !store.hasFreshData && store.confirmedChanges == 1)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        try await loadMetadata(store, fixture: fixture)
        #expect(store.snapshot?.exifInfo?.rating == 5)
        _ = try store.prepare(.init(rating: .clear), manager: fixture.manager)
        #expect(await fixture.script.requests().count == 5)
    }

    /// source区分共享与回收站；可读不代表可写，真实GET以后仍须拒绝本地确认而不发送PUT。
    @Test(arguments: ["shared", "trash"])
    @MainActor func ownershipAndTrashRemainWriteGates(_ source: String) async throws {
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(metadataJSON(owner: source == "shared" ? metadataOtherOwner : metadataOwner, trashed: source == "trash"))])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        #expect(throws: AssetMetadataError.self) { try store.prepare(.init(rating: .set(2)), manager: fixture.manager) }
        #expect(await fixture.script.requests().count == 1)
    }

    /// 取消真实在途预检不发送PUT；取消在途PUT只算未知；取消已确认后的重读仍保留真实保存回执。
    @Test(.timeLimit(.minutes(1)), arguments: ["preflight", "write", "readback"])
    @MainActor func cancellationPreservesTheActualWriteBoundary(_ stage: String) async throws {
        let updated = metadataJSON(rating: "5", version: "after")
        var exchanges = [metadataRead(), MetadataExchange(method: "GET", path: metadataPath, status: 200, json: metadataJSON(), held: stage == "preflight")]
        if stage != "preflight" {
            exchanges.append(.init(method: "PUT", path: metadataPath, status: 200, json: updated, held: stage == "write"))
        }
        if stage == "readback" {
            exchanges.append(.init(method: "GET", path: metadataPath, status: 200, json: updated, held: true))
        }
        let fixture = MetadataHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetMetadataStore()
            try await loadMetadata(store, fixture: fixture)
            let plan = try store.prepare(.init(rating: .set(5)), manager: fixture.manager)
            let operation = try #require(store.start(plan, manager: fixture.manager))
            let completion = Task { await operation.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            store.cancel()
            await fixture.script.release()
            await completion.value
            #expect(!store.hasFreshData && !store.isWorking && store.error != nil && !fixture.manager.busy)
            #expect((store.notice != nil) == (stage == "readback"))
            #expect(store.confirmedChanges == (stage == "readback" ? 1 : 0))
            #expect(fixture.manager.revision == (stage == "preflight" ? 0 : 1))
            #expect(await fixture.script.requests().count == exchanges.count)
        } onCancel: {
            Task { @MainActor in fixture.close() }
        }
    }

    /// context区分账号/路由变化；旧在途PUT不能发布到新上下文，UI onChange前的旧快照也不能产生新确认。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    @MainActor func obsoleteAccountOrEndpointCannotPublish(_ context: String) async throws {
        let nextUser = context == "account" ? metadataOtherOwner : metadataOwner
        let prefix = context == "endpoint" ? "fallback/" : ""
        let nextJSON = metadataJSON(id: metadataOtherID, owner: nextUser, rating: "3", version: "next")
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead(), metadataRead(),
                                                      .init(method: "PUT", path: metadataPath, status: 200, json: metadataJSON(rating: "5", version: "after"), held: true),
                                                      .init(method: "GET", path: prefix + "assets/\(metadataOtherID)", status: 200, json: nextJSON,
                                                            authorization: context == "account" ? "Bearer metadata-next" : "Bearer metadata-owner")])
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetMetadataStore()
            try await loadMetadata(store, fixture: fixture)
            let oldPlan = try store.prepare(.init(rating: .set(5)), manager: fixture.manager)
            let operation = try #require(store.start(oldPlan, manager: fixture.manager))
            let completion = Task { await operation.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            let endpoint = context == "endpoint" ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
            // 路由切换保持登录Session逐字段不变，仅替换请求endpoint，独立覆盖manager的端点代际分支。
            fixture.manager.configure(session: metadataSession(endpoint: fixture.endpoint, user: nextUser, token: context == "account" ? "metadata-next" : "metadata-owner"), endpoint: endpoint)
            #expect(throws: AssetMetadataError.self) { try store.prepare(.init(rating: .clear), manager: fixture.manager) }
            store.invalidate(manager: fixture.manager)
            let read = try #require(store.reload(assetID: metadataOtherID, manager: fixture.manager))
            await read.value
            #expect(store.snapshot?.id == metadataOtherID && store.hasFreshData && store.snapshot?.ownerId == nextUser)
            #expect(store.start(oldPlan, manager: fixture.manager) == nil)
            await fixture.script.release()
            await completion.value
            #expect(store.snapshot?.id == metadataOtherID && store.snapshot?.exifInfo?.rating == 3 && store.hasFreshData)
            #expect(store.confirmedChanges == 0 && store.notice == nil && fixture.manager.revision == 0 && !fixture.manager.busy)
            #expect(await fixture.script.requests().count == 4)
        } onCancel: {
            Task { @MainActor in fixture.close() }
        }
    }

    /// 初次GET也受停止等待/页面/账号/端点退休约束；旧请求不能恢复fresh状态或覆盖新上下文。
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "page", "account", "endpoint"])
    @MainActor func initialReadsCannotOutliveTheirContext(_ context: String) async throws {
        let changesAccount = context == "account"
        let changesEndpoint = context == "endpoint"
        let replacesContext = changesAccount || changesEndpoint
        let nextUser = changesAccount ? metadataOtherOwner : metadataOwner
        let prefix = changesEndpoint ? "fallback/" : ""
        var exchanges = [MetadataExchange(method: "GET", path: metadataPath, status: 200, json: metadataJSON(), held: true)]
        if replacesContext {
            exchanges.append(.init(method: "GET", path: prefix + "assets/\(metadataOtherID)", status: 200,
                                   json: metadataJSON(id: metadataOtherID, owner: nextUser, rating: "3", version: "next"),
                                   authorization: changesAccount ? "Bearer metadata-next" : "Bearer metadata-owner"))
        }
        let fixture = MetadataHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetMetadataStore()
            let read = try #require(store.reload(assetID: metadataID, manager: fixture.manager))
            let completion = Task { await read.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            if context == "cancel" {
                store.cancel()
            } else {
                if replacesContext {
                    let endpoint = changesEndpoint ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
                    fixture.manager.configure(session: metadataSession(endpoint: fixture.endpoint, user: nextUser,
                                                                       token: changesAccount ? "metadata-next" : "metadata-owner"), endpoint: endpoint)
                }
                store.invalidate(manager: fixture.manager)
            }
            if replacesContext {
                let replacement = try #require(store.reload(assetID: metadataOtherID, manager: fixture.manager))
                await replacement.value
            }
            await fixture.script.release()
            await completion.value
            #expect(!store.isLoading && !store.isWorking && store.error == nil && store.notice == nil)
            #expect(store.confirmedChanges == 0 && fixture.manager.revision == 0 && !fixture.manager.busy)
            if replacesContext {
                #expect(store.hasFreshData && store.snapshot?.id == metadataOtherID && store.snapshot?.ownerId == nextUser)
                #expect(store.snapshot?.exifInfo?.rating == 3)
            } else {
                #expect(!store.hasFreshData && store.snapshot == nil)
                #expect(throws: AssetMetadataError.self) { try store.prepare(.init(rating: .clear), manager: fixture.manager) }
            }
            #expect(await fixture.script.requests().map(\.method) == Array(repeating: "GET", count: exchanges.count))
        } onCancel: {
            Task { @MainActor in fixture.close() }
        }
    }

    /// 真实详情200若只有EXIF更新不能发布日期意图；有限重读后需同时核metadata、真实瞬间和墙上时间。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func dateProjectionWaitsForActualAssetDates(_ becomesReady: Bool) async throws {
        let waiting = metadataJSON(fileCreated: "2026-11-23T04:00:00.000Z", localDate: "2026-11-23T12:00:00.000Z")
        let ready = metadataJSON(fileCreated: "2026-11-24T04:00:00.000Z", localDate: "2026-11-24T12:00:00.000Z")
        let reads = becomesReady ? [metadataRead(waiting), metadataRead(waiting), metadataRead(ready)]
            : [metadataRead(waiting), metadataRead(waiting), metadataRead(waiting), metadataRead(waiting)]
        let fixture = MetadataHTTPFixture(exchanges: reads)
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        fixture.manager.metadataDateRefreshAvailable = true
        let check = try #require(store.refreshTimelineDate(manager: fixture.manager))
        await check.value
        let intents = fixture.manager.takeMetadataDateProjections()
        #expect(!store.isCheckingDateProjection && store.dateProjectionNotice != nil)
        #expect(intents.count == (becomesReady ? 1 : 0))
        #expect(fixture.manager.revision == (becomesReady ? 1 : 0))
        if becomesReady {
            let intent = try #require(intents.first)
            #expect(intent.assetID == metadataID && intent.accountGeneration == fixture.manager.generation)
            #expect(intent.capturedAt == AssetMetadataDateValue.parse("2026-11-24T04:00:00.000Z"))
            #expect(intent.localDateTime == AssetMetadataDateValue.parse("2026-11-24T12:00:00.000Z"))
        }
        #expect(await fixture.script.requests().map(\.method) == Array(repeating: "GET", count: reads.count))
    }

    /// 迟到的派生详情不可在取消、退页、换号或只换端点后发布旧日期意图；新页面状态保持不变。
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "page", "account", "endpoint"])
    @MainActor func dateProjectionRetirementCannotPublishOldIntent(_ context: String) async throws {
        let changesAccount = context == "account"
        let changesEndpoint = context == "endpoint"
        let replacesContext = changesAccount || changesEndpoint
        let nextUser = changesAccount ? metadataOtherOwner : metadataOwner
        let prefix = changesEndpoint ? "fallback/" : ""
        var exchanges = [metadataRead(), MetadataExchange(method: "GET", path: metadataPath, status: 200,
                                                          json: metadataJSON(fileCreated: "2026-11-24T04:00:00.000Z",
                                                                             localDate: "2026-11-24T12:00:00.000Z"), held: true)]
        if replacesContext {
            exchanges.append(.init(method: "GET", path: prefix + "assets/\(metadataOtherID)", status: 200,
                                   json: metadataJSON(id: metadataOtherID, owner: nextUser, rating: "3", version: "next"),
                                   authorization: changesAccount ? "Bearer metadata-next" : "Bearer metadata-owner"))
        }
        let fixture = MetadataHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetMetadataStore()
            try await loadMetadata(store, fixture: fixture)
            fixture.manager.metadataDateRefreshAvailable = true
            let check = try #require(store.refreshTimelineDate(manager: fixture.manager))
            let completion = Task { await check.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            if context == "cancel" {
                store.cancel()
            } else {
                if replacesContext {
                    let endpoint = changesEndpoint ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
                    fixture.manager.configure(session: metadataSession(endpoint: fixture.endpoint, user: nextUser,
                                                                       token: changesAccount ? "metadata-next" : "metadata-owner"), endpoint: endpoint)
                }
                store.invalidate(manager: fixture.manager)
            }
            if replacesContext {
                let replacement = try #require(store.reload(assetID: metadataOtherID, manager: fixture.manager))
                await replacement.value
            }
            await fixture.script.release()
            await completion.value
            #expect(fixture.manager.takeMetadataDateProjections().isEmpty && fixture.manager.revision == 0)
            if replacesContext {
                #expect(store.snapshot?.id == metadataOtherID && store.snapshot?.ownerId == nextUser && store.hasFreshData)
                #expect(store.dateProjectionNotice == nil && !store.isCheckingDateProjection)
            } else {
                #expect(!store.isCheckingDateProjection)
            }
            #expect(await fixture.script.requests().map(\.method) == Array(repeating: "GET", count: exchanges.count))
        } onCancel: {
            Task { @MainActor in fixture.close() }
        }
    }

    /// 单位/空值/非法评分必须在HTTP前拒绝；0/0仍按官方PUT范围编码，不据此断言异步处理后的持久位置。
    @Test @MainActor func rejectsInvalidInputsAndPreservesExplicitNull() async throws {
        let fixture = MetadataHTTPFixture(exchanges: [metadataRead()])
        defer { fixture.close() }
        let store = AssetMetadataStore()
        try await loadMetadata(store, fixture: fixture)
        let date = Date(timeIntervalSince1970: 0)
        let invalid: [AssetMetadataPatch] = [.init(), .init(rating: .set(0)), .init(rating: .set(6)), .init(rating: .set(-2)),
                                             .init(location: .init(latitude: .nan, longitude: 0)), .init(location: .init(latitude: 91, longitude: 0)),
                                             .init(location: .init(latitude: 0, longitude: -.infinity)), .init(location: .init(latitude: 0, longitude: -181)),
                                             .init(date: .init(instant: date, offsetMinutes: .min)), .init(date: .init(instant: Date(timeIntervalSince1970: .infinity), offsetMinutes: 0))]
        for patch in invalid {
            #expect(throws: AssetMetadataError.self) { try store.prepare(patch, manager: fixture.manager) }
            #expect(throws: AssetMetadataError.self) { try JSONEncoder().encode(patch) }
        }
        let clear = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AssetMetadataPatch(rating: .clear))) as? [String: Any]
        #expect(clear?.count == 1 && clear?["rating"] is NSNull)
        let nullIsland = AssetMetadataPatch(location: .init(latitude: 0, longitude: 0))
        try nullIsland.validate()
        let coordinates = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nullIsland)) as? [String: Any]
        #expect(coordinates?.count == 2 && coordinates?["latitude"] as? Double == 0 && coordinates?["longitude"] as? Double == 0)
        #expect(AssetMetadataDateValue.offset(name: "UTC+5:45", at: date) == 345)
        #expect(AssetMetadataDateValue.offset(name: "UTC-03:30", at: date) == -210)
        #expect(await fixture.script.requests().count == 1)
    }
}

/// 所有身份、关联、文件名及EXIF均为固定合成值，不读取真实媒体或凭据。
private nonisolated let metadataID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let metadataOtherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let metadataOwner = "11111111-1111-4111-8111-111111111111"
private nonisolated let metadataOtherOwner = "22222222-2222-4222-8222-222222222222"
private nonisolated let metadataPartnerID = "44444444-4444-4444-8444-444444444444"
private nonisolated let metadataPath = "assets/\(metadataID)"

/// 参数是独立声明的响应值，rating为JSON片段、nil明确省略该键；不调用生产模型的编码器。
private nonisolated func metadataJSON(id: String = metadataID, owner: String = metadataOwner, trashed: Bool = false,
                                      date: String = "2026-11-24T04:00:00.000Z", zone: String = "UTC+8", latitude: Double = 30,
                                      longitude: Double = 120, rating: String? = "0", version: String = "before",
                                      fileCreated: String? = nil, localDate: String? = nil) -> String
{
    let ratingField = rating.map { #", "rating":\#($0)"# } ?? ""
    let fileField = fileCreated.map { #", "fileCreatedAt":"\#($0)""# } ?? ""
    let localField = localDate.map { #", "localDateTime":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","ownerId":"\#(owner)","type":"IMAGE","visibility":"timeline","isTrashed":\#(trashed),"originalFileName":"synthetic.jpg","livePhotoVideoId":"\#(metadataPartnerID)","updatedAt":"\#(version)"\#(fileField)\#(localField),"exifInfo":{"dateTimeOriginal":"\#(date)","timeZone":"\#(zone)","latitude":\#(latitude),"longitude":\#(longitude)\#(ratingField)}}"#
}

/// json为固定响应字节；返回一次真实单资源读取交换。
private nonisolated func metadataRead(_ json: String = metadataJSON()) -> MetadataExchange {
    .init(method: "GET", path: metadataPath, status: 200, json: json)
}

/// endpoint/user/token定义隔离登录，endpoint变更仍走实际manager代际逻辑，不访问Keychain。
private nonisolated func metadataSession(endpoint: URL, user: String = metadataOwner, token: String = "metadata-owner") -> AccountSession {
    .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// store/fixture通过真实reload入口准备fresh快照；等待实际HTTP完成，不手工设置业务状态。
@MainActor private func loadMetadata(_ store: AssetMetadataStore, fixture: MetadataHTTPFixture) async throws {
    let task = try #require(store.reload(assetID: metadataID, manager: fixture.manager))
    await task.value
    #expect(store.hasFreshData && !store.isLoading && store.error == nil)
}

/// 一次固定HTTP响应，held仅控制在途时序，authorization用于换账号后的真实新Bearer断言。
nonisolated struct MetadataExchange: Sendable {
    let method: String
    let path: String
    let status: Int
    let json: String
    var held = false
    var authorization = "Bearer metadata-owner"
}

/// 有限JSON请求快照；不把Foundation输入流跨actor共享。
nonisolated struct MetadataRequest: Sendable {
    let id = UUID()
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let cookie: String?
    let body: Data?

    /// request来自本测试会话；完整读取最多100KB，未设置body的GET保持nil。
    init(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else { throw URLError(.badURL) }
        self.method = method; self.url = url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        cookie = request.value(forHTTPHeaderField: "Cookie")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 100_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = bytes
        } else {
            body = nil
        }
    }
}

/// 每个随机host独立的响应顺序/等待门；业务提前失败也唤醒观察者，不靠sleep推进场景。
actor MetadataHTTPScript {
    private let exchanges: [MetadataExchange]
    private var captured: [MetadataRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var held = false
    private var finished = false
    private var stopped = false
    private var heldRequestID: UUID?
    private var responderExits = Set<UUID>()
    private var exitObserver: CheckedContinuation<Void, Never>?

    /// exchanges是独立响应剧本，不从Store/patch反推成功值。
    init(_ exchanges: [MetadataExchange]) {
        self.exchanges = exchanges
    }

    /// request/endpoint记录实际路径、身份和body；未知多余请求直接失败，绝不访问外网。
    func response(_ request: MetadataRequest, endpoint: URL) async throws -> MetadataExchange {
        guard !stopped else { throw CancellationError() }
        let index = captured.count; captured.append(request)
        guard exchanges.indices.contains(index) else { throw URLError(.badServerResponse) }
        let exchange = exchanges[index]
        guard request.method == exchange.method, request.url == endpoint.appending(path: exchange.path),
              request.authorization == exchange.authorization, request.cookie == nil,
              request.contentType == (request.body == nil ? nil : "application/json") else { throw URLError(.badServerResponse) }
        if exchange.held {
            heldRequestID = request.id
            await withCheckedContinuation { continuation in
                pending = continuation; held = true; observer?.resume(returning: true); observer = nil
            }
        }
        return exchange
    }

    /// 返回捕获值供测试独立断言，不在传输回调中伪造业务成功。
    func requests() -> [MetadataRequest] {
        captured
    }

    /// 实际请求到达门后返回true；操作若先失败返回false，避免断言无法到达时永远挂起。
    func waitForHeld() async -> Bool {
        if held {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { observer = $0 }
    }

    /// 真实操作结束时唤醒未到门的观察者，不返回任何伪造HTTP结果。
    func operationFinished() {
        finished = true; if !held {
            observer?.resume(returning: false); observer = nil
        }
    }

    /// 测试明确释放旧响应；URLProtocol仍必须遵守真实取消，不强行交付迟到字节。
    func release() {
        pending?.resume(); pending = nil
    }

    /// requestID由真实URLProtocol任务结束路径报告；只唤醒对应被hold的响应退出观察者。
    func responderExited(_ requestID: UUID) {
        responderExits.insert(requestID)
        if requestID == heldRequestID {
            exitObserver?.resume(); exitObserver = nil
        }
    }

    /// 等待实际hold响应任务结束，而非仅业务任务结束；提前失败/清理时无不可达等待。
    func waitForHeldResponderExit() async {
        guard let heldRequestID, !responderExits.contains(heldRequestID), !stopped else { return }
        await withCheckedContinuation { exitObserver = $0 }
    }

    /// 失败/超时清理同时释放响应和观察者；清理先于请求到门时也不再新建不可唤醒的continuation。
    func stop() {
        stopped = true; finished = true; observer?.resume(returning: false); observer = nil
        exitObserver?.resume(); exitObserver = nil; release()
    }
}

/// 每例自己的真实manager和随机.invalid host，仅会话内安装协议，不改变生产构造或全局URLSession。
@MainActor struct MetadataHTTPFixture {
    let endpoint: URL
    let manager: LibraryManagementController
    let script: MetadataHTTPScript

    /// exchanges是固定有限HTTP序列；真实客户端继续执行Bearer、JSON、状态与取消检查。
    init(exchanges: [MetadataExchange]) {
        endpoint = URL(string: "https://metadata-\(UUID().uuidString.lowercased()).invalid/api")!
        script = MetadataHTTPScript(exchanges)
        MetadataURLProtocol.install(script, endpoint: endpoint)
        manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MetadataURLProtocol.self]
            return configuration
        })
        manager.configure(session: metadataSession(endpoint: endpoint), endpoint: endpoint)
    }

    /// 先取消本会话，再移除私有host；清理不接触任何真实账号或其他并行测试。
    func close() {
        manager.configure(session: nil, endpoint: nil)
        MetadataURLProtocol.remove(endpoint: endpoint)
        Task { await script.stop() }
    }
}

/// request是实际PUT，expected为独立完整JSON；比较全部键和值，保证keep字段没有被悄悄写入。
private nonisolated func assertMetadataBody(_ request: MetadataRequest, expected: String) throws {
    #expect(request.method == "PUT" && request.contentType == "application/json")
    let body = try #require(request.body)
    let actual = try JSONSerialization.jsonObject(with: body)
    let expected = try JSONSerialization.jsonObject(with: Data(expected.utf8))
    let actualBytes = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
    let expectedBytes = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
    #expect(actualBytes == expectedBytes)
}

/// 本会话HTTP响应器；Mutex保护取消/任务安装竞争，未知host也被拦截，不回落真实网络。
private final nonisolated class MetadataURLProtocol: URLProtocol, @unchecked Sendable {
    /// 一个随机host的脚本与API根。
    private struct Entry: Sendable { let script: MetadataHTTPScript; let endpoint: URL }
    /// URLSession取消和异步响应任务的线程间同步状态。
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: Entry]>([:])
    private let loading = Mutex(Loading())

    /// script/endpoint只装入本类私有表，不使用进程全局URLProtocol注册。
    static func install(_ script: MetadataHTTPScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
    }

    /// 仅移除本测试endpoint，保留其他并行fixture。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 所有请求都由该协议接管，错误host必须失败。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留生产请求，不由fixture修正错误body或路径。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 捕获请求并异步回传固定响应；实际取消后不再交付字节，异常使真正URLSession失败。
    override func startLoading() {
        do {
            let capturedRequest = try MetadataRequest(request)
            guard let entry = Self.scripts.withLock({ $0[capturedRequest.url.host ?? ""] }) else { throw URLError(.badURL) }
            let task = Task { @Sendable [weak self, entry, capturedRequest] in
                defer { Task { @Sendable [script = entry.script, requestID = capturedRequest.id] in await script.responderExited(requestID) } }
                do {
                    let exchange = try await entry.script.response(capturedRequest, endpoint: entry.endpoint)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    guard let response = HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status, httpVersion: nil,
                                                         headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(exchange.json.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 取消真实在途响应任务；gate仍由测试释放，不能把迟到成功注入新账号。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}
