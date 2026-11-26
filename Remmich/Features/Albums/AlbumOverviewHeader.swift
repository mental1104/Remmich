import SwiftUI

/// 相簿总览的自适应原生控件树；只改变位置/可见性，不持有查询、scope或导航状态。
struct AlbumOverviewHeader<Search: View, Options: View>: View {
    let layout: AlbumOverviewHeaderLayout
    @Binding var scope: AlbumScope
    let fontSize: CGFloat
    let search: Search
    let options: Options

    /// layout为当前窗口/字号几何，scope为原业务绑定，fontSize为缩放字体；两个builder沿用原搜索和菜单操作。
    init(layout: AlbumOverviewHeaderLayout, scope: Binding<AlbumScope>, fontSize: CGFloat,
         @ViewBuilder search: () -> Search, @ViewBuilder options: () -> Options)
    {
        self.layout = layout
        _scope = scope
        self.fontSize = fontSize
        self.search = search()
        self.options = options()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                AlbumScopeControl(selection: $scope, fontSize: fontSize)
                    .opacity(layout.scopeUsesMenu ? 0 : 1)
                    .disabled(layout.scopeUsesMenu)
                    .allowsHitTesting(!layout.scopeUsesMenu)
                    .accessibilityHidden(layout.scopeUsesMenu)
                scopeMenu
                    .opacity(layout.scopeUsesMenu ? 1 : 0)
                    .disabled(!layout.scopeUsesMenu)
                    .allowsHitTesting(layout.scopeUsesMenu)
                    .accessibilityHidden(!layout.scopeUsesMenu)
            }
            .frame(width: layout.scopeFrame.width, height: layout.scopeFrame.height)
            .position(x: layout.scopeFrame.midX, y: layout.scopeFrame.midY)
            .opacity(layout.scopeVisible ? 1 : 0)
            .allowsHitTesting(layout.scopeVisible)
            .accessibilityHidden(!layout.scopeVisible)
            .hoverEffect(.highlight)
            search.position(x: layout.searchFrame.midX, y: layout.searchFrame.midY)
            options.position(x: layout.optionsFrame.midX, y: layout.optionsFrame.midY)
        }
        .frame(width: layout.width, height: layout.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("albums-adaptive-header")
    }

    /// 最大字号时两段文字连整行也容不下，使用原生菜单保留完整选择；隐藏分段实例不接收输入。
    private var scopeMenu: some View {
        Menu {
            Picker("Album Scope", selection: $scope) {
                ForEach(AlbumScope.allCases) { Text(L10n.string($0.rawValue)).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(L10n.string(scope.rawValue)).font(.system(size: fontSize, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 16))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Album Scope").accessibilityValue(scope.rawValue)
        .accessibilityIdentifier("albums-scope-menu")
    }
}
