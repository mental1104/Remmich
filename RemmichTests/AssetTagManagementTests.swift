import Foundation
import Testing
@testable import Remmich

/// 原生标签真实Store/manager/client/URLSession验证；复用会话内HTTP夹具，响应/预期body均独立声明。
@Suite("Asset tag management")
struct AssetTagManagementTests {
    /// kind覆盖根/子创建、祖先/叶改名、级联删除及单资源加减关系，所有请求精确到原生路由与完整body。
    @Test(arguments: ["create-root", "create-child", "rename-root", "rename-child", "delete", "attach", "detach"])
    @MainActor func nativeCommandsConfirmTheirActualEffects(_ kind: String) async throws {
        let change = tagChange(kind)
        let exchanges = tagReads() + tagReads() + [change.exchange] + tagReads(tags: change.tags, attached: change.attached)
        let fixture = MetadataHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let baseline = try #require(store.state)
        #expect(baseline.subtree(tagRootID) == Set([tagRootID, tagChildID]))
        let plan = try store.prepare(change.command, manager: fixture.manager)
        let optionalTask = store.start(plan, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(store.hasFreshData && !store.isWorking && !fixture.manager.busy && store.error == nil && store.notice != nil)
        #expect(store.confirmedChanges == 1 && store.savedAccountGeneration == fixture.manager.generation && fixture.manager.revision == 1)
        #expect(store.state?.asset.livePhotoVideoId == tagPartnerID)
        #expect(Set(store.state?.asset.tags.map(\.id) ?? []) == Set(change.attachedIDs))
        let requests = await fixture.script.requests()
        try #require(requests.count == 7)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "GET", change.exchange.method, "GET", "GET"])
        try assertTagBody(requests[4], expected: change.body)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 7)
    }

