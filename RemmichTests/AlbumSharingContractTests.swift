import Foundation
import Testing
@testable import Remmich

/// 实际Store/manager/客户端的单成员合同；只复用私有URLSession字节来源，不替换权限政策或生成服务器成功状态。
@Suite("Album sharing member contracts")
@MainActor struct AlbumSharingContractTests {
    /// editor和第二位owner均可按真实角色管理；每次必须读取→确认→fresh预检→写→fresh确认，原响应无需ownerId。
    @Test(arguments: ["add", "role", "remove"], ["editor", "owner"])
    func confirmsOneMemberUsingFreshServerRoles(_ kind: String, _ currentRole: String) async throws {
        let baseline = try sharingAlbumJSON(currentRole: currentRole)
        let next = try sharingAlbumJSON(currentRole: currentRole, added: kind == "add", targetRole: kind == "role" ? "editor" : "viewer", includeTarget: kind != "remove")
        let command = sharingCommand(kind)
        let write = sharingWrite(kind, json: kind == "add" ? next : "")
        let fixture = ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline) + [sharingDetail(baseline), write, sharingDetail(next)])
        defer { fixture.close() }
        let store = AlbumSharingStore()
        await store.reload(manager: fixture.manager)?.value
        #expect(store.hasFreshData && store.snapshot?.albumUsers.count == 3)
        let plan = try store.prepare(command, manager: fixture.manager)
        let task = try #require(store.start(plan, manager: fixture.manager)); await task.value
        #expect(store.hasFreshData && !store.isWorking && store.error == nil && store.notice != nil && fixture.manager.revision == 1)
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.confirms(command, from: plan.baseline))
        let requests = await fixture.script.requests()
        try #require(requests.count == 6)
        try assertSharingBody(requests[4], kind: kind)
        #expect(requests[3].method == "GET" && requests[5].method == "GET")
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 6)
    }

    /// viewer可退出本人但不读取全用户清单；204后必须fresh列表不含相簿，详情403不能冒充成功。
    @Test(arguments: [false, true])
    func viewerLeavesUsingItsExplicitUUID(_ remainsVisible: Bool) async throws {
        let baseline = try sharingAlbumJSON(currentRole: "viewer")
        let fixture = ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline, candidates: false) + [sharingDetail(baseline),
                                                                                                        .init(method: "DELETE", path: "albums/\(sharingAlbumID)/user/\(sharingCurrentID)", status: 204, json: ""),
                                                                                                        .init(method: "GET", path: "albums", status: 200, json: remainsVisible ? "[\(baseline)]" : "[]")])
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        #expect(throws: AlbumSharingError.self) { try store.prepare(.remove(id: sharingTargetID), manager: fixture.manager) }
        let plan = try store.prepare(.remove(id: sharingCurrentID), manager: fixture.manager)
        let task = try #require(store.start(plan, manager: fixture.manager)); await task.value
        #expect(!store.hasFreshData && fixture.manager.revision == 1)
        #expect(remainsVisible ? store.error != nil : store.notice != nil && store.snapshot == nil)
        let requests = await fixture.script.requests()
        #expect(requests.count == 5 && requests.allSatisfy { !$0.url.path.contains("/users") && !$0.url.path.hasSuffix("/me") })
    }

    /// 多owner按每个成员角色判断；首位角色不可改、最后owner不可移除，未知角色整体只读。
    @Test(arguments: ["editor", "owner", "viewer", "future-role"])
    func followsCompleteMembershipInsteadOfScalarOwner(_ role: String) throws {
        let snapshot = try JSONDecoder().decode(AlbumSharingSnapshot.self, from: Data(sharingAlbumJSON(currentRole: role).utf8))
        #expect(snapshot.canManage(sharingCurrentID) == ["editor", "owner"].contains(role))
        #expect(throws: AlbumSharingError.self) { try snapshot.require(.role(id: sharingFirstOwnerID, role: .viewer), userID: sharingCurrentID, users: []) }
        if role == "owner" {
            try snapshot.require(.remove(id: sharingFirstOwnerID), userID: sharingCurrentID, users: [])
            try snapshot.require(.remove(id: sharingCurrentID), userID: sharingCurrentID, users: [])
        } else {
            #expect(throws: AlbumSharingError.self) { try snapshot.require(.remove(id: sharingFirstOwnerID), userID: sharingCurrentID, users: []) }
        }
        if role == "future-role" {
            #expect(throws: AlbumSharingError.self) { try snapshot.require(.remove(id: sharingCurrentID), userID: sharingCurrentID, users: []) }
        }
    }

    /// 唯一owner本人也不可退出；可见多owner不能错误退化为只认首位owner的权限。
    @Test func lastOwnerCannotLeaveOrChangeItsProtectedRole() throws {
        let json = "{\"id\":\"\(sharingAlbumID)\",\"albumName\":\"Synthetic\",\"albumUsers\":[{\"user\":{\"id\":\"\(sharingCurrentID)\",\"name\":\"Only owner\"},\"role\":\"owner\"}]}"
        let snapshot = try JSONDecoder().decode(AlbumSharingSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.canManage(sharingCurrentID))
        #expect(throws: AlbumSharingError.self) { try snapshot.require(.remove(id: sharingCurrentID), userID: sharingCurrentID, users: []) }
        #expect(throws: AlbumSharingError.self) { try snapshot.require(.role(id: sharingCurrentID, role: .viewer), userID: sharingCurrentID, users: []) }
    }

    /// 缺失/重复/损坏成员在真实GET解码处失败，不能以空成员或ownerId回退开放共享写入。
    @Test(arguments: ["missing", "empty", "duplicate", "invalid-id", "no-owner"])
    func malformedMembershipNeverBecomesWritable(_ scenario: String) async throws {
        let baseline = try sharingAlbumJSON()
        let bytes = Data(baseline.utf8)
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        var object = try #require(decoded as? [String: Any])
        var members = try #require(object["albumUsers"] as? [[String: Any]])
        switch scenario {
        case "missing": object.removeValue(forKey: "albumUsers")
        case "empty": object["albumUsers"] = []
        case "duplicate": members.append(members[0]); object["albumUsers"] = members
        case "invalid-id": members[0]["user"] = ["id": "invalid", "name": "Synthetic"]; object["albumUsers"] = members
        default: members[0]["role"] = "editor"; object["albumUsers"] = members
        }
        let invalid = try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: "GET", path: "albums", status: 200, json: "[\(invalid)]")])
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.snapshot == nil && store.error != nil)
        #expect(await fixture.script.requests().count == 1)
    }

    /// 未知未来角色保留原文供只读显示，既不读取用户候选，也不能自行退出或产生确认计划。
    @Test func unknownRoleStaysReadOnlyThroughActualStore() async throws {
        let baseline = try sharingAlbumJSON(currentRole: "future-role")
        let fixture = ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline, candidates: false))
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        #expect(store.hasFreshData && store.snapshot?.roles[sharingCurrentID] == "future-role" && store.notice != nil)
        #expect(throws: AlbumSharingError.self) { try store.prepare(.remove(id: sharingCurrentID), manager: fixture.manager) }
        #expect(await fixture.script.requests().count == 2)
    }

    /// 确认期间目标/本人权限改变使预检失败；只读到变化，不发送写入，也不自动再取确认计划。
    @Test(arguments: ["viewer", "owner"])
    func rejectsChangedMembershipBeforeWriting(_ changedRole: String) async throws {
        let baseline = try sharingAlbumJSON()
        let changed = try sharingAlbumJSON(currentRole: changedRole)
        let fixture = ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline) + [sharingDetail(changed)])
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(.remove(id: sharingTargetID), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && fixture.manager.revision == 0)
        #expect(await fixture.script.requests().count == 4)
        #expect(throws: AlbumSharingError.self) { try store.prepare(.remove(id: sharingTargetID), manager: fixture.manager) }
    }

    /// 添加200、角色/移除204都是精确合同；错误2xx与服务错误只要求重载，不自动重发或宣称成功。
    @Test(arguments: ["add-201", "add-204", "role-200", "remove-200", "add-500"])
    func uncertainWriteRequiresExplicitReload(_ scenario: String) async throws {
        let parts = scenario.split(separator: "-"); let kind = String(parts[0]); let status = try #require(Int(parts[1]))
        let baseline = try sharingAlbumJSON()
        var write = try sharingWrite(kind, json: kind == "add" && status != 204 ? sharingAlbumJSON(added: true) : "")
        write = .init(method: write.method, path: write.path, status: status, json: write.json)
        let fixture = ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline) + [sharingDetail(baseline), write])
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(sharingCommand(kind), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 1)
        #expect(await fixture.script.requests().count == 5)
        #expect(store.start(plan, manager: fixture.manager) == nil)
    }

    /// 精确写回执仍不能替代后置读取；未改变/额外成员变动或fresh失败一律保持未确认。
    @Test(arguments: ["unchanged", "extra-change", "read-failed"])
    func requiresTheActualPostWriteState(_ scenario: String) async throws {
        let baseline = try sharingAlbumJSON()
        let after = scenario == "extra-change" ? try sharingAlbumJSON(added: true, targetRole: "editor") : baseline
        let fixture = try ChecksumLookupHTTPFixture(exchanges: sharingReads(baseline) + [sharingDetail(baseline),
                                                                                         sharingWrite("add", json: sharingAlbumJSON(added: true)),
                                                                                         .init(method: "GET", path: "albums/\(sharingAlbumID)", status: scenario == "read-failed" ? 503 : 200, json: after)])
        defer { fixture.close() }
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(.add(id: sharingNewID, role: .viewer), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 1)
        #expect(await fixture.script.requests().count == 6)
    }

    /// 预检、写入、写后读取的真正URLSession挂起点退休；晚响应不能开写或发布成功，取消清理有明确握手。
    @Test(.timeLimit(.minutes(1)), arguments: ["preflight", "write", "confirm"], ["cancel", "page", "account", "endpoint"])
    func retiresActualRequestsWithoutAutomaticReplay(_ stage: String, _ retirement: String) async throws {
        let baseline = try sharingAlbumJSON(); let after = try sharingAlbumJSON(added: true)
        var sequence = sharingReads(baseline) + [sharingDetail(baseline), sharingWrite("add", json: after), sharingDetail(after)]
        let heldIndex = stage == "preflight" ? 3 : stage == "write" ? 4 : 5; sequence[heldIndex].held = true
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence)
        let store = AlbumSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(.add(id: sharingNewID, role: .viewer), manager: fixture.manager)
        let task = try #require(store.start(plan, manager: fixture.manager))
        let observer = Task { await task.value; await fixture.script.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld(), "Actual sharing request must enter its gate")
                switch retirement {
                case "cancel": task.cancel()
                case "page": store.invalidate(manager: fixture.manager)
                case "account":
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint, user: sharingNewID, token: "other"), endpoint: fixture.endpoint)
                    store.invalidate(manager: fixture.manager)
                default:
                    let endpoint = fixture.endpoint.appending(path: "route")
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint), endpoint: endpoint)
                    store.invalidate(manager: fixture.manager)
                }
                await fixture.script.release(); await task.value; await fixture.script.waitForHeldResponderExit()
                #expect(!store.hasFreshData && store.notice == nil && !store.isWorking)
                #expect(fixture.manager.revision == (["cancel", "page"].contains(retirement) && stage != "preflight" ? 1 : 0))
                #expect(await fixture.script.requests().count == heldIndex + 1)
            } onCancel: { Task { @MainActor in store.invalidate(manager: fixture.manager); await fixture.script.stop() } }
        } catch {
            store.invalidate(manager: fixture.manager); await fixture.script.stop(); await task.value
            await observer.value; fixture.close(); throw error
        }
        await observer.value; await fixture.script.stop(); fixture.close()
    }
}

