import XCTest

/// 在独立DEBUG宿主验证真实搜索视图；全部账号、结果和像素为本地合成资料。
final class SearchAcceptanceUITests: XCTestCase {
    /// 真实UIKit底栏保持五项，“我的”最右；相簿和分类共享图库且记住子页选择。
    @MainActor func testUnifiedProfileAndLibraryNavigation() {
        let app = launchProfile(language: "en")
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["Me"].waitForExistence(timeout: 10))
        XCTAssertEqual(tabs.buttons.count, 5)
        XCTAssertTrue(tabs.buttons["Photos"].exists)
        XCTAssertTrue(tabs.buttons["Videos"].exists)
        XCTAssertGreaterThan(tabs.buttons["Me"].frame.midX, tabs.buttons["Search"].frame.midX)
        tabs.buttons["Library"].tap()
        XCTAssertTrue(element("library-section-picker", in: app).waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Collections"].tap()
        XCTAssertTrue(element("profile-fixture-collections", in: app).waitForExistence(timeout: 5))
        tabs.buttons["Me"].tap()
        XCTAssertTrue(element("my-language", in: app).waitForExistence(timeout: 5))
        capture("profile-english", app: app)
        tabs.buttons["Library"].tap()
        XCTAssertTrue(element("profile-fixture-collections", in: app).waitForExistence(timeout: 5))
        capture("library-collections-english", app: app)
    }

