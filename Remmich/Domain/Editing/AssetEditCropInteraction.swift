import CoreGraphics

/// 一次裁剪拖动的像素锚点；窗口、来源或外部调整变化时重设起点，不累计旧布局的屏幕位移。
nonisolated struct AssetEditCropDragSession {
    /// 固定某轮手势的像素区域和屏幕基准；corner为nil表示移动，否则固定对应对角。
    private struct Anchor {
        let crop: AssetEditPixelCrop
        let translation: CGSize
        let imageRect: CGRect
        let source: AssetEditPixelSize
        let corner: AssetEditPixelCrop.Corner?
    }

    private var anchor: Anchor?
    private var latest: AssetEditPixelCrop?

    /// 清除本轮快照；松手、捏合、键盘/VoiceOver操作和窗口变化后都不复用旧的屏幕坐标。
    mutating func reset() {
        anchor = nil; latest = nil
    }

    /// crop为当前像素值，translation为整轮手势点数，imageRect为完整原图aspect-fit区域，source为原图尺寸。
    /// corner缺省移动整个框；返回合法像素区域。几何/来源/外部值变化的第一事件只建立新锚点，不跳框。
    mutating func updated(crop: AssetEditPixelCrop, translation: CGSize, imageRect: CGRect, source: AssetEditPixelSize,
                          corner: AssetEditPixelCrop.Corner? = nil) -> AssetEditPixelCrop
    {
        guard imageRect.width > 0, imageRect.height > 0,
              translation.width.isFinite, translation.height.isFinite else { return crop }
        guard let anchor, anchor.imageRect == imageRect, anchor.source == source, anchor.corner == corner, latest == crop else {
            anchor = Anchor(crop: crop, translation: translation, imageRect: imageRect, source: source, corner: corner)
            latest = crop
            return crop
        }
        let dx = Double((translation.width - anchor.translation.width) / imageRect.width) * Double(source.width)
        let dy = Double((translation.height - anchor.translation.height) / imageRect.height) * Double(source.height)
        let result = if let corner {
            anchor.crop.resized(corner: corner, dx: dx, dy: dy, in: source)
        } else {
            anchor.crop.translated(dx: dx, dy: dy, in: source)
        }
        latest = result
        return result
    }
}

/// 裁剪焦点的硬件键盘方向，与屏幕点数和横竖屏无关；一像素/十像素操作使用同一领域边界校验。
nonisolated enum AssetEditCropKeyboardDirection: CaseIterable {
    case left, right, up, down

    /// crop/source为当前原图像素范围；resizing移动右下边而非整个框，accelerated把步长从1改为10像素。
    /// 返回约束后的区域，不允许越界或零面积，等价手势与辅助功能操作共享同一约束。
    func applied(to crop: AssetEditPixelCrop, in source: AssetEditPixelSize, resizing: Bool, accelerated: Bool) -> AssetEditPixelCrop {
        let step: Double = accelerated ? 10 : 1
        let dx: Double = switch self { case .left: -step; case .right: step; case .up, .down: 0 }
        let dy: Double = switch self { case .up: -step; case .down: step; case .left, .right: 0 }
        return resizing
            ? crop.resized(corner: .bottomRight, dx: dx, dy: dy, in: source)
            : crop.translated(dx: dx, dy: dy, in: source)
    }
}
