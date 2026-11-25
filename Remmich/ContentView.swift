//
//  ContentView.swift
//  Remmich
//
//  Created by Ender Wang on 9/25/26.
//

import SwiftUI

/// 正常进入账号根界面；只有DEBUG明确UI测试标记才使用无网络搜索宿主。
struct ContentView: View {
    var body: some View {
        #if DEBUG
            if SearchUIFixtureLaunch.isEnabled {
                SearchUITestHost()
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
