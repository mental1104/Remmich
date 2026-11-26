import Foundation

/// 应用独立语言选择；持久值与系统语言分开，不改写AppleLanguages、认证或备份任务。
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    /// languages为系统按优先级排列的语言；返回本应用支持的资源代码，未支持语言回退英文。
    func resolvedCode(preferredLanguages languages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            for language in languages {
                if language.lowercased().hasPrefix("zh") {
                    return "zh-Hans"
                }
                if language.lowercased().hasPrefix("en") {
                    return "en"
                }
            }
            return "en"
        }
    }
}

/// SwiftUI以外的文本边界；使用同一语言偏好和标准lproj资源，不翻译协议、用户标题或诊断日志。
nonisolated enum L10n {
    static let preferenceKey = "remmich-app-language"

    /// 正式应用使用标准偏好；仅显式DEBUG验收宿主采用既有隔离suite，避免中英文用例污染其他测试。
    static var preferenceDefaults: UserDefaults {
        #if DEBUG
            let process = ProcessInfo.processInfo
            if process.arguments.contains("-ui-testing-profile") || process.arguments.contains("-ui-testing-search") || process.arguments.contains("-ui-testing-search-presets"),
               let name = process.environment["REMMICH_UI_TEST_PREFERENCES_SUITE"], let defaults = UserDefaults(suiteName: name)
            {
                return defaults
            }
        #endif
        return .standard
    }

    /// 返回当前持久偏好；缺失或未知值按跟随系统处理。
    static var language: AppLanguage {
        AppLanguage(rawValue: preferenceDefaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    /// 返回供独立UIHostingController与SwiftUI共同使用的语言区域。
    static var locale: Locale {
        Locale(identifier: language.resolvedCode())
    }

    /// key只允许应用自有文案，不传入照片名、相簿名、地址或用户资料；language可供独立测试覆盖。
    /// 未收录文案保持原值，避免把未知错误或外部内容变为空文本。
    static func string(_ key: String, language: AppLanguage? = nil) -> String {
        bundle(for: language ?? self.language).localizedString(forKey: key, value: key, table: nil)
    }

    /// value保留Swift插值类型与参数；按所选语言格式化，不能先拼接成String再查找资源。
    static func text(_ value: String.LocalizationValue, language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        return String(localized: value, bundle: bundle(for: selected), locale: Locale(identifier: selected.resolvedCode()))
    }

    /// language限定受支持的本地资源；缺失资源保留主Bundle，构建测试会核对语言文件齐全。
    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.resolvedCode(), ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}