private nonisolated let sharingAlbumID = "44444444-4444-4444-8444-444444444444"
private nonisolated let sharingCurrentID = "99999999-9999-4999-8999-999999999999"
private nonisolated let sharingFirstOwnerID = "11111111-1111-4111-8111-111111111111"
private nonisolated let sharingTargetID = "22222222-2222-4222-8222-222222222222"
private nonisolated let sharingNewID = "33333333-3333-4333-8333-333333333333"

/// 独立指定的完整官方成员JSON，无ownerId；默认当前用户为editor，显式保留首owner和已有viewer。
private nonisolated func sharingAlbumJSON(currentRole: String = "editor", added: Bool = false, targetRole: String = "viewer", includeTarget: Bool = true) throws -> String {
    var members: [[String: Any]] = [
        ["user": ["id": sharingFirstOwnerID, "name": "First owner"], "role": "owner"],
        ["user": ["id": sharingCurrentID, "name": "Current"], "role": currentRole],
    ]
    if includeTarget {
        members.append(["user": ["id": sharingTargetID, "name": "Existing"], "role": targetRole])
    }
    if added {
        members.append(["user": ["id": sharingNewID, "name": "Candidate"], "role": "viewer"])
    }
    return try String(decoding: JSONSerialization.data(withJSONObject: ["id": sharingAlbumID, "albumName": "Synthetic", "albumUsers": members], options: [.sortedKeys]), as: UTF8.self)
}

