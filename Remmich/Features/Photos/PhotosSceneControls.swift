import SwiftUI

/// 只修改主Photos外层展示的原生菜单；错误/缺扩展可随时关闭并回到原始顺序，没有分组写操作。
struct PhotosSceneControl: View {
    let state: PhotosSceneState
    let reload: () -> Void

    var body: some View {
        Menu {
            Toggle("Scene grouping", isOn: Binding(get: { state.enabled }, set: state.setEnabled))
            Text(state.status)
            Button("Reload scene evidence", action: reload).disabled(!state.enabled || state.checking)
        } label: {
            Image(systemName: state.enabled ? "rectangle.stack.fill" : "rectangle.stack")
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottomTrailing) {
                    if state.checking {
                        ProgressView().controlSize(.mini).padding(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if state.hasFailure {
                        Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Scene grouping").accessibilityValue(state.status)
        .accessibilityIdentifier("photos-scene-groups-control")
    }
}

/// 封面徽标是单独可点击的展开/收起按钮，不复用删除/堆叠管理操作或改变单张asset身份。
struct TimelineSceneBadge: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label("\(count)", systemImage: expanded ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.plus")
                .font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(expanded ? "Collapse scene group" : "Expand scene group"))
        .accessibilityValue("\(count) photos")
    }
}

/// 独立ViewModifier限制现有大缩略图表达式的推断范围，日期徽标与封面按钮遵循相同返回动画隐藏边界。
struct TimelineSceneDecoration: ViewModifier {
    let group: ResolvedTimelineScenes.Group?
    let originalDate: Date?
    let hidden: Bool
    let toggle: () -> Void

    /// content仍是原照片单元，group/date只提供展示覆盖物，hidden阻止透明封面按钮接收点击。
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let group {
                    TimelineSceneBadge(count: group.count, expanded: group.expanded, toggle: toggle)
                        .padding(3).opacity(hidden ? 0 : 1).allowsHitTesting(!hidden)
                }
            }
            .overlay(alignment: .topLeading) {
                if let originalDate {
                    Text(TimelineCaptureDateFormatting.string(from: originalDate, dateStyle: .short, timeStyle: .none))
                        .font(.caption2).padding(3).background(.ultraThinMaterial, in: .capsule).padding(3)
                        .allowsHitTesting(false).opacity(hidden ? 0 : 1)
                }
            }
    }
}
