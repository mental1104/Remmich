import Combine
import SwiftUI
import Testing
import UIKit
@testable import Remmich

/// 相簿标题栏宽度/字号几何与实际UIKit控件回归；只使用合成标签，不读取相簿或联网。
@Suite("Adaptive album overview header")
@MainActor
struct AlbumOverviewHeaderTests {
    /// 包含窄窗口、iPhone和iPad横竖屏；由真实UIFont文字需求驱动，所有可见控件必须不碰撞且保持可触区域。
    @Test(arguments: [CGFloat(240), 288, 361, 744, 802, 992, 1162], [CGFloat(13), 20, 32, 46])
    func visibleControlsFitAtRealFontSizes(_ width: CGFloat, _ fontSize: CGFloat) {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let desired = AlbumScopeControl.requiredWidth(fontSize: fontSize)
        for expanded in [false, true] {
            let layout = AlbumOverviewHeaderLayout(availableWidth: width, scopeWidth: desired,
                                                   rowHeight: max(44, ceil(font.lineHeight + 16)), searchExpanded: expanded)
            let frames = [layout.searchFrame, layout.optionsFrame] + (layout.scopeVisible ? [layout.scopeFrame] : [])
            for frame in frames {
                #expect(frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= width + 0.001 && frame.maxY <= layout.height + 0.001)
                #expect(frame.width >= 44 && frame.height >= 44)
            }
            for first in frames.indices {
                for second in frames.indices where second > first {
                    #expect(!frames[first].intersects(frames[second]))
                }
            }
            if layout.scopeVisible, !layout.scopeUsesMenu {
                #expect(layout.scopeFrame.width >= desired)
            }
            if desired > width {
                #expect(layout.stacked && layout.scopeUsesMenu && layout.scopeVisible)
            }
        }
    }

    /// 正常窗口维持单行；只在中间不够宽时分行，搜索开关不让分行标题和滚动留白跳回单行。
    @Test func inlineStackedAndMenuLayoutsRetainSearchAndScopeAccess() {
        let wide = AlbumOverviewHeaderLayout(availableWidth: 802, scopeWidth: 146, rowHeight: 44, searchExpanded: false)
        #expect(!wide.stacked && wide.scopeVisible && !wide.scopeUsesMenu && wide.height == 44)
        let wideSearch = AlbumOverviewHeaderLayout(availableWidth: 802, scopeWidth: 146, rowHeight: 44, searchExpanded: true)
        #expect(!wideSearch.scopeVisible && wideSearch.searchFrame.width > wide.searchFrame.width)
        let narrow = AlbumOverviewHeaderLayout(availableWidth: 288, scopeWidth: 220, rowHeight: 80, searchExpanded: false)
        let narrowSearch = AlbumOverviewHeaderLayout(availableWidth: 288, scopeWidth: 220, rowHeight: 80, searchExpanded: true)
        #expect(narrow.stacked && !narrow.scopeUsesMenu && narrow.height == 172)
        #expect(narrowSearch.height == narrow.height && narrowSearch.scopeFrame == narrow.scopeFrame && narrowSearch.scopeVisible)
        let largest = AlbumOverviewHeaderLayout(availableWidth: 288, scopeWidth: 400, rowHeight: 100, searchExpanded: true)
        #expect(largest.scopeUsesMenu && largest.scopeFrame.width == 288 && largest.scopeVisible)
    }

    /// 未附加窗口的零宽或非法测量不能产生NaN/负矩形；极窄控制行使用纵向摆放而非互相覆盖。
    @Test func transientInvalidMeasurementsRemainFinite() {
        for width in [CGFloat.zero, -1, .nan, .infinity, 44, 80] {
            let layout = AlbumOverviewHeaderLayout(availableWidth: width, scopeWidth: .nan, rowHeight: .nan, searchExpanded: true)
            for frame in [layout.scopeFrame, layout.searchFrame, layout.optionsFrame] {
                #expect([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite))
                #expect(frame.minX >= 0 && frame.minY >= 0 && frame.width > 0 && frame.height > 0)
            }
            #expect(!layout.searchFrame.intersects(layout.optionsFrame))
        }
    }

