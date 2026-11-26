import Foundation
import Testing
@testable import Remmich

/// 真Store/manager/客户端经过会话内HTTP；两个方向独立响应，不能把单向授权或时间线偏好伪造成互相共享。
@Suite("Partner sharing contracts")
@MainActor struct PartnerSharingContractTests {
    /// 添加/停止本人共享与显示/隐藏incoming分别走官方POST/DELETE/PUT；写前后都读取两个方向。
    @Test(arguments: ["add", "remove", "show", "hide"])
    func confirmsExactlyOneDirectionAndOneWrite(_ kind: String) async throws {
        let incoming = partnerList(enabled: kind == "hide"); let outgoing = kind == "add" ? "[]" : partnerList()
        let afterIncoming = ["show", "hide"].contains(kind) ? partnerList(enabled: kind == "show") : incoming
        let afterOutgoing = kind == "remove" ? "[]" : partnerList()
        var sequence = partnerReads(incoming: incoming, outgoing: outgoing) + partnerDirections(incoming: incoming, outgoing: outgoing)
        if kind == "add" {
            sequence += [partnerUsers()]
        }
        sequence += [partnerWrite(kind)] + partnerDirections(incoming: afterIncoming, outgoing: afterOutgoing)
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        try #require(store.hasFreshData)
        let plan = try store.prepare(partnerCommand(kind), manager: fixture.manager)
        #expect(await fixture.script.requests().count == 3)
        let task = try #require(store.start(plan, manager: fixture.manager)); await task.value
        #expect(store.hasFreshData && store.notice != nil && store.error == nil && !store.isWorking && !fixture.manager.busy)
        #expect(fixture.manager.revision == 1)
        let snapshot = try #require(store.snapshot)
        let expectedIncoming = try JSONDecoder().decode([ManagedPartner].self, from: Data(afterIncoming.utf8))
        let expectedOutgoing = try JSONDecoder().decode([ManagedPartner].self, from: Data(afterOutgoing.utf8))
        #expect(snapshot.incoming == expectedIncoming && snapshot.outgoing == expectedOutgoing)
        #expect(fixture.manager.takePartnerTimelineRefreshRequest() == ["show", "hide"].contains(kind))
        #expect(!fixture.manager.takePartnerTimelineRefreshRequest())
        let requests = await fixture.script.requests(); try #require(requests.count == sequence.count)
        let write = try #require(requests.first { $0.method != "GET" })
        try assertPartnerBody(write, kind: kind)
        #expect(requests.filter { $0.method != "GET" }.count == 1 && store.start(plan, manager: fixture.manager) == nil)
    }

    /// 来向不能由本人撤销，去向不能由本人设置对方timeline；自选本人/已共享/不在当前用户列表或未知偏好均无写入口。
    @Test(arguments: ["remove-incoming", "timeline-outgoing", "self", "existing", "unknown-user", "unknown-timeline"])
    func refusesUnsupportedDirectionAndUnknownState(_ variant: String) async throws {
        let incoming = variant == "timeline-outgoing" ? "[]" : partnerList(enabled: variant == "unknown-timeline" ? nil : false)
        let outgoing = variant == "remove-incoming" ? "[]" : partnerList()
        let fixture = ChecksumLookupHTTPFixture(exchanges: partnerReads(incoming: incoming, outgoing: outgoing)); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        let command: PartnerSharingCommand = switch variant {
        case "remove-incoming": .remove(partnerID)
        case "timeline-outgoing", "unknown-timeline": .timeline(partnerID, true)
        case "self": .add(partnerCurrentID)
        case "existing": .add(partnerID)
        default: .add(partnerOtherID)
        }
        #expect(store.hasFreshData)
        #expect(throws: PartnerSharingError.self) { try store.prepare(command, manager: fixture.manager) }
        #expect(await fixture.script.requests().count == 3 && fixture.manager.revision == 0)
    }

