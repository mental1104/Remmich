#if DEBUG
    import SwiftUI

    /// 显式DEBUG入口只验证真实底栏、图库容器和“我的”页面；媒体内容为合成文本，不访问账号或网络。
    struct ProfileNavigationUITestHost: View {
        @State private var navigation = NativeTabSelectionState()
        @State private var activation = NativeTabContentActivationState()
        @State private var rotation = TimelineRotationState()
        @State private var tabBarTop: CGFloat = 0
        @State private var librarySection: NativeTabDestination = .albums
        @State private var language = AppLanguageSettings.shared
        @State private var index = LibraryIndexController(source: PreviewTimelineReader())

        /// 宿主使用生产UIKit标签和MyView；无测试标记时ContentView永远不会进入这里。
        var body: some View {
            @Bindable var navigation = navigation
            NativeAppTabShell(
                selection: $navigation.selection, tabBarTop: $tabBarTop, rotationState: rotation,
                contentActivationState: activation, compactOwner: nil, isViewerPresented: false, pageSwipeEnabled: false,
                photosScrollRequest: 0, videosScrollRequest: 0, groupedScrollRequests: [:], groupedMediaOwner: .photos,
                languageCode: language.selection.resolvedCode(), librarySection: librarySection,
                selectLibrarySection: { librarySection = $0; navigation.selection = $0 },
                libraryContentRevision: .restoring,
                photosRetapped: {}, videosRetapped: {}, libraryRetapped: {}, groupedTabRetapped: { _ in },
                account: AnyView(NavigationStack {
                    MyView(session: .fixture, profile: .init(), activeRoute: nil, routeStatus: .connected,
                           libraryIndex: index, saveProfile: { _ in .saved(profile: .init()) }, signOut: { _ in }, sessionController: nil)
                }),
                photos: AnyView(Text("Photos").accessibilityIdentifier("profile-fixture-photos")),
                videos: AnyView(Text("Videos").accessibilityIdentifier("profile-fixture-videos")),
                albums: AnyView(Text("Albums").accessibilityIdentifier("profile-fixture-albums")),
                library: AnyView(Text("Collections").accessibilityIdentifier("profile-fixture-collections")),
                years: AnyView(EmptyView()), months: AnyView(EmptyView()), weeks: AnyView(EmptyView()), search: AnyView(Text("Search"))
            )
            .ignoresSafeArea()
            .task {
                // 只在明确测试宿主中设置应用偏好；不读取生产账户或重写设备语言。
                if let code = ProcessInfo.processInfo.environment["REMMICH_UI_TEST_LANGUAGE"], let selected = AppLanguage(rawValue: code) {
                    language.selection = selected
                }
            }
        }
    }
#endif
