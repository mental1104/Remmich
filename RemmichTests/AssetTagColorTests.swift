import Foundation
import Testing
@testable import Remmich

/// 颜色意愿与真实Store→manager→会话内URLSession回归；所有标签/照片/身份及响应都是合成数据。
@Suite("Asset tag colors")
@MainActor
struct AssetTagColorTests {
    /// value覆盖官方四种长度和可选#；预期独立声明，RGBA不得被静默改成不透明RGB。
    @Test(arguments: ["abc", "#abc", "aBc8", "#aBc8", "AABBCC", "#aabbcc", "aabbcc88", "#AABBCC88"])
    func acceptsEveryOfficialHexShape(_ value: String) throws {
        let color = try AssetTagColor(hex: value)
        #expect(color.red == 170 && color.green == 187 && color.blue == 204)
        let translucent = value.lowercased().contains("8")
        #expect(color.alpha == (translucent ? 136 : 255))
        #expect(color.hex == (translucent ? "#AABBCC88" : "#AABBCC"))
    }

    /// 空白、未知字符和错误长度不是清除意愿，输入失败不得被编码成null。
    @Test(arguments: ["", "#", "12", "12345", "1234567", "#ggg", " aabbcc", "aabbcc "])
    func refusesInvalidColorValues(_ value: String) {
        #expect(throws: AssetTagError.self) { try AssetTagColor(hex: value) }
    }

    /// keep、set和clear的完整正文分别为空对象、唯一color值及唯一显式null，不带名称或父级。
    @Test func encodesThreeDistinctIntentStates() throws {
        let set = try AssetTagColor(hex: "#abc8")
        for (change, expected) in [(AssetTagColorChange.keep, "{}"), (.set(set), ##"{"color":"#AABBCC88"}"##), (.clear, #"{"color":null}"#)] {
            let bytes = try JSONEncoder().encode(AssetTagColorPatch(change: change))
            try assertColorBody(bytes, expected: expected)
        }
    }

    /// wire缺键与显式null仍有独立存在位；官方无色省略语义可读取，错误color类型必须解码失败。
    @Test(arguments: ["omitted", "null", "invalid"])
    func preservesResponseFieldPresence(_ variant: String) throws {
        let raw = variant == "invalid" ? colorTag().replacingOccurrences(of: ##""color":"#123456""##, with: #""color":false"#)
            : colorTag(color: nil, present: variant == "null")
        if variant == "invalid" {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ManagedTag.self, from: Data(raw.utf8)) }
        } else {
            let tag = try JSONDecoder().decode(ManagedTag.self, from: Data(raw.utf8))
            #expect(tag.color == nil && tag.hasColorField == (variant == "null"))
        }
    }

