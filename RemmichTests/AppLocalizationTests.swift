import Foundation
import Testing
@testable import Remmich

/// 使用真实Bundle文案与独立偏好，核查语言回退、插值和持久化，不改进程的全局语言。
@Suite("App language and resources")
@MainActor struct AppLocalizationTests {
    /// 系统首选列表只采用支持的语言；繁体系统也能使用现有简体资源，未知语言回退英文。
    @Test func resolvesSupportedLanguages() {
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["zh-CN", "en-US"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["en-GB", "zh-Hans"]) == "en")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["fr-FR", "zh-TW"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ja-JP"]) == "en")
        #expect(AppLanguage.english.resolvedCode(preferredLanguages: ["zh-Hans"]) == "en")
        #expect(AppLanguage.simplifiedChinese.resolvedCode(preferredLanguages: ["en"]) == "zh-Hans")
    }

    /// 真正读取打包后的资源；中文旧键也必须可显示英文，插值中的用户名称保持原样。
    @Test func resolvesBothLanguagesAndPreservesUserContent() {
        #expect(L10n.string("Me", language: .english) == "Me")
        #expect(L10n.string("Me", language: .simplifiedChinese) == "我的")
        #expect(L10n.string("导入旧备份记录（可选）", language: .english) == "Import Old Backup History (Optional)")
        #expect(L10n.string("导入旧备份记录（可选）", language: .simplifiedChinese) == "导入旧备份记录（可选）")
        let name = "Library"
        #expect(L10n.text("Keep \(name)", language: .simplifiedChinese) == "保留Library")
        #expect(L10n.string("unregistered-ui-key", language: .simplifiedChinese) == "unregistered-ui-key")
    }

    /// 数字保持Swift插值类型，不能将已拼接的字符串作为资源键；匹配不冒充新上传。
    @Test func formatsRealBackupProgress() {
        let completed = 2, matched = 3, unconfirmed = 4, failed = 5, processed = 14
        #expect(L10n.text("Loaded \(completed) items", language: .simplifiedChinese) == "已载入 2 项")
        #expect(L10n.text("已处理 \(processed) 项：新备份 \(completed)，已匹配 \(matched)，备份未确认 \(unconfirmed)，失败 \(failed)。", language: .english)
            == "Processed 14: 2 new backups, 3 matched, 4 unconfirmed, 5 failed.")
        #expect(L10n.text("已处理 \(processed) 项：新备份 \(completed)，已匹配 \(matched)，备份未确认 \(unconfirmed)，失败 \(failed)。", language: .simplifiedChinese)
            == "已处理 14 项：新备份 2，已匹配 3，备份未确认 4，失败 5。")
    }

    /// 使用独立suite验证冷启动恢复；偏好更新不改系统AppleLanguages或其他账户资料。
    @Test @MainActor func persistsOnlyAppPreference() throws {
        let name = "remmich-language-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ja-JP"], forKey: "AppleLanguages")
        let settings = AppLanguageSettings(defaults: defaults)
        #expect(settings.selection == .system)
        settings.selection = .simplifiedChinese
        #expect(AppLanguageSettings(defaults: defaults).selection == .simplifiedChinese)
        settings.selection = .english
        #expect(AppLanguageSettings(defaults: defaults).locale.identifier == "en")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja-JP"])
        defaults.set("future-language", forKey: L10n.preferenceKey)
        #expect(AppLanguageSettings(defaults: defaults).selection == .system)
    }

    /// 核对已编译资源的键和插值类型，避免缺语言或把数字/用户名称填入错误位置。
    @Test func bundlesHaveMatchingKeysAndPlaceholders() throws {
        let english = try resourceTable("en"), chinese = try resourceTable("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|lf|@)"#)
        for (key, value) in english {
            let translated = try #require(chinese[key])
            let expected = placeholders(value, expression: expression)
            #expect(expected == placeholders(translated, expression: expression), "Format mismatch for \(key)")
        }
    }

    /// language是Bundle内的资源目录；返回系统已编译的标准字符串表，缺资源直接失败。
    private func resourceTable(_ language: String) throws -> [String: String] {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// value为资源译文，expression是固定格式语法；返回排序后的占位符类型，允许译文调整顺序。
    private func placeholders(_ value: String, expression: NSRegularExpression) -> [String] {
        expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }
}

/// 底栏顺序和相簿别名共同形成导航契约，不以可见标题作为持久身份。
@Suite("Unified profile and library navigation")
struct MyNavigationTests {
    /// 所有根布局保持五项，“我的”始终最右；照片/视频在主布局继续独立。
    @Test @MainActor func profileRemainsRightmostAndAlbumsShareLibraryPosition() {
        #expect(NativeTabLayout.primaryDestinations == [.photos, .videos, .library, .search, .account])
        for owner in [nil, .photos, .videos] as [NativeTabDestination?] {
            let tabs = NativeTabLayout.destinations(compactOwner: owner)
            #expect(tabs.count == 5 && tabs.last == .account)
        }
        #expect(NativeTabLayout.adjacentDestination(from: .albums, direction: .previous, compactOwner: nil) == .videos)
        #expect(NativeTabLayout.adjacentDestination(from: .albums, direction: .next, compactOwner: nil) == .search)
        #expect(NativeTabLayout.adjacentDestination(from: .account, direction: .next, compactOwner: nil) == nil)
        #expect(NativeTabLayout.pageDirection(from: .albums, to: .library, compactOwner: nil) == nil)
    }
}