    /// 确认后双向快照或现有用户候选变化即停止，不凭旧名称/旧方向向服务器发写。
    @Test(arguments: ["incoming", "outgoing", "candidate"])
    func changedPreflightCannotWrite(_ variant: String) async throws {
        let adding = variant == "candidate"
        let outgoing = adding ? "[]" : partnerList()
        var sequence = partnerReads(outgoing: outgoing) + partnerDirections(incoming: variant == "incoming" ? "[]" : partnerList(),
                                                                            outgoing: variant == "outgoing" ? "[]" : outgoing)
        if adding {
            sequence += [partnerUsers(json: "[]")]
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(adding ? .add(partnerID) : .remove(partnerID), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 0)
        #expect(await fixture.script.requests().allSatisfy { $0.method == "GET" })
    }

    /// 精确状态、目标UUID和timeline回执值均须正确；未知结果锁定到fresh重读，禁止同一计划自动再发。
    @Test(arguments: ["add-200", "remove-200", "show-201", "show-500", "wrong-id", "wrong-value"])
    func uncertainReceiptRequiresReload(_ variant: String) async throws {
        let kind = variant.hasPrefix("add") ? "add" : variant.hasPrefix("remove") ? "remove" : "show"
        let outgoing = kind == "add" ? "[]" : partnerList()
        var sequence = partnerReads(outgoing: outgoing) + partnerDirections(outgoing: outgoing)
        if kind == "add" {
            sequence += [partnerUsers()]
        }
        let standard = partnerWrite(kind)
        let status = Int(variant.split(separator: "-").last ?? "") ?? 200
        let json = variant == "wrong-id" ? partnerJSON(id: partnerOtherID, enabled: true) : variant == "wrong-value" ? partnerJSON() : standard.json
        sequence += [.init(method: standard.method, path: standard.path, status: status, json: json)]
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(partnerCommand(kind), manager: fixture.manager); await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 1)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        let requests = await fixture.script.requests(); #expect(requests.count == sequence.count && requests.filter { $0.method != "GET" }.count == 1)
    }

    /// PUT受理后仍需fresh双向列表；未变化、未知偏好、额外去向变动或拒绝读取都不能宣称保存已确认。
    @Test(arguments: ["unchanged", "unknown", "opposite-changed", "unavailable"])
    func requiresBothPostWriteDirections(_ variant: String) async throws {
        let first = partnerDirection(.incoming, variant == "unknown" ? partnerList(enabled: nil) : partnerList(enabled: variant != "unchanged"), status: variant == "unavailable" ? 403 : 200)
        let sequence = partnerReads() + partnerDirections() + [partnerWrite("show"), first]
            + (variant == "unavailable" ? [] : [partnerDirection(.outgoing, variant == "opposite-changed" ? "[]" : partnerList())])
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(.timeline(partnerID, true), manager: fixture.manager); await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 1)
        #expect(fixture.manager.takePartnerTimelineRefreshRequest())
    }

    /// 畸形UUID/重复用户/错误布尔拒绝整次读取；可省略的inTimeline则明确保留nil，而不是默认false。
    @Test(arguments: ["invalid-id", "duplicate", "invalid-boolean", "missing-boolean"])
    func preservesUnknownAndRejectsMalformedList(_ variant: String) async {
        let list = switch variant {
        case "invalid-id": "[\(partnerJSON(id: "invalid"))]"
        case "duplicate": "[\(partnerJSON()),\(partnerJSON())]"
        case "invalid-boolean": partnerList().replacingOccurrences(of: #""inTimeline":false"#, with: #""inTimeline":"false""#)
        default: partnerList(enabled: nil)
        }
        let exchanges = variant == "missing-boolean" ? partnerReads(incoming: list) : [partnerDirection(.incoming, list)]
        let fixture = ChecksumLookupHTTPFixture(exchanges: exchanges); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        #expect(store.hasFreshData == (variant == "missing-boolean"))
        if variant == "missing-boolean" {
            #expect(store.snapshot?.incoming.first?.inTimeline == nil)
        } else {
            #expect(store.snapshot == nil && store.error != nil)
        }
    }

    /// 两个预检GET、写、两个后读GET均在真实URLSession门暂停，再取消/退页/换号/换路由；无迟到发布或自动重发。
    @Test(.timeLimit(.minutes(1)), arguments: [3, 4, 5, 6, 7], ["cancel", "page", "account", "endpoint"])
    func retiresEveryInflightBoundary(_ heldIndex: Int, _ retirement: String) async throws {
        var sequence = partnerReads() + partnerDirections() + [partnerWrite("show")] + partnerDirections(incoming: partnerList(enabled: true))
        sequence[heldIndex].held = true
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = PartnerSharingStore(); await store.reload(manager: fixture.manager)?.value
        let plan = try store.prepare(.timeline(partnerID, true), manager: fixture.manager)
        let task = try #require(store.start(plan, manager: fixture.manager))
        let observer = Task { await task.value; await fixture.script.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld(), "Actual partner request must enter its gate")
                switch retirement {
                case "cancel": task.cancel()
                case "page": store.invalidate(manager: fixture.manager)
                case "account":
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint, user: partnerOtherID, token: "other"), endpoint: fixture.endpoint)
                    store.invalidate(manager: fixture.manager)
                default:
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint), endpoint: fixture.endpoint.appending(path: "new-route"))
                    store.invalidate(manager: fixture.manager)
                }
                await fixture.script.release(); await task.value; await fixture.script.waitForHeldResponderExit()
                #expect(!store.hasFreshData && store.notice == nil && !store.isWorking)
                let notifies = ["cancel", "page"].contains(retirement) && heldIndex >= 5
                #expect(fixture.manager.revision == (notifies ? 1 : 0))
                #expect(fixture.manager.takePartnerTimelineRefreshRequest() == notifies)
                #expect(await fixture.script.requests().count == heldIndex + 1)
            } onCancel: { Task { @MainActor in store.invalidate(manager: fixture.manager); await fixture.script.stop() } }
        } catch {
            store.invalidate(manager: fixture.manager); await fixture.script.stop(); await task.value; await observer.value; throw error
        }
        await observer.value; await fixture.script.stop()
    }
}

