import Observation
import SwiftUI

/// 只管理界面语言；切换时刷新文案环境，保留当前导航、认证与后台任务实例。
@MainActor @Observable final class AppLanguageSettings {
    static let shared = AppLanguageSettings()
    private let defaults: UserDefaults
    var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: L10n.preferenceKey) }
    }

    /// defaults默认为应用偏好，测试可传独立suite；初始化不修改已有值。
    init(defaults: UserDefaults = L10n.preferenceDefaults) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "") ?? .system
    }

    /// 当前SwiftUI及UIKit宿主共同采用的区域；跟随系统时在前台重建环境即可更新。
    var locale: Locale {
        Locale(identifier: selection.resolvedCode())
    }
}

/// 应用内语言入口；语言名始终用自身语言书写，便于在陌生界面中切回。
struct AppLanguageSettingsView: View {
    @State private var settings = AppLanguageSettings.shared

    /// 选择立即持久化；不重新创建RootView或取消进行中的同步。
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("App Language", selection: $settings.selection) {
                    Text("Follow System").tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("app-language-picker")
            } footer: {
                Text("Only Remmich uses this choice. Your device language, photos, and backup settings stay unchanged.")
            }
        }
        .navigationTitle("App Language")
        .accessibilityIdentifier("app-language-settings")
    }
}
