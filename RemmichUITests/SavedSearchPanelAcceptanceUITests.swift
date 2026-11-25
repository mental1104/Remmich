import Foundation
import XCTest

/// 通过真实搜索面板操作登记；宿主只替换HTTP字节，测试独立核对最终请求而不直接调用CRUD。
final class SavedSearchPanelAcceptanceUITests: XCTestCase {
    /// 第一处失败即保留现场，避免后续操作覆盖原始请求及截图证据。
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 创建及改名后改变当前条件，再点击真实保存行，最终搜索必须恢复原条件而非当前草稿。
    @MainActor func testCreateRenameAndApplyRestoresSavedConditions() throws {
        let app = launch()
        submit("Before", in: app)
        setFavorites(true, in: app)
        try assertSearchBody(query: "Before", favorite: true, in: app)
        reloadPresets(in: app)
        replaceName("Created", in: app)
        tap("saved-search-save", in: app)
        assertLabel("GET=1 POST=1 PATCH=0 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        assertLabel("Created", identifier: createdRow, in: app)
        try assertPresetBody(name: "Created", query: "Before", favorite: true, in: app)

        openMenu(identifier: createdID, action: "Rename", in: app)
        replaceName("Renamed", in: app)
        tap("saved-search-save", in: app)
        assertLabel("GET=2 POST=1 PATCH=1 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        assertLabel("Renamed", identifier: createdRow, in: app)
        try assertPresetBody(name: "Renamed", query: "Before", favorite: true, in: app)

        submit("Other", in: app)
        setFavorites(false, in: app)
        try assertSearchBody(query: "Other", favorite: false, in: app)
        tap(createdRow, in: app)
        try assertSearchBody(query: "Before", favorite: true, in: app)
        assertLabel("GET=2 POST=1 PATCH=1 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        assertLabel("none", identifier: "saved-search-test-violations", in: app)
        capture("saved-search-create-rename-apply", app: app)
    }

    /// 替换和删除都先验证真实取消零写入，再确认；复用必须保留新文字/视频类型并去除旧收藏条件。
    @MainActor func testReplaceAndDeleteRequireConfirmation() throws {
        let app = launch()
        submit("Before", in: app)
        setFavorites(true, in: app)
        reloadPresets(in: app)
        replaceName("Target", in: app)
        tap("saved-search-save", in: app)
        assertLabel("Target", identifier: createdRow, in: app)

        submit("After", in: app)
        setFavorites(false, in: app)
        selectMedia("Videos", in: app)
        try assertSearchBody(query: "After", favorite: false, media: "VIDEO", in: app)
        openMenu(identifier: createdID, action: "Replace with current conditions", in: app)
        cancelConfirmation("saved-search-confirm-replace", in: app)
        assertCountsStay("GET=1 POST=1 PATCH=0 DELETE=0", in: app)

        openMenu(identifier: createdID, action: "Replace with current conditions", in: app)
        tap("saved-search-confirm-replace", in: app)
        assertLabel("GET=2 POST=1 PATCH=1 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        try assertPresetBody(name: "Target", query: "After", favorite: false, media: "video", in: app)
        submit("Unrelated", in: app)
        setFavorites(true, in: app)
        selectMedia("All", in: app)
        try assertSearchBody(query: "Unrelated", favorite: true, in: app)
        tap(createdRow, in: app)
        try assertSearchBody(query: "After", favorite: false, media: "VIDEO", in: app)

        openMenu(identifier: createdID, action: "Delete saved search", in: app)
        cancelConfirmation("saved-search-confirm-delete", in: app)
        assertCountsStay("GET=2 POST=1 PATCH=1 DELETE=0", in: app)
        XCTAssertTrue(element(createdRow, in: app).exists)
        openMenu(identifier: createdID, action: "Delete saved search", in: app)
        tap("saved-search-confirm-delete", in: app)
        assertLabel("GET=2 POST=1 PATCH=1 DELETE=1", identifier: "saved-search-test-request-counts", in: app)
        waitUntilGone(element(createdRow, in: app))
        assertLabel("none", identifier: "saved-search-test-violations", in: app)
        capture("saved-search-replace-delete-confirmation", app: app)
    }

    /// 服务端409保留名称草稿并禁写；仅修改名称不能重发，显式Reload后才能保存新名称。
    @MainActor func testConflictKeepsDraftAndRequiresReloadBeforeRetry() throws {
        let app = launch()
        submit("Before", in: app)
        setFavorites(true, in: app)
        reloadPresets(in: app)
        assertLabel("Existing", identifier: "saved-search-apply-88888888-8888-4888-8888-888888888888", in: app)
        replaceName("Existing", in: app)
        tap("saved-search-save", in: app)
        let error = waitForLabel("saved-search-error", matching: NSPredicate(format: "label CONTAINS %@", "already exists"), in: app)
        XCTAssertTrue(error.label.contains("draft was kept"))
        XCTAssertEqual(element("saved-search-name", in: app).value as? String, "Existing")
        let save = element("saved-search-save", in: app)
        XCTAssertFalse(save.isEnabled)
        assertCountsStay("GET=1 POST=1 PATCH=0 DELETE=0", in: app)

        replaceName("Unique", in: app)
        XCTAssertFalse(save.isEnabled)
        assertCountsStay("GET=1 POST=1 PATCH=0 DELETE=0", in: app)
        capture("saved-search-conflict-keeps-draft", app: app)
        tap("saved-search-reload", in: app)
        assertLabel("GET=2 POST=1 PATCH=0 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        waitUntilEnabled(save)
        XCTAssertEqual(element("saved-search-name", in: app).value as? String, "Unique")
        tap("saved-search-save", in: app)
        assertLabel("GET=2 POST=2 PATCH=0 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
        assertLabel("Unique", identifier: createdRow, in: app)
        try assertPresetBody(name: "Unique", query: "Before", favorite: true, in: app)
        XCTAssertFalse(element("saved-search-error", in: app).exists)
        assertLabel("none", identifier: "saved-search-test-violations", in: app)
        capture("saved-search-conflict-explicit-retry", app: app)
    }

    /// 新建项的固定合成UUID只定位真实面板行，不用于触发宿主或直接执行操作。
    private var createdID: String {
        "11111111-1111-4111-8111-111111111111"
    }

    private var createdRow: String {
        "saved-search-apply-\(createdID)"
    }

    /// 仅显式三flag进入隔离宿主；等真实repo/manager配置完成，使用独立偏好避免普通账户数据。
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-search", "-ui-testing-search-presets", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["REMMICH_UI_TEST_PREFERENCES_SUITE"] = "saved-search-ui-\(UUID().uuidString)"
        app.launch()
        assertLabel("ready", identifier: "saved-search-test-ready", in: app)
        return app
    }

    /// identifier为精确AX身份，返回真实后代，不依赖SwiftUI生成的具体节点类型。
    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 真实Disclosure关闭时才展开；不直接调用Store，Reload必须点击实际按钮。
    @MainActor private func reloadPresets(in app: XCUIApplication) {
        if !element("saved-search-reload", in: app).exists {
            let disclosure = app.buttons["Saved searches"]
            reveal(disclosure, in: app)
            disclosure.tap()
        }
        tap("saved-search-reload", in: app)
        waitUntilEnabled(element("saved-search-name", in: app))
        assertLabel("GET=1 POST=0 PATCH=0 DELETE=0", identifier: "saved-search-test-request-counts", in: app)
    }

    /// value替换真实名称框内容，保留键盘事件与Panel草稿逻辑；本方法不提交保存。
    @MainActor private func replaceName(_ value: String, in app: XCUIApplication) {
        let field = element("saved-search-name", in: app)
        reveal(field, in: app)
        field.tap()
        if let previous = field.value as? String, !previous.isEmpty, previous != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value)
    }

    /// query为纯合成文字；滚回系统searchable字段后提交，结果必须来自真实SDK请求。
    @MainActor private func submit(_ query: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        for _ in 0 ..< 10 {
            if field.isHittable {
                break
            }
            app.swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.tap()
        if let previous = field.value as? String, !previous.isEmpty, previous != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(query + "\n")
    }

    /// enabled为目标收藏状态；只在控件关闭时展开Filters，再使用真实UISwitch，不用fixture修改query。
    @MainActor private func setFavorites(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["search-favorites"]
        if !toggle.exists {
            let filters = app.buttons["Filters"]
            reveal(filters, in: app)
            filters.tap()
        }
        reveal(toggle, in: app)
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            toggle.tap()
        }
        XCTAssertEqual(toggle.value as? String, expected)
    }

    /// title选择真实Media分段；复用前明确改成不同类型，JSON断言再核对保存条件是否完整恢复。
    @MainActor private func selectMedia(_ title: String, in app: XCUIApplication) {
        let option = app.segmentedControls["search-media"].buttons[title]
        reveal(option, in: app)
        option.tap()
        XCTAssertTrue(option.isSelected)
    }

    /// identifier为已存在登记的UUID，action为真实Menu标签；返回后可等待confirmation或名称输入。
    @MainActor private func openMenu(identifier: String, action: String, in app: XCUIApplication) {
        tap("saved-search-manage-\(identifier)", in: app)
        let button = app.buttons.matching(NSPredicate(format: "label == %@", action)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    /// confirmation为真实确认按钮ID；iPhone点系统Cancel，iPad无Cancel时点popover外，等待对话框真正退出。
    @MainActor private func cancelConfirmation(_ confirmation: String, in app: XCUIApplication) {
        let confirm = element(confirmation, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.05)).tap()
        }
        waitUntilGone(confirm)
    }

    /// expected为完整preset方法计数；真实取消后在有限观察窗内禁止任何后台CRUD，避免只读瞬时计数漏掉晚写。
    @MainActor private func assertCountsStay(_ expected: String, in app: XCUIApplication) {
        assertLabel(expected, identifier: "saved-search-test-request-counts", in: app)
        let counts = element("saved-search-test-request-counts", in: app)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", expected), object: counts)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.75), .completed)
    }

    /// query/favorite/media是独立业务预期；同一远程查询匹配实际JSON各条件，再按真实wire键逐项核对。
    /// 缺省字段仍须不存在；合并AX查询只避免重复快照耗尽原10秒，不放宽正文断言。
    @MainActor private func assertSearchBody(query: String, favorite: Bool, media: String? = nil, in app: XCUIApplication) throws {
        var predicates = [NSPredicate(format: "label CONTAINS %@", query),
                          NSPredicate(format: favorite ? "label CONTAINS 'isFavorite'" : "NOT (label CONTAINS 'isFavorite')")]
        if let media {
            predicates.append(NSPredicate(format: "label CONTAINS %@", media))
        }
        let item = waitForLabel("saved-search-test-last-search-body", matching: NSCompoundPredicate(andPredicateWithSubpredicates: predicates), in: app)
        let body = try jsonBody(item)
        let filter = try XCTUnwrap(body["filter"] as? [String: Any])
        XCTAssertEqual((filter["originalFileName"] as? [String: String])?["like"], query)
        if favorite {
            XCTAssertEqual((filter["isFavorite"] as? [String: Bool])?["eq"], true)
        } else {
            XCTAssertNil(filter["isFavorite"])
        }
        if let media {
            XCTAssertEqual((filter["type"] as? [String: String])?["eq"], media)
        } else {
            XCTAssertNil(filter["type"])
        }
    }

    /// name/query/favorite/media独立核对真实POST/PATCH字节；等待包含完整新条件的同一AX快照，不能只等未改变的名称。
    /// 登记使用mediaType小写，不能与搜索filter.type大写混用。
    @MainActor private func assertPresetBody(name: String, query: String, favorite: Bool, media: String? = nil, in app: XCUIApplication) throws {
        var predicates = [NSPredicate(format: "label CONTAINS %@", name), NSPredicate(format: "label CONTAINS %@", query),
                          NSPredicate(format: favorite ? "label CONTAINS 'isFavorite'" : "NOT (label CONTAINS 'isFavorite')")]
        if let media {
            predicates.append(NSPredicate(format: "label CONTAINS %@", media))
        }
        let item = waitForLabel("saved-search-test-last-preset-body", matching: NSCompoundPredicate(andPredicateWithSubpredicates: predicates), in: app)
        let body = try jsonBody(item)
        XCTAssertEqual(body["name"] as? String, name)
        let conditions = try XCTUnwrap(body["conditions"] as? [String: Any])
        XCTAssertEqual((conditions["query"] as? [String: String])?["value"], query)
        XCTAssertEqual((conditions["query"] as? [String: String])?["type"], "metadata")
        if favorite {
            XCTAssertEqual(conditions["isFavorite"] as? Bool, true)
        } else {
            XCTAssertNil(conditions["isFavorite"])
        }
        if let media {
            XCTAssertEqual(conditions["mediaType"] as? String, media)
        } else {
            XCTAssertNil(conditions["mediaType"])
        }
    }

    /// item.label仅为宿主捕获的真实HTTP正文；使用独立Foundation解析，坏JSON或根对象错误直接失败。
    @MainActor private func jsonBody(_ item: XCUIElement) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(item.label.utf8)) as? [String: Any])
    }

    /// identifier定位真实按钮并有限滚动后点击，找不到或不可交互即失败，不绕过UI调用动作。
    @MainActor private func tap(_ identifier: String, in app: XCUIApplication) {
        let item = element(identifier, in: app)
        reveal(item, in: app)
        item.tap()
    }

    /// item可在当前视口上下两侧；有限向下/向上搜索，确保从深层筛选返回Saved面板时也能找到控件。
    @MainActor private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        for _ in 0 ..< 8 {
            if item.isHittable {
                return
            }
            app.swipeUp()
        }
        for _ in 0 ..< 16 {
            if item.isHittable {
                return
            }
            app.swipeDown()
        }
        XCTAssertTrue(item.isHittable)
    }

