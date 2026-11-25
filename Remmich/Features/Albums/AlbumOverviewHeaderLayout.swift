import CoreGraphics
import UIKit

/// 相簿总览标题栏的点坐标；按可用窗口宽度与实际文字需求分行，和卡片布局/相簿身份保持独立。
nonisolated struct AlbumOverviewHeaderLayout: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat
    let scopeFrame: CGRect
    let searchFrame: CGRect
    let optionsFrame: CGRect
    let scopeVisible: Bool
    let stacked: Bool
    let scopeUsesMenu: Bool

    /// availableWidth为当前内容点宽，fontSize/textHeight来自真实SwiftUI缩放；复用产品实测文字与同一行高，不缓存容器尺寸。
    @MainActor init(availableWidth: CGFloat, fontSize: CGFloat, textHeight: CGFloat, searchExpanded: Bool) {
        self.init(availableWidth: availableWidth, scopeWidth: AlbumScopeControl.requiredWidth(fontSize: fontSize),
                  rowHeight: Self.controlRowHeight(fontSize: fontSize, textHeight: textHeight), searchExpanded: searchExpanded)
    }

    /// fontSize为当前scope字号，textHeight为搜索正文缩放高度，单位均为点；返回至少44点且容纳文字的控件行高。
    @MainActor static func controlRowHeight(fontSize: CGFloat, textHeight: CGFloat) -> CGFloat {
        max(44, max(textHeight + 12, ceil(UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight + 16)))
    }

    /// windowTopInset为当前宿主顶部安全留白；返回与AlbumOverviewHeaderInsets实际上下padding一致的内容顶部留白。
    func contentTopClearance(windowTopInset: CGFloat) -> CGFloat {
        windowTopInset + height + 16
    }

    /// availableWidth为扣除外侧padding的点数，scopeWidth为当前字号两段文字所需宽度，rowHeight为完整文字行高度。
    /// searchExpanded仅控制搜索宽度；分行时保留独立scope行，避免开关搜索重排滚动留白。
    init(availableWidth: CGFloat, scopeWidth: CGFloat, rowHeight: CGFloat, searchExpanded: Bool) {
        let width = availableWidth.isFinite ? max(1, availableWidth) : 1
        let row = rowHeight.isFinite ? max(44, rowHeight) : 44
        let desiredScope = scopeWidth.isFinite ? max(0, scopeWidth) : width
        let controlWidth = min(44, width)
        let spacing: CGFloat = 12
        let controlsVertical = width < controlWidth * 2 + spacing
        let centerWidth = max(0, width - 2 * (controlWidth + spacing))
        let stacked = controlsVertical || desiredScope > centerWidth
        let controlsY: CGFloat = stacked ? row + spacing : 0
        let optionsY = controlsVertical ? controlsY + row + spacing : controlsY
        self.width = width
        height = optionsY + row
        self.stacked = stacked
        scopeUsesMenu = desiredScope > width
        scopeVisible = stacked || !searchExpanded
        scopeFrame = CGRect(x: stacked ? 0 : controlWidth + spacing, y: 0,
                            width: stacked ? width : centerWidth, height: row)
        searchFrame = CGRect(x: 0, y: controlsY,
                             width: searchExpanded ? (controlsVertical ? width : max(controlWidth, width - controlWidth - spacing)) : controlWidth,
                             height: row)
        optionsFrame = CGRect(x: width - controlWidth, y: optionsY, width: controlWidth, height: row)
    }
}