    /// 中文启动后在应用内切回英文，保留当前导航并验证冷启动语言偏好；不修改设备语言。
    @MainActor func testChineseProfileAndExplicitEnglishSwitch() {
        let suite = "profile-language-ui-" + UUID().uuidString
        let app = launchProfile(language: "zh-Hans", preferencesSuite: suite)
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["我的"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(tabs.buttons["我的"].frame.midX, tabs.buttons["搜索"].frame.midX)
        tabs.buttons["我的"].tap()
        element("my-language", in: app).tap()
        XCTAssertTrue(element("app-language-picker", in: app).waitForExistence(timeout: 5))
        capture("profile-language-chinese", app: app)
        app.staticTexts["English"].tap()
        XCTAssertTrue(tabs.buttons["Me"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Me"].isSelected)
        XCTAssertTrue(element("app-language-settings", in: app).exists)
        capture("profile-language-switched-english", app: app)
        app.terminate()
        let restored = launchProfile(language: nil, preferencesSuite: suite)
        XCTAssertTrue(restored.tabBars.buttons["Me"].waitForExistence(timeout: 10))
    }

    /// language仅在显式DEBUG宿主中设置应用偏好；nil保留上次选择以验证重启恢复。
    @MainActor private func launchProfile(language: String?, preferencesSuite: String = "profile-ui-" + UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-profile"]
        app.launchEnvironment["REMMICH_UI_TEST_PREFERENCES_SUITE"] = preferencesSuite
        if let language {
            app.launchEnvironment["REMMICH_UI_TEST_LANGUAGE"] = language
        }
        app.launch()
        return app
    }

    /// 单个断言失败即停止，避免后续手势污染首个失败证据。
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 空白页不得出现演示结果；执行查询后沿用原生查看器打开合成像素。
    @MainActor func testBlankSearchAndViewer() {
        let app = launch()
        XCTAssertTrue(element("search-empty-state", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("search-loaded-count", in: app).exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-'")).count, 0)
        submit("synthetic", in: app)
        assertLabel("Loaded 2 items", identifier: "search-loaded-count", in: app)
        let first = app.buttons["search-result-search-alpha-1"]
        let second = app.buttons["search-result-search-alpha-2"]
        XCTAssertTrue(first.isHittable)
        XCTAssertLessThan(abs(first.frame.width - first.frame.height), 1)
        XCTAssertLessThan(abs(second.frame.width - second.frame.height), 1)
        XCTAssertFalse(first.frame.intersects(second.frame))
        capture("search-results-portrait", app: app)
        first.tap()
        XCTAssertTrue(element("asset-viewer-page-search-alpha-1", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("asset-viewer-rendered-pixels-search-alpha-1", in: app).waitForExistence(timeout: 10))
        capture("search-native-viewer", app: app)
    }

    /// 首次续页失败必须保留首屏；显式重试后按ID去重，不能显示重复照片。
    @MainActor func testPaginationFailureRetry() {
        let app = launch()
        submit("retry", in: app)
        assertLabel("Loaded 1 items", identifier: "search-loaded-count", in: app)
        reveal(app.buttons["search-load-more"], in: app)
        app.buttons["search-load-more"].tap()
        XCTAssertTrue(element("search-error", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-result-search-alpha-1"].exists)
        app.buttons["search-retry"].tap()
        assertLabel("Loaded 2 items", identifier: "search-loaded-count", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "search-result-search-alpha-1").count, 1)
        XCTAssertTrue(app.buttons["search-result-search-alpha-2"].exists)
        XCTAssertFalse(element("search-error", in: app).exists)
        capture("search-page-retry", app: app)
    }

    /// 筛选改变真实查询；横竖屏与键盘开启时搜索入口仍应处于可交互窗口内。
    @MainActor func testFavoriteFilterRotationAndKeyboard() {
        let app = launch()
        submit("synthetic", in: app)
        assertLabel("Loaded 2 items", identifier: "search-loaded-count", in: app)
        app.buttons["Filters"].tap()
        let favorites = app.switches["search-favorites"]
        reveal(favorites, in: app)
        favorites.tap()
        assertLabel("Loaded 1 items", identifier: "search-loaded-count", in: app)
        XCTAssertFalse(app.buttons["search-result-search-alpha-2"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        let field = searchField(in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.frame.contains(field.frame))
        XCTAssertFalse(app.keyboards.firstMatch.frame.intersects(field.frame))
        capture("search-landscape-keyboard", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.frame.contains(field.frame))
        XCTAssertFalse(app.keyboards.firstMatch.frame.intersects(field.frame))
        capture("search-portrait-keyboard", app: app)
    }

    /// 等待旧请求进入，再切换账号并等到旧响应实际返回，证明代际发布隔离。
    @MainActor func testAccountSwitchRejectsLateResponse() {
        let app = launch()
        submit("late", in: app)
        assertLabel("started late", identifier: "search-test-request", in: app)
        dismissSearchIfAccountHidden(in: app)
        app.buttons["account-button"].tap()
        assertLabel("Synthetic account beta", identifier: "search-test-account", in: app)
        submit("synthetic", in: app)
        XCTAssertTrue(app.buttons["search-result-search-beta-1"].waitForExistence(timeout: 5))
        assertLabel("completed", identifier: "search-test-retired", in: app)
        XCTAssertFalse(app.buttons["search-result-search-alpha-9"].exists)
        XCTAssertTrue(app.buttons["search-result-search-beta-1"].exists)
        assertLabel("Loaded 2 items", identifier: "search-loaded-count", in: app)
        capture("search-account-generation", app: app)
    }

    /// 服务返回空页与错误分开展示；错误不能被错误包装成没有结果。
    @MainActor func testEmptyAndErrorStates() {
        let app = launch()
        submit("empty", in: app)
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 5))
        submit("error", in: app)
        XCTAssertTrue(element("search-error", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-retry"].exists)
        capture("search-explicit-error", app: app)
    }

    /// 返回仅合成签入的应用；独立偏好suite避免读写普通账号设置，测试结束由runner终止进程。
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-search", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["REMMICH_UI_TEST_PREFERENCES_SUITE"] = "search-ui-\(UUID().uuidString)"
        app.launch()
        return app
    }

    /// identifier是稳定可访问性ID；返回跨SwiftUI元素类型的首个匹配项。
    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// identifier和精确label合成一次远程查询，再等待其存在，保留原10秒及完整成功条件。
    /// 分别读取exists/label会请求两次AX快照：首快照已匹配也可能被第二次读取耗尽等待预算。
    @MainActor private func assertLabel(_ label: String, identifier: String, in app: XCUIApplication) {
        let item = app.descendants(matching: .any).matching(identifier: identifier)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        let predicate = NSPredicate(format: "exists == true")
        expectation(for: predicate, evaluatedWith: item)
        waitForExpectations(timeout: 10)
    }

    /// 返回系统searchable字段，必要时下拉展开导航栏；找不到即在本方法失败。
    @MainActor private func searchField(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        for _ in 0 ..< 8 {
            if field.isHittable {
                break
            }
            app.swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        return field
    }

    /// 输入纯合成场景名；清除旧文本并提交以收起键盘，不触发正常登录入口。
    @MainActor private func submit(_ query: String, in app: XCUIApplication) {
        let field = searchField(in: app)
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(query + "\n")
    }

    /// 搜索激活会隐藏导航栏账号入口；先点平板固定退出入口，再兼容原生Close和旧Cancel/close，不释放late响应gate。
    /// app仍是合成宿主；调用后保留原account按钮点击与所有账号代际断言，缺入口照常失败。
    @MainActor private func dismissSearchIfAccountHidden(in app: XCUIApplication) {
        guard !app.buttons["account-button"].isHittable else { return }
        if app.buttons["search-dismiss"].exists {
            app.buttons["search-dismiss"].tap()
        } else if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else if app.buttons["close"].exists {
            app.buttons["close"].tap()
        }
    }

    /// 在有限次数滚动内露出指定元素；无限滚动会掩盖布局回归，因此失败即报告。
    @MainActor private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 {
            if item.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(item.isHittable)
    }

    /// 保存当前设备和方向的截图到xcresult；name仅使用无私人资料的固定场景名。
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