    /// 挂载产品Header并改变给定内容宽度/SwiftUI字号，核原生实例、选择和缩放；不调整UIWindow，不能代替真实窗口重排验收。
    @Test func liveUIKitScopeRetainsIdentityAcrossWindowAndDynamicTypeChanges() async throws {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = AlbumHeaderFixtureState()
        let host = UIHostingController(rootView: AlbumHeaderFixtureRoot(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await waitUntil { findScope(in: host.view) != nil }
        let control = try #require(findScope(in: host.view))
        try await waitUntil { (control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize != nil && control.bounds.height >= 44 }
        let originalFont = try #require(control.titleTextAttributes(for: .normal)?[.font] as? UIFont)
        let originalHeight = control.bounds.height
        state.scope = .shared
        state.width = 288
        state.typeSize = .accessibility5
        host.view.setNeedsLayout()
        try await waitUntil {
            control.selectedSegmentIndex == 1 && control.bounds.height > originalHeight
                && ((control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize ?? 0) > originalFont.pointSize
        }
        #expect(findScope(in: host.view) === control && state.scope == .shared)
        #expect(control.bounds.height >= 44)
        state.width = 802
        state.typeSize = .large
        try await waitUntil { (control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize == originalFont.pointSize }
        #expect(findScope(in: host.view) === control && state.scope == .shared && control.selectedSegmentIndex == 1)
    }

    /// 实际原生valueChanged走原有binding；上层scope转场拒绝选择时，控件必须回到真实值而非显示未生效状态。
    @Test func nativeScopeEventRespectsRejectedSelection() {
        let state = AlbumHeaderFixtureState()
        let binding = Binding(get: { state.scope }, set: {
            if state.permitsScopeChange {
                state.scope = $0
            }
        })
        let coordinator = AlbumScopeControl.Coordinator(selection: binding)
        let control = UISegmentedControl(items: AlbumScope.allCases.map(\.rawValue))
        control.addTarget(coordinator, action: #selector(AlbumScopeControl.Coordinator.selectionChanged(_:)), for: .valueChanged)
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        #expect(state.scope == .all && control.selectedSegmentIndex == 0)
        state.permitsScopeChange = true
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        #expect(state.scope == .shared && control.selectedSegmentIndex == 1)
        control.selectedSegmentIndex = UISegmentedControl.noSegment
        control.sendActions(for: .valueChanged)
        #expect(state.scope == .shared)
    }

    /// UIKit附加需要异步布局；有界等待只观察真实控件状态，失败抛错而非无限等待。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Album header did not reach its expected UIKit layout")
    }

    /// 从实际UIKit树找到产品UISegmentedControl，不使用演示截图或替代控件。
    private func findScope(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl {
            return control
        }
        for child in view.subviews {
            if let result = findScope(in: child) {
                return result
            }
        }
        return nil
    }
}

/// 仅供宿主测试注入内容宽度/字体/选择；没有服务端、身份或媒体状态，也不驱动真实UIWindow尺寸。
@MainActor
private final class AlbumHeaderFixtureState: ObservableObject {
    @Published var width: CGFloat = 802
    @Published var typeSize: DynamicTypeSize = .large
    @Published var scope: AlbumScope = .all
    var permitsScopeChange = false
}

/// 把字号环境放在产品Header外侧，确保@ScaledMetric来自真实SwiftUI环境更新。
private struct AlbumHeaderFixtureRoot: View {
    @ObservedObject var state: AlbumHeaderFixtureState
    var body: some View {
        AlbumHeaderFixtureHost(state: state).environment(\.dynamicTypeSize, state.typeSize)
    }
}

/// 独立原生宿主只提供合成搜索/菜单按钮；分段/菜单fallback和位置布局均直接使用产品Header。
private struct AlbumHeaderFixtureHost: View {
    @ObservedObject var state: AlbumHeaderFixtureState
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 24
    var body: some View {
        let layout = AlbumOverviewHeaderLayout(availableWidth: state.width, fontSize: fontSize, textHeight: textHeight, searchExpanded: false)
        AlbumOverviewHeader(layout: layout, scope: $state.scope, fontSize: fontSize) {
            Button("Search") {}.frame(width: layout.searchFrame.width, height: layout.searchFrame.height)
        } options: {
            Button("Options") {}.frame(width: layout.optionsFrame.width, height: layout.optionsFrame.height)
        }
    }
}
