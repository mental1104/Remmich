//
//  ContentView.swift
//  Remmich
//
//  Created by Ender Wang on 9/25/26.
//

import SwiftUI

/// 正常进入账号根界面；只有DEBUG明确UI测试标记才使用无网络搜索宿主。
struct ContentView: View {
    @State private var language = AppLanguageSettings.shared

    /// 只更新语言环境，不以语言作为View identity，避免重建会话和同步协调器。
    var body: some View {
        localizedContent.environment(\.locale, language.locale)
    }

    @ViewBuilder private var localizedContent: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-profile") {
                ProfileNavigationUITestHost()
            } else if SearchUIFixtureLaunch.isEnabled {
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-search-presets") {
                    SavedSearchUITestHost()
                } else {
                    SearchUITestHost()
                }
            } else {
                RootView()
            }
        #else
            RootView()
        #endif
    }
}

#Preview {
    ContentView()
}
