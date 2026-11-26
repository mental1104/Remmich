import SwiftUI

/// 标题栏原有外边距的窄复用点；不持有状态，产品与实际UIKit容器回归共用相同修饰顺序。
struct AlbumOverviewHeaderInsets: ViewModifier {
    let windowTopInset: CGFloat

    /// content是产品标题栏；返回保留原横向默认padding、上下各8点及顶部安全留白的视图。
    func body(content: Content) -> some View {
        content
            .padding(.horizontal)
            .padding(.vertical, 8)
            .padding(.top, windowTopInset)
    }
}