    /// label/identifier为明确HTTP阶段或UI文本，在单次远程查询内精确匹配，不以固定sleep推断完成。
    @MainActor private func assertLabel(_ label: String, identifier: String, in app: XCUIApplication) {
        _ = waitForLabel(identifier, matching: NSPredicate(format: "label == %@", label), in: app)
    }

    /// identifier限定唯一AX身份，predicate仅匹配真实label条件，app为本场景应用；返回同快照匹配节点供独立JSON解析。
    /// identity与label交给查询端一次核对，随后仅等待exists；保留原10秒，避免二次AX快照造成误报。
    @MainActor private func waitForLabel(_ identifier: String, matching predicate: NSPredicate, in app: XCUIApplication) -> XCUIElement {
        let item = app.descendants(matching: .any).matching(identifier: identifier).matching(predicate).firstMatch
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: item)], timeout: 10)
        return item
    }

    /// item为已经出现的名称框或保存按钮；只有可用后才继续操作，不跳过fresh-list门禁。
    @MainActor private func waitUntilEnabled(_ item: XCUIElement) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: item)], timeout: 10)
    }

    /// item为已取消对话框或已删除行；要求真实AX节点移除，不能只验证请求计数。
    @MainActor private func waitUntilGone(_ item: XCUIElement) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item)], timeout: 10)
    }

    /// name仅为固定合成场景名；每条路径保存真实当前画面，保留于xcresult供手机/平板审查。
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