    /// 单次设置RGB/RGBA或清除都经真实七请求闭环；旧名称/层级/其他颜色/照片关系全部保持。
    @Test(arguments: ["set", "alpha", "clear"])
    func confirmsOnlyTheRequestedColor(_ kind: String) async throws {
        let expected = kind == "clear" ? nil : kind == "alpha" ? "#AABBCC88" : "#AABBCC"
        let next = colorTag(color: expected, present: expected != nil)
        let fixture = MetadataHTTPFixture(exchanges: colorReads() + colorReads() + [colorWrite(next)] + colorReads(root: next))
        defer { fixture.close() }
        let store = AssetTagStore(); await store.reload(assetID: colorAssetID, manager: fixture.manager)?.value
        let change: AssetTagColorChange = if let expected {
            try .set(AssetTagColor(hex: expected))
        } else {
            .clear
        }
        let plan = try store.prepare(.color(tagID: colorRootID, change: change), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager)); await operation.value
        #expect(store.hasFreshData && store.error == nil && store.notice != nil && store.confirmedChanges == 1)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        let state = try #require(store.state)
        #expect(state.tags.first { $0.id == colorRootID }?.color == expected)
        #expect(state.asset.tags.map(\.id) == [colorRootID, colorChildID])
        #expect(state.asset.livePhotoVideoId == colorMotionID)
        let requests = await fixture.script.requests(); try #require(requests.count == 7)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "GET", "PUT", "GET", "GET"])
        let body = try #require(requests[4].body)
        try assertColorBody(body, expected: expected.map { #"{"color":"\#($0)"}"# } ?? #"{"color":null}"#)
        #expect(store.start(plan, manager: fixture.manager) == nil)
    }

    /// 保留和语义相同的颜色没有写动作；不因#rgb与#RRGGBB不同拼法而虚构颜色变更。
    @Test func keepAndEquivalentColorNeverWrite() async throws {
        let fixture = MetadataHTTPFixture(exchanges: colorReads(root: colorTag(color: "#abc"))); defer { fixture.close() }
        let store = AssetTagStore(); await store.reload(assetID: colorAssetID, manager: fixture.manager)?.value
        let same = try AssetTagColor(hex: "#AABBCC")
        for change in [AssetTagColorChange.keep, .set(same)] {
            #expect(throws: AssetTagError.self) { try store.prepare(.color(tagID: colorRootID, change: change), manager: fixture.manager) }
        }
        #expect(await fixture.script.requests().count == 2 && fixture.manager.revision == 0)
    }

    /// 预检时颜色已被其他客户端改变，旧确认无写入；不把新服务端值当当前草稿覆盖。
    @Test func changedColorPreflightStopsBeforePut() async throws {
        let fixture = MetadataHTTPFixture(exchanges: colorReads() + colorReads(root: colorTag(color: "#111111"))); defer { fixture.close() }
        let store = AssetTagStore(); await store.reload(assetID: colorAssetID, manager: fixture.manager)?.value
        let plan = try store.prepare(.color(tagID: colorRootID, change: .clear), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.confirmedChanges == 0)
        let requests = await fixture.script.requests(); #expect(requests.count == 4 && requests.allSatisfy { $0.method == "GET" })
    }

    /// 错状态/身份/定义/缺失新颜色拒绝写回执；后读改变其他标签或关系也不能宣称颜色操作已完整确认。
    @Test(arguments: ["201", "id", "name", "parent", "created", "missing-color", "wrong-color", "other-color", "lost-relation", "old-attached-color"])
    func unconfirmedColorEffectsRequireReload(_ variant: String) async throws {
        let next = colorTag(color: "#AABBCC")
        let postFailure = ["other-color", "lost-relation", "old-attached-color"].contains(variant)
        var receipt = next
        if variant == "id" {
            receipt = receipt.replacingOccurrences(of: colorRootID, with: colorOtherID)
        }
        if variant == "name" {
            receipt = receipt.replacingOccurrences(of: "Root", with: "Renamed")
        }
        if variant == "parent" {
            receipt = receipt.replacingOccurrences(of: #""name":"Root""#, with: #""parentId":"\#(colorChildID)","name":"Root""#)
        }
        if variant == "created" {
            receipt = receipt.replacingOccurrences(of: "2026-11-24", with: "2026-11-23")
        }
        if variant == "missing-color" {
            receipt = colorTag(color: nil, present: false)
        }
        if variant == "wrong-color" {
            receipt = colorTag(color: "#000000")
        }
        var sequence = colorReads() + colorReads() + [colorWrite(receipt, status: variant == "201" ? 201 : 200)]
        if postFailure {
            sequence += colorReads(root: next, child: variant == "other-color" ? colorChild(color: "#000000") : colorChild(),
                                   attachedRoot: variant == "lost-relation" ? "" : variant == "old-attached-color" ? colorTag() : next)
        }
        let fixture = MetadataHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = AssetTagStore(); await store.reload(assetID: colorAssetID, manager: fixture.manager)?.value
        let plan = try store.prepare(.color(tagID: colorRootID, change: .set(AssetTagColor(hex: "#AABBCC"))), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && !store.isWorking && !fixture.manager.busy)
        #expect(store.confirmedChanges == (postFailure ? 1 : 0))
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == sequence.count)
    }

    /// 真实预检/写/后读门闩内取消或换号；旧颜色不能恢复fresh或自动重发，门及会话始终被释放。
    @Test(.timeLimit(.minutes(1)), arguments: [2, 4, 5], [false, true])
    func retiresColorRequestsAtEachStage(_ heldIndex: Int, _ switchesAccount: Bool) async throws {
        let next = colorTag(color: "#AABBCC")
        var sequence = colorReads() + colorReads() + [colorWrite(next)] + colorReads(root: next)
        sequence[heldIndex].held = true
        let fixture = MetadataHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = AssetTagStore(); await store.reload(assetID: colorAssetID, manager: fixture.manager)?.value
        let plan = try store.prepare(.color(tagID: colorRootID, change: .set(AssetTagColor(hex: "#AABBCC"))), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        let observer = Task { await operation.value; await fixture.script.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld())
                if switchesAccount {
                    fixture.manager.configure(session: nil, endpoint: nil); store.invalidate(manager: fixture.manager)
                } else {
                    operation.cancel()
                }
                await fixture.script.release(); await operation.value; await fixture.script.waitForHeldResponderExit()
                #expect(!store.hasFreshData && !store.isWorking)
                #expect(await fixture.script.requests().count == heldIndex + 1)
                if switchesAccount {
                    #expect(store.state == nil && fixture.manager.revision == 0)
                }
            } onCancel: { operation.cancel(); Task { @MainActor in fixture.close() } }
        } catch { fixture.close(); await fixture.script.stop(); await operation.value; await observer.value; throw error }
        await observer.value; await fixture.script.stop()
    }
}

