import SwiftUI
import UIKit

/// 保留原生分段控件及其选择身份，按当前语言和缩放字号更新文字，不使用全局UIKit appearance。
struct AlbumScopeControl: UIViewRepresentable {
    @Binding var selection: AlbumScope
    let fontSize: CGFloat

    /// fontSize为当前窗口缩放后的点数；返回等宽segment所需宽度，预留每段两侧16点避免压缩标题。
    static func requiredWidth(fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let titleWidth = AlbumScope.allCases.map { (L10n.string($0.rawValue) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil((titleWidth + 32) * CGFloat(AlbumScope.allCases.count))
    }

    /// context绑定协调器；创建一次原生控件，后续尺寸/字号变化只更新属性，不替换选择或导航状态。
    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: AlbumScope.allCases.map { L10n.string($0.rawValue) })
        control.accessibilityIdentifier = "albums-scope"
        control.accessibilityLabel = L10n.string("Album Scope")
        control.addTarget(context.coordinator, action: #selector(Coordinator.selectionChanged(_:)), for: .valueChanged)
        return control
    }

    /// control为当前实例，context提供语言/binding/启用状态；按本地化标题和字体刷新，不读写服务器。
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        _ = context.environment.locale.identifier
        context.coordinator.selection = $selection
        control.accessibilityLabel = L10n.string("Album Scope")
        for (index, scope) in AlbumScope.allCases.enumerated() {
            let title = L10n.string(scope.rawValue)
            if control.titleForSegment(at: index) != title {
                control.setTitle(title, forSegmentAt: index)
                control.invalidateIntrinsicContentSize()
            }
        }
        control.selectedSegmentIndex = AlbumScope.allCases.firstIndex(of: selection) ?? 0
        control.isEnabled = context.environment.isEnabled
        if (control.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.pointSize != fontSize {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium)]
            control.setTitleTextAttributes(attributes, for: .normal)
            control.setTitleTextAttributes(attributes, for: .selected)
            control.invalidateIntrinsicContentSize()
        }
    }

    /// proposal是标题栏已分配的完整点数，uiView提供缺省intrinsic大小；返回拟合尺寸，不在桥接层硬编码44点高度。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context _: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: proposal.height ?? intrinsic.height)
    }

    /// 返回拥有当前binding的原生target-action协调器；无额外持久状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    /// 只桥接原生选择事件；原有scope动画拒绝切换时恢复真实绑定值，不绕过导航/动画边界。
    final class Coordinator: NSObject {
        var selection: Binding<AlbumScope>

        /// selection为相簿页当前scope绑定，每次SwiftUI刷新时由updateUIView替换。
        init(selection: Binding<AlbumScope>) {
            self.selection = selection
        }

        /// control提供用户选择；越界忽略，成功后以实际binding值回写选中项。
        @objc func selectionChanged(_ control: UISegmentedControl) {
            let scopes = AlbumScope.allCases
            guard scopes.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = scopes[control.selectedSegmentIndex]
            control.selectedSegmentIndex = scopes.firstIndex(of: selection.wrappedValue) ?? 0
        }
    }
}