    /// 非成功成员、未知结果、错误身份/重复回执和错误成功码不能显示保存，明确错误不会变成重试。
    @Test(arguments: ["duplicate", "no_permission", "not_found", "validation", "unknown", "wrong-id", "duplicate-results", "empty-results", "contradictory", "false-no-reason", "201", "403", "503"])
    @MainActor func refusesUnconfirmedRelationshipWrites(_ variant: String) async throws {
        let known = ["duplicate", "no_permission", "not_found", "validation", "unknown"].contains(variant)
        let success = #"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":true}"#
        let json: String = switch variant {
        case "wrong-id": #"[{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","success":true}]"#
        case "duplicate-results": "[" + success + "," + success + "]"
        case "empty-results": "[]"
        case "contradictory": #"[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":true,"error":"duplicate"}]"#
        case "false-no-reason": #"[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":false}]"#
        default: known ? #"[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":false,"error":"\#(variant)"}]"# : "[" + success + "]"
        }
        let fixture = MetadataHTTPFixture(exchanges: tagReads() + tagReads() + [.init(method: "PUT", path: "tags/\(tagRootID)/assets", status: Int(variant) ?? 200, json: json)])
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let plan = try store.prepare(.attach(tagID: tagRootID), manager: fixture.manager)
        let optionalTask = store.start(plan, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(!store.hasFreshData && !store.isWorking && !fixture.manager.busy && store.notice == nil && store.error != nil)
        #expect(store.confirmedChanges == 0)
        #expect(fixture.manager.revision == (["duplicate", "no_permission", "not_found", "validation", "403"].contains(variant) ? 0 : 1))
        #expect(store.start(plan, manager: fixture.manager) == nil)
        let requests = await fixture.script.requests()
        #expect(requests.count == 5)
        try assertTagBody(#require(requests.last), expected: #"{"ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]}"#)
    }

    /// 树写入也逐一要求原生成功码及正确路径/父ID/身份，不因请求发出就显示创建/改名/删除成功。
    @Test(arguments: ["create-200", "create-parent", "create-path", "rename-201", "rename-id", "rename-path", "delete-200"])
    @MainActor func refusesUnconfirmedTreeWrites(_ variant: String) async throws {
        let kind = variant.hasPrefix("create") ? "create-root" : variant.hasPrefix("rename") ? "rename-root" : "delete"
        let change = tagChange(kind)
        let json: String = switch variant {
        case "create-parent": tagNew(parent: tagRootID)
        case "create-path": tagJSON(id: tagNewID, name: "Fresh", value: "Different/Fresh")
        case "rename-id": tagRoot("Renamed").replacingOccurrences(of: tagRootID, with: tagNewID)
        case "rename-path": tagJSON(id: tagRootID, name: "Renamed", value: "Different/Renamed")
        default: change.exchange.json
        }
        let status = variant == "create-200" || variant == "delete-200" ? 200 : variant == "rename-201" ? 201 : change.exchange.status
        let exchange = MetadataExchange(method: change.exchange.method, path: change.exchange.path, status: status, json: json)
        let fixture = MetadataHTTPFixture(exchanges: tagReads() + tagReads() + [exchange])
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let plan = try store.prepare(change.command, manager: fixture.manager)
        let optionalTask = store.start(plan, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(!store.hasFreshData && !store.isWorking && store.notice == nil && store.error != nil && store.confirmedChanges == 0)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        let requests = await fixture.script.requests()
        #expect(requests.count == 5)
        try assertTagBody(#require(requests.last), expected: change.body)
    }

    /// 标签缺字段/null、树身份重复、错误UUID/资源和HTTP拒绝不能伪装成空列表授权删除/创建。
    @Test(arguments: ["missing-tags", "null-tags", "wrong-asset", "foreign-relation", "duplicate-catalog", "v5-tag", "201", "403", "404"])
    @MainActor func rejectsInvalidFreshState(_ variant: String) async throws {
        var catalog = tagCatalog()
        if variant == "duplicate-catalog" {
            catalog = "[" + tagRoot() + "," + tagRoot() + "]"
        }
        if variant == "v5-tag" {
            catalog = "[" + tagRoot().replacingOccurrences(of: tagRootID, with: "55555555-5555-5555-8555-555555555555") + "]"
        }
        var asset = tagAsset()
        if variant == "missing-tags" {
            asset = tagAsset(tags: nil)
        }
        if variant == "null-tags" {
            asset = tagAsset(tags: "null")
        }
        if variant == "wrong-asset" {
            asset = tagAsset(id: tagOtherAssetID)
        }
        if variant == "foreign-relation" {
            asset = tagAsset(tags: "[" + tagNew() + "]")
        }
        let readsAsset = !["duplicate-catalog", "v5-tag", "201", "403", "404"].contains(variant)
        let fixture = MetadataHTTPFixture(exchanges: [.init(method: "GET", path: "tags", status: Int(variant) ?? 200, json: catalog)]
            + (readsAsset ? [.init(method: "GET", path: "assets/\(tagAssetID)", status: 200, json: asset)] : []))
        defer { fixture.close() }
        let store = AssetTagStore()
        let optionalTask = store.reload(assetID: tagAssetID, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(!store.hasFreshData && store.state == nil && store.error != nil && !store.isLoading)
        #expect(throws: AssetTagError.self) { try store.prepare(.delete(tagID: tagRootID), manager: fixture.manager) }
        #expect(fixture.manager.revision == 0)
        #expect(await fixture.script.requests().count == (readsAsset ? 2 : 1))
    }

    /// tree/asset任一在审阅后变化都要重新确认，不能把列表展示与服务器可写状态混为一谈。
    @Test(arguments: ["tree", "asset", "shared", "trash"])
    @MainActor func preflightAndPermissionPreventWrites(_ variant: String) async throws {
        let changedTree = "[" + tagRoot() + "," + tagChild(value: "Root/Changed", name: "Changed") + "]"
        let after = variant == "tree" ? tagReads(tags: changedTree, attached: "[" + tagChild(value: "Root/Changed", name: "Changed") + "]")
            : tagReads(attached: variant == "asset" ? "[]" : "[" + tagChild() + "]", owner: variant == "shared" ? tagOtherOwner : tagOwner, trashed: variant == "trash")
        let fixture = MetadataHTTPFixture(exchanges: tagReads() + after)
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let plan = try store.prepare(.delete(tagID: tagRootID), manager: fixture.manager)
        let optionalTask = store.start(plan, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && store.confirmedChanges == 0 && fixture.manager.revision == 0)
        #expect(await fixture.script.requests().map(\.method) == ["GET", "GET", "GET", "GET"])
    }

    /// 写响应成功后读失败仍保留保存回执，不能把失败加载当可继续使用的fresh树。
    @Test @MainActor func confirmedWriteWithFailedReadbackRequiresReload() async throws {
        let change = tagChange("rename-root")
        let fixture = MetadataHTTPFixture(exchanges: tagReads() + tagReads() + [change.exchange, .init(method: "GET", path: "tags", status: 503, json: "{}")])
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let plan = try store.prepare(change.command, manager: fixture.manager)
        let optionalTask = store.start(plan, manager: fixture.manager)
        let operation = try #require(optionalTask)
        await operation.value
        #expect(store.notice != nil && store.error != nil && !store.hasFreshData && !store.isWorking && store.confirmedChanges == 1)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        #expect(await fixture.script.requests().count == 6)
    }

    /// stage分别卡住预检、PUT、已确认后的回读；失败也唤醒门，取消不伪造回滚或自动重发。
    @Test(.timeLimit(.minutes(1)), arguments: ["preflight", "write", "readback"])
    @MainActor func cancellationKeepsTheRealWriteBoundary(_ stage: String) async throws {
        let change = tagChange("attach")
        var exchanges = tagReads()
        if stage == "preflight" {
            exchanges.append(.init(method: "GET", path: "tags", status: 200, json: tagCatalog(), held: true))
        } else {
            exchanges += tagReads()
            var write = change.exchange; write.held = stage == "write"; exchanges.append(write)
            if stage == "readback" {
                exchanges.append(.init(method: "GET", path: "tags", status: 200, json: change.tags, held: true))
            }
        }
        let fixture = MetadataHTTPFixture(exchanges: exchanges)
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetTagStore()
            try await loadTags(store, fixture: fixture)
            let plan = try store.prepare(change.command, manager: fixture.manager)
            let optionalTask = store.start(plan, manager: fixture.manager)
            let operation = try #require(optionalTask)
            let completion = Task { await operation.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            store.cancel(); await fixture.script.release(); await completion.value
            await fixture.script.waitForHeldResponderExit()
            #expect(!store.hasFreshData && !store.isWorking && store.error != nil && !fixture.manager.busy)
            #expect((store.notice != nil) == (stage == "readback"))
            #expect(store.confirmedChanges == (stage == "readback" ? 1 : 0))
            #expect(fixture.manager.revision == (stage == "preflight" ? 0 : 1))
            #expect(await fixture.script.requests().count == exchanges.count)
        } onCancel: { Task { @MainActor in fixture.close() } }
    }

    /// context区分账号/端点；旧PUT返回或旧确认不能覆盖新读取，也不能增加新账号revision。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint"])
    @MainActor func oldAccountCannotPublishTags(_ context: String) async throws {
        var write = tagChange("attach").exchange; write.held = true
        let nextOwner = context == "account" ? tagOtherOwner : tagOwner
        let prefix = context == "endpoint" ? "fallback/" : ""
        let authorization = context == "account" ? "Bearer metadata-next" : "Bearer metadata-owner"
        let fixture = MetadataHTTPFixture(exchanges: tagReads() + tagReads() + [write,
                                                                                .init(method: "GET", path: prefix + "tags", status: 200, json: "[" + tagNew() + "]", authorization: authorization),
                                                                                .init(method: "GET", path: prefix + "assets/\(tagOtherAssetID)", status: 200,
                                                                                      json: tagAsset(id: tagOtherAssetID, owner: nextOwner, tags: "[" + tagNew() + "]"), authorization: authorization)])
        defer { fixture.close() }
        try await withTaskCancellationHandler {
            let store = AssetTagStore()
            try await loadTags(store, fixture: fixture)
            let old = try store.prepare(.attach(tagID: tagRootID), manager: fixture.manager)
            let optionalTask = store.start(old, manager: fixture.manager)
            let operation = try #require(optionalTask)
            let completion = Task { await operation.value; await fixture.script.operationFinished() }
            #expect(await fixture.script.waitForHeld())
            let endpoint = context == "endpoint" ? fixture.endpoint.appending(path: "fallback") : fixture.endpoint
            fixture.manager.configure(session: tagSession(endpoint: endpoint, user: nextOwner, token: context == "account" ? "metadata-next" : "metadata-owner"), endpoint: endpoint)
            #expect(throws: AssetTagError.self) { try store.prepare(.detach(tagID: tagChildID), manager: fixture.manager) }
            store.invalidate(manager: fixture.manager)
            let optionalRead = store.reload(assetID: tagOtherAssetID, manager: fixture.manager)
            let read = try #require(optionalRead)
            await read.value
            #expect(store.state?.asset.id == tagOtherAssetID && store.hasFreshData)
            #expect(store.start(old, manager: fixture.manager) == nil)
            await fixture.script.release(); await completion.value
            await fixture.script.waitForHeldResponderExit()
            #expect(store.state?.asset.id == tagOtherAssetID && store.state?.tags.map(\.id) == [tagNewID] && store.hasFreshData)
            #expect(store.notice == nil && store.confirmedChanges == 0 && fixture.manager.revision == 0 && !fixture.manager.busy)
            #expect(await fixture.script.requests().count == 7)
        } onCancel: { Task { @MainActor in fixture.close() } }
    }

    /// 无效叶名/未知父级/不变关系在HTTP前拒绝；保持颜色、父级和其他照片关系不在请求体中。
    @Test @MainActor func invalidOrUnchangedCommandsNeverWrite() async throws {
        let fixture = MetadataHTTPFixture(exchanges: tagReads())
        defer { fixture.close() }
        let store = AssetTagStore()
        try await loadTags(store, fixture: fixture)
        let commands: [AssetTagCommand] = [.create(name: " ", parentID: nil), .create(name: "A/B", parentID: nil),
                                           .create(name: "Root", parentID: nil), .create(name: "New", parentID: tagNewID),
                                           .rename(tagID: tagRootID, name: "Root"), .rename(tagID: tagRootID, name: "A/B"),
                                           .delete(tagID: tagNewID), .attach(tagID: tagChildID), .detach(tagID: tagRootID)]
        for command in commands {
            #expect(throws: AssetTagError.self) { try store.prepare(command, manager: fixture.manager) }
        }
        #expect(await fixture.script.requests().count == 2)
        #expect(fixture.manager.revision == 0 && !fixture.manager.busy)
    }
}

/// 所有资源、标签、身份、文件名和颜色都为固定合成数据，不读取私人媒体/标签/凭据。
private nonisolated let tagAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let tagOtherAssetID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let tagOwner = "11111111-1111-4111-8111-111111111111"
private nonisolated let tagOtherOwner = "22222222-2222-4222-8222-222222222222"
private nonisolated let tagPartnerID = "44444444-4444-4444-8444-444444444444"
private nonisolated let tagRootID = "55555555-5555-4555-8555-555555555555"
private nonisolated let tagChildID = "66666666-6666-4666-8666-666666666666"
private nonisolated let tagNewID = "77777777-7777-4777-8777-777777777777"

/// id/name/value/parent是独立响应声明，parent缺省时省略；不使用生产DTO编码作为预期答案。
private nonisolated func tagJSON(id: String, name: String, value: String, parent: String? = nil) -> String {
    let parentField = parent.map { #", "parentId":"\#($0)""# } ?? ""
    return ##"{"id":"\##(id)","name":"\##(name)","value":"\##(value)","createdAt":"2026-11-24T00:00:00Z","updatedAt":"2026-11-24T00:00:00Z","color":"#aabbcc"\##(parentField)}"##
}

/// name默认根叶名，返回独立根标签响应，可用于构造改名前后树。
private nonisolated func tagRoot(_ name: String = "Root") -> String {
    tagJSON(id: tagRootID, name: name, value: name)
}

/// value/name独立指定，以捕获客户端仅改叶名或遗漏后代路径的错误。
private nonisolated func tagChild(value: String = "Root/Child", name: String = "Child") -> String {
    tagJSON(id: tagChildID, name: name, value: value, parent: tagRootID)
}

/// parent确定根/子创建的真实回执；固定新ID与请求标签ID不同。
private nonisolated func tagNew(parent: String? = nil) -> String {
    tagJSON(id: tagNewID, name: "Fresh", value: parent == nil ? "Fresh" : "Root/Fresh", parent: parent)
}

/// 返回合成完整个人树，不由Store当前选择产生数据。
private nonisolated func tagCatalog() -> String {
    "[" + tagRoot() + "," + tagChild() + "]"
}

/// tags为独立JSON数组/明确null，nil省略字段以检测缺失；id/owner/trashed模拟真实权限边界。
private nonisolated func tagAsset(id: String = tagAssetID, owner: String = tagOwner, tags: String? = "[" + tagChild() + "]", trashed: Bool = false) -> String {
    let tagsField = tags.map { #", "tags":\#($0)"# } ?? ""
    return #"{"id":"\#(id)","ownerId":"\#(owner)","type":"IMAGE","isTrashed":\#(trashed),"livePhotoVideoId":"\#(tagPartnerID)"\#(tagsField)}"#
}

/// tags/attached为当前真实响应，owner/trashed用于写前权限变化；每次两个独立GET。
private nonisolated func tagReads(tags: String = tagCatalog(), attached: String = "[" + tagChild() + "]", owner: String = tagOwner, trashed: Bool = false) -> [MetadataExchange] {
    [.init(method: "GET", path: "tags", status: 200, json: tags), .init(method: "GET", path: "assets/\(tagAssetID)", status: 200,
                                                                        json: tagAsset(owner: owner, tags: attached, trashed: trashed))]
}

/// 独立声明命令/响应/body/回读与ID集合，避免调用生产编码器或确认器来生成测试预期。
private nonisolated struct TagChange {
    let command: AssetTagCommand
    let exchange: MetadataExchange
    let body: String?
    let tags: String
    let attached: String
    let attachedIDs: [String]
}

/// kind选择有限真实用例；默认分支仅为已列出的detach，不按生产状态自动修正错误响应。
private nonisolated func tagChange(_ kind: String) -> TagChange {
    switch kind {
    case "create-root", "create-child":
        let child = kind == "create-child"
        let tag = tagNew(parent: child ? tagRootID : nil)
        return .init(command: .create(name: " Fresh ", parentID: child ? tagRootID : nil), exchange: .init(method: "POST", path: "tags", status: 201, json: tag),
                     body: child ? #"{"name":"Fresh","parentId":"55555555-5555-4555-8555-555555555555"}"# : #"{"name":"Fresh"}"#,
                     tags: "[" + tagRoot() + "," + tagChild() + "," + tag + "]", attached: "[" + tagChild() + "]", attachedIDs: [tagChildID])
    case "rename-root":
        let child = tagChild(value: "Renamed/Child")
        return .init(command: .rename(tagID: tagRootID, name: "Renamed"), exchange: .init(method: "PUT", path: "tags/\(tagRootID)", status: 200, json: tagRoot("Renamed")),
                     body: #"{"name":"Renamed"}"#, tags: "[" + tagRoot("Renamed") + "," + child + "]", attached: "[" + child + "]", attachedIDs: [tagChildID])
    case "rename-child":
        let child = tagChild(value: "Root/Renamed", name: "Renamed")
        return .init(command: .rename(tagID: tagChildID, name: "Renamed"), exchange: .init(method: "PUT", path: "tags/\(tagChildID)", status: 200, json: child),
                     body: #"{"name":"Renamed"}"#, tags: "[" + tagRoot() + "," + child + "]", attached: "[" + child + "]", attachedIDs: [tagChildID])
    case "delete": return .init(command: .delete(tagID: tagRootID), exchange: .init(method: "DELETE", path: "tags/\(tagRootID)", status: 204, json: ""), body: nil, tags: "[]", attached: "[]", attachedIDs: [])
    case "attach": return .init(command: .attach(tagID: tagRootID), exchange: .init(method: "PUT", path: "tags/\(tagRootID)/assets", status: 200,
                                                                                    json: #"[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":true}]"#),
                                body: #"{"ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]}"#, tags: tagCatalog(), attached: "[" + tagRoot() + "," + tagChild() + "]", attachedIDs: [tagRootID, tagChildID])
    default: return .init(command: .detach(tagID: tagChildID), exchange: .init(method: "DELETE", path: "tags/\(tagChildID)/assets", status: 200,
                                                                               json: #"[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","success":true}]"#),
                          body: #"{"ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]}"#, tags: tagCatalog(), attached: "[]", attachedIDs: [])
    }
}

/// store通过真实reload准备；只等待实际任务，不手工注入可写状态。
@MainActor private func loadTags(_ store: AssetTagStore, fixture: MetadataHTTPFixture) async throws {
    let optionalTask = store.reload(assetID: tagAssetID, manager: fixture.manager)
    let operation = try #require(optionalTask)
    await operation.value
    #expect(store.hasFreshData && store.error == nil && !store.isLoading)
}

/// request是实际网络记录；expected为独立完整JSON或nil，既检查全部键值也检查DELETE无额外body。
private nonisolated func assertTagBody(_ request: MetadataRequest, expected: String?) throws {
    if let expected {
        let actual = try JSONSerialization.jsonObject(with: #require(request.body))
        let value = try JSONSerialization.jsonObject(with: Data(expected.utf8))
        #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    } else {
        #expect(request.body == nil && request.contentType == nil)
    }
}

/// endpoint/user/token为合成会话，用真实configure制造账号/路由代际变化。
private nonisolated func tagSession(endpoint: URL, user: String, token: String) -> AccountSession {
    .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}