private nonisolated let colorAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let colorRootID = "55555555-5555-4555-8555-555555555555"
private nonisolated let colorChildID = "66666666-6666-4666-8666-666666666666"
private nonisolated let colorOtherID = "77777777-7777-4777-8777-777777777777"
private nonisolated let colorMotionID = "44444444-4444-4444-8444-444444444444"

/// color/present独立控制真实JSON值与键存在性，其他固定字段用于核对改色不改定义。
private nonisolated func colorTag(color: String? = "#123456", present: Bool = true) -> String {
    let field = present ? color.map { #", "color":"\#($0)""# } ?? #", "color":null"# : ""
    return #"{"id":"\#(colorRootID)","name":"Root","value":"Root","createdAt":"2026-11-24T00:00:00Z","updatedAt":"2026-11-24T00:00:00Z"\#(field)}"#
}

/// 另一个标签的固定独立定义；不会从生产补丁推导预期颜色或继承父标签颜色。
private nonisolated func colorChild(color: String = "#778899") -> String {
    #"{"id":"\#(colorChildID)","parentId":"\#(colorRootID)","name":"Child","value":"Root/Child","createdAt":"2026-11-24T00:00:00Z","updatedAt":"2026-11-24T00:00:00Z","color":"\#(color)"}"#
}

/// root/child是独立目录数据，attachedRoot只改变资源关系回读；本函数不调用或替换Store。
private nonisolated func colorReads(root: String = colorTag(), child: String = colorChild(), attachedRoot: String? = nil) -> [MetadataExchange] {
    let relationship = attachedRoot ?? root
    let attached = relationship.isEmpty ? child : relationship + "," + child
    let asset = #"{"id":"\#(colorAssetID)","ownerId":"11111111-1111-4111-8111-111111111111","type":"IMAGE","isTrashed":false,"livePhotoVideoId":"\#(colorMotionID)","tags":[\#(attached)]}"#
    return [.init(method: "GET", path: "tags", status: 200, json: "[\(root),\(child)]"),
            .init(method: "GET", path: "assets/\(colorAssetID)", status: 200, json: asset)]
}

/// 回执只属于精确PUT标签资源；不提供改名/关系写路由，意外额外写会被真实夹具拒绝。
private nonisolated func colorWrite(_ json: String, status: Int = 200) -> MetadataExchange {
    .init(method: "PUT", path: "tags/\(colorRootID)", status: status, json: json)
}

/// bytes为真实编码/HTTP完整正文，expected为独立JSON常量；比较整个对象，任何额外键也失败。
private nonisolated func assertColorBody(_ bytes: Data, expected: String) throws {
    let value = try JSONSerialization.jsonObject(with: bytes)
    let object = try #require(value as? NSDictionary)
    let expectedValue = try JSONSerialization.jsonObject(with: Data(expected.utf8))
    let expectedObject = try #require(expectedValue as? [String: Any])
    #expect(object.isEqual(to: expectedObject))
}