/// 输入完整详情字节，返回明确GET200，不从Store状态生成响应。
private nonisolated func sharingDetail(_ json: String) -> ChecksumLookupExchange {
    .init(method: "GET", path: "albums/\(sharingAlbumID)", status: 200, json: json)
}

/// fresh列表/详情加可选已有用户清单；viewer/未知角色不发GET/users。
private nonisolated func sharingReads(_ album: String, candidates: Bool = true) -> [ChecksumLookupExchange] {
    var values: [ChecksumLookupExchange] = [.init(method: "GET", path: "albums", status: 200, json: "[\(album)]"), sharingDetail(album)]
    if candidates {
        values.append(.init(method: "GET", path: "users", status: 200, json: "[{\"id\":\"\(sharingNewID)\",\"name\":\"Candidate\"}]"))
    }
    return values
}

/// kind选择独立固定意图；所有目标是UUID，不把email、me或数组索引传给服务端。
private nonisolated func sharingCommand(_ kind: String) -> AlbumSharingCommand {
    switch kind { case "add": .add(id: sharingNewID, role: .viewer); case "role": .role(id: sharingTargetID, role: .editor); default: .remove(id: sharingTargetID) }
}

/// kind固定官方真实方法/状态；json仅为添加200返回的完整相簿，204保持空body。
private nonisolated func sharingWrite(_ kind: String, json: String) -> ChecksumLookupExchange {
    .init(method: kind == "remove" ? "DELETE" : "PUT", path: kind == "add" ? "albums/\(sharingAlbumID)/users" : "albums/\(sharingAlbumID)/user/\(sharingTargetID)",
          status: kind == "add" ? 200 : 204, json: json)
}

/// 对实际写请求全文比较JSON，添加必须恰一个userId+role，移除不能附body；不允许接受额外字段碰巧成功。
private nonisolated func assertSharingBody(_ request: ChecksumLookupRequest, kind: String) throws {
    if kind == "remove" {
        #expect(request.body == nil); return
    }
    let bytes = try #require(request.body)
    let object = try JSONSerialization.jsonObject(with: bytes)
    let expected: [String: Any] = kind == "add" ? ["albumUsers": [["userId": sharingNewID, "role": "viewer"]]] : ["role": "editor"]
    #expect(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
}
