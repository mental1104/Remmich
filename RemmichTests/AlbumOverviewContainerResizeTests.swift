import Observation
import SwiftUI
import Testing
import UIKit
@testable import Remmich

/// 在非主UIWindow中真实调整宿主与AutoLayout，再观察产品Header；没有注入假窗口宽度或使用照片/账号。
@Suite("Album header UIKit container resize")
@MainActor
struct AlbumOverviewContainerResizeTests {
    /// initiallyShared只决定初始选择；宽→窄大字→横向→原宽均须保留同一原生实例、合成查询和选择。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func actualContainerAndTraitsPreserveHeaderState(_ initiallyShared: Bool) async throws {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first { $0.isKeyWindow }
        let state = AlbumResizeState(scope: initiallyShared ? .shared : .all)
        let fixture = AlbumResizeWindow(scene: scene, state: state)
        defer { fixture.close() }

        fixture.resize(to: CGSize(width: 1000, height: 700), horizontal: .regular, category: .large)
        try await waitUntil {
            fixture.hasSettled(width: 1000, category: .large)
                && (findScope(in: fixture.host.view)?.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize == state.fontSize
        }
        let control = try #require(findScope(in: fixture.host.view))
        let originalFont = try #require(control.titleTextAttributes(for: .normal)?[.font] as? UIFont)
        try assertMeasuredHeader(fixture, control: control, originalKeyWindow: originalKeyWindow)
        #expect(state.layout?.stacked == false)
        let originalHeight = try #require(state.headerFrame).height

        // 改真实UIWindow尺寸及宿主traits；state不含width，GeometryReader必须从AutoLayout后的实际bounds读取。
        fixture.resize(to: CGSize(width: 320, height: 640), horizontal: .compact, category: .accessibilityLarge)
        try await waitUntil {
            fixture.hasSettled(width: 320, category: .accessibilityLarge)
                && state.layout?.stacked == true && (state.headerFrame?.height ?? 0) > originalHeight
                && ((control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize ?? 0) > originalFont.pointSize
        }
        #expect(fixture.host.traitCollection.horizontalSizeClass == .compact)
        #expect(((control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize ?? 0) > originalFont.pointSize)
        try assertMeasuredHeader(fixture, control: control, originalKeyWindow: originalKeyWindow)

        // 搜索展开只改变原Header参数，不重建宿主或替换原生分段；分行时仍能看到scope和搜索入口。
        state.searchExpanded = true
        try await waitUntil {
            (state.layout?.searchFrame.width ?? 0) > 44 && state.layout?.scopeVisible == true
                && abs((state.searchFrame?.width ?? 0) - (state.layout?.searchFrame.width ?? 0)) < 1
        }
        try assertMeasuredHeader(fixture, control: control, originalKeyWindow: originalKeyWindow)
        state.searchExpanded = false

        fixture.resize(to: CGSize(width: 900, height: 480), horizontal: .regular, category: .large)
        try await waitUntil { fixture.hasSettled(width: 900, category: .large) && state.layout?.stacked == false }
        try assertMeasuredHeader(fixture, control: control, originalKeyWindow: originalKeyWindow)
        fixture.resize(to: CGSize(width: 1000, height: 700), horizontal: .regular, category: .large)
        try await waitUntil {
            fixture.hasSettled(width: 1000, category: .large)
                && (control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize == originalFont.pointSize
        }
        try assertMeasuredHeader(fixture, control: control, originalKeyWindow: originalKeyWindow)
        #expect(state.headerFrame?.height == originalHeight)
        #expect(state.query == "Synthetic holiday" && state.scope == (initiallyShared ? .shared : .all))
        fixture.close()
        #expect(fixture.window.isHidden && fixture.window.rootViewController == nil && fixture.host.parent == nil)
        #expect(scene.windows.first { $0.isKeyWindow } === originalKeyWindow)
    }

    /// fixture为实际窗口，control为第一次挂载的实例；核布局后真实frame、可见边界与产品clearance，绝不只比几何算法返回值。
    private func assertMeasuredHeader(_ fixture: AlbumResizeWindow, control: UISegmentedControl, originalKeyWindow: UIWindow?) throws {
        let state = fixture.state
        let header = try #require(state.headerFrame)
        let search = try #require(state.searchFrame)
        let options = try #require(state.optionsFrame)
        let layout = try #require(state.layout)
        let bounds = fixture.host.view.bounds
        #expect(findScope(in: fixture.host.view) === control)
        #expect(control.window === fixture.window && !fixture.window.isKeyWindow)
        #expect(fixture.window.windowScene?.windows.first { $0.isKeyWindow } === originalKeyWindow)
        #expect(abs(bounds.width - state.viewport.width) < 1)
        #expect(abs(header.width - bounds.width) < 1 && abs(header.minX) < 1 && abs(header.minY) < 1)
        // 产品内容clearance必须覆盖真实padding后的标题总高；此项不宣称已驱动完整AlbumsView滚动/转场。
        #expect(abs(state.contentClearance - header.height) < 1)
        for frame in [search, options] {
            #expect(frame.width >= 43.5 && frame.height >= 43.5)
            #expect(header.insetBy(dx: -0.5, dy: -0.5).contains(frame))
            #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        }
        #expect(!search.intersects(options))
        if layout.scopeVisible, !layout.scopeUsesMenu {
            let scope = control.convert(control.bounds, to: fixture.host.view)
            #expect(scope.height >= 43.5 && scope.width >= AlbumScopeControl.requiredWidth(fontSize: state.fontSize) - 0.5)
            #expect(header.insetBy(dx: -0.5, dy: -0.5).contains(scope))
            #expect(!scope.intersects(search) && !scope.intersects(options))
        }
        #expect(control.selectedSegmentIndex == (state.scope == .all ? 0 : 1))
        #expect(state.query == "Synthetic holiday")
    }

    /// condition只观察真实布局/trait回调，有限等待仍失败就让测试失败，不用超时冒充布局完成。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Actual album container layout did not settle")
    }

    /// view来自真实UIHostingController；只寻找产品UISegmentedControl，不创建替代控件或改其frame。
    private func findScope(in view: UIView) -> UISegmentedControl? {
        if let scope = view as? UISegmentedControl {
            return scope
        }
        for child in view.subviews {
            if let scope = findScope(in: child) {
                return scope
            }
        }
        return nil
    }
}

/// 测试拥有的有限窗口资源；从不makeKey，移除时断开child/root引用，不触正常窗口或scene生命周期。
@MainActor
private final class AlbumResizeWindow {
    let state: AlbumResizeState
    let window: UIWindow
    let container: UIViewController
    let host: UIHostingController<AlbumResizeRoot>

    /// scene只用于附加原生层级，state仅含合成输入；hosting视图四边约束到真实父view，不另传内容宽度。
    init(scene: UIWindowScene, state: AlbumResizeState) {
        self.state = state
        window = UIWindow(windowScene: scene)
        container = UIViewController()
        host = UIHostingController(rootView: AlbumResizeRoot(state: state))
        window.windowLevel = .init(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.rootViewController = container
        container.loadViewIfNeeded()
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        host.didMove(toParent: container)
        window.isHidden = false
    }

    /// size改变真实UIWindow bounds，horizontal/category通过公开UIKit traits传播到SwiftUI；不注入width或dynamicTypeSize环境。
    func resize(to size: CGSize, horizontal: UIUserInterfaceSizeClass, category: UIContentSizeCategory) {
        window.frame = CGRect(origin: .zero, size: size)
        container.traitOverrides.horizontalSizeClass = horizontal
        container.traitOverrides.preferredContentSizeCategory = category
        container.updateTraitsIfNeeded()
        window.setNeedsLayout(); window.layoutIfNeeded()
        container.view.setNeedsLayout(); container.view.layoutIfNeeded()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    }

    /// width是本轮独立预期，category是实际UIKit偏好；同时等真实host/GeometryReader/字号回执，避免旧快照通过。
    func hasSettled(width: CGFloat, category: UIContentSizeCategory) -> Bool {
        guard let header = state.headerFrame, let layout = state.layout,
              let search = state.searchFrame, let options = state.optionsFrame else { return false }
        return abs(host.view.bounds.width - width) < 1 && abs(state.viewport.width - width) < 1
            && abs(header.width - width) < 1 && abs(layout.width - AlbumReflowMetrics.overview(availableWidth: width).width) < 1
            && host.traitCollection.preferredContentSizeCategory == category
            && abs(search.width - layout.searchFrame.width) < 1 && abs(options.height - layout.optionsFrame.height) < 1
            && abs(header.height - state.contentClearance) < 1 && header.contains(search) && header.contains(options)
    }

    /// 清理仅本实例且可重复调用，不使普通key window重新激活，也不发送全局旋转或scene请求。
    func close() {
        guard window.rootViewController != nil else { return }
        window.isHidden = true
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        window.rootViewController = nil
    }
}

/// 只保存合成输入和观察结果；没有可供测试注入的width，所有frame只由实际GeometryReader回调写入。
@MainActor @Observable
private final class AlbumResizeState {
    var scope: AlbumScope
    var query = "Synthetic holiday"
    var searchExpanded = false
    @ObservationIgnored var viewport: CGSize = .zero
    @ObservationIgnored var headerFrame: CGRect?
    @ObservationIgnored var searchFrame: CGRect?
    @ObservationIgnored var optionsFrame: CGRect?
    @ObservationIgnored var layout: AlbumOverviewHeaderLayout?
    @ObservationIgnored var fontSize: CGFloat = 0
    @ObservationIgnored var contentClearance: CGFloat = 0

    /// scope为原生binding初值，没有账号或相簿网络依赖。
    init(scope: AlbumScope) {
        self.scope = scope
    }
}

/// 真宿主使用产品metrics/Header/insets；两个纯合成入口只承接Header布局，不复制其分行算法。
private struct AlbumResizeRoot: View {
    @Bindable var state: AlbumResizeState
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 24
    private let topInset: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumReflowMetrics.overview(availableWidth: geometry.size.width)
            let layout = AlbumOverviewHeaderLayout(availableWidth: metrics.width, fontSize: fontSize,
                                                   textHeight: textHeight, searchExpanded: state.searchExpanded)
            VStack {
                AlbumOverviewHeader(layout: layout, scope: $state.scope, fontSize: fontSize) {
                    Button("Search") { state.searchExpanded.toggle() }
                        .frame(width: layout.searchFrame.width, height: layout.searchFrame.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("album-resize-container")) } action: { state.searchFrame = $0 }
                } options: {
                    Button("Options") {}
                        .frame(width: layout.optionsFrame.width, height: layout.optionsFrame.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("album-resize-container")) } action: { state.optionsFrame = $0 }
                }
                .modifier(AlbumOverviewHeaderInsets(windowTopInset: topInset))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("album-resize-container")) } action: { state.headerFrame = $0 }
                .onChange(of: layout, initial: true) { _, value in
                    state.layout = value; state.fontSize = fontSize
                    state.contentClearance = layout.contentTopClearance(windowTopInset: topInset)
                }
                Text(state.query).accessibilityIdentifier("synthetic-album-query")
                Spacer(minLength: 0)
            }
        }
        .coordinateSpace(name: "album-resize-container")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { state.viewport = $0 }
        .ignoresSafeArea()
    }
}