private nonisolated let partnerID = "22222222-2222-4222-8222-222222222222"
private nonisolated let partnerOtherID = "33333333-3333-4333-8333-333333333333"
private nonisolated let partnerCurrentID = "99999999-9999-4999-8999-999999999999"

/// 合成对方身份；enabled=nil表示当前官方可省略字段，不伪造false。无真实用户或邮箱。
private nonisolated func partnerJSON(id: String = partnerID, enabled: Bool? = false) -> String {
    let flag = enabled.map { #","inTimeline":\#($0 ? "true" : "false")"# } ?? ""
    return #"{"id":"\#(id)","name":"Synthetic partner"\#(flag)}"#
}

/// 单伙伴数组的显式响应，不由Store状态/命令生成下一步结果。
private nonisolated func partnerList(enabled: Bool? = false) -> String {
    "[\(partnerJSON(enabled: enabled))]"
}

/// direction是真实必需query；响应形状相同，测试必须依请求方向区别谁分享给谁。
private nonisolated func partnerDirection(_ direction: PartnerSharingDirection, _ json: String, status: Int = 200) -> ChecksumLookupExchange {
    .init(method: "GET", path: "partners", status: status, json: json, query: [.init(name: "direction", value: direction.rawValue)])
}

/// 两方向按实际Store顺序返回，仅隔离HTTP数据，不替代业务匹配或确认逻辑。
private nonisolated func partnerDirections(incoming: String = partnerList(), outgoing: String = partnerList()) -> [ChecksumLookupExchange] {
    [partnerDirection(.incoming, incoming), partnerDirection(.outgoing, outgoing)]
}

/// 用户候选只来自GET/users，默认含本人和现有对方；json可用于模拟确认后账户不再可选。
private nonisolated func partnerUsers(json: String? = nil) -> ChecksumLookupExchange {
    .init(method: "GET", path: "users", status: 200,
          json: json ?? #"[{"id":"\#(partnerCurrentID)","name":"Self"},{"id":"\#(partnerID)","name":"Synthetic partner"}]"#)
}

/// 完整页面读取包含双向列表和候选账户，方法均为只读GET。
private nonisolated func partnerReads(incoming: String = partnerList(), outgoing: String = partnerList()) -> [ChecksumLookupExchange] {
    partnerDirections(incoming: incoming, outgoing: outgoing) + [partnerUsers()]
}

/// 四个用户意图不引入双向分享/邀请API，timeline目标是incoming共享者。
private nonisolated func partnerCommand(_ kind: String) -> PartnerSharingCommand {
    switch kind { case "add": .add(partnerID); case "remove": .remove(partnerID); default: .timeline(partnerID, kind == "show") }
}

/// 独立声明官方响应状态及目标路径，非deprecated POST/:id；DELETE无回执正文。
private nonisolated func partnerWrite(_ kind: String) -> ChecksumLookupExchange {
    .init(method: kind == "add" ? "POST" : kind == "remove" ? "DELETE" : "PUT", path: kind == "add" ? "partners" : "partners/\(partnerID)",
          status: kind == "add" ? 201 : kind == "remove" ? 204 : 200, json: kind == "remove" ? "" : partnerJSON(enabled: kind == "show"))
}

/// 实际请求只允许对应单字段；不得添加邮件、方向、对方用户控制参数或额外共享选项。
private nonisolated func assertPartnerBody(_ request: ChecksumLookupRequest, kind: String) throws {
    if kind == "remove" {
        #expect(request.body == nil); return
    }
    let data = try #require(request.body); let decoded = try JSONSerialization.jsonObject(with: data)
    let object = try #require(decoded as? [String: Any]); #expect(object.count == 1)
    if kind == "add" {
        #expect(object["sharedWithId"] as? String == partnerID)
    } else {
        #expect(object["inTimeline"] as? Bool == (kind == "show"))
    }
    #expect(request.authorization == "Bearer checksum-owner" && request.cookie == nil)
}
