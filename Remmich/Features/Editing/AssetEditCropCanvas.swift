import SwiftUI
import UIKit

/// 在未编辑原图的aspect-fit区域内交互裁剪；屏幕留白不参与像素换算，旋转/镜像显示在旁边结果预览。
struct AssetEditCropCanvas: View {
    let image: UIImage
    let sourceSize: AssetEditPixelSize
    @Binding var crop: AssetEditPixelCrop
    @State private var dragStart: AssetEditPixelCrop?
    @State private var dragOrigin = CGSize.zero
    @State private var pinchStart: AssetEditPixelCrop?

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.imageRect(sourceSize, in: geometry.size)
            let selected = crop.displayRect(in: rect, source: sourceSize)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.9)
                Image(uiImage: image).resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityHidden(true)
                Path { path in
                    path.addRect(rect)
                    path.addRect(selected)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().stroke(.white, lineWidth: 2)
                    .frame(width: selected.width, height: selected.height)
                    .position(x: selected.midX, y: selected.midY)
                    .allowsHitTesting(false)
                grid(in: selected)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: selected.width, height: selected.height)
                    .position(x: selected.midX, y: selected.midY)
                    .gesture(moveGesture(in: rect))
                    .simultaneousGesture(magnificationGesture())
                    .accessibilityLabel("Crop selection")
                    .accessibilityIdentifier("asset-editor-crop-selection")
                ForEach(AssetEditPixelCrop.Corner.allCases, id: \.self) { corner in
                    let point = cornerPoint(corner, in: selected)
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(point)
                        .gesture(resizeGesture(corner: corner, in: rect))
                        .hoverEffect(.highlight)
                        .accessibilityLabel(cornerLabel(corner))
                }
            }
            .clipped()
            .onChange(of: geometry.size) { _, _ in dragStart = nil; pinchStart = nil; dragOrigin = .zero }
        }
        .accessibilityIdentifier("asset-editor-crop-canvas")
    }

    /// size为原图尺寸，viewport为当前可用点数；返回居中aspect-fit区域，iPad尺寸变化不改变像素草稿。
    static func imageRect(_ size: AssetEditPixelSize, in viewport: CGSize) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / CGFloat(size.width), viewport.height / CGFloat(size.height))
        let fitted = CGSize(width: CGFloat(size.width) * scale, height: CGFloat(size.height) * scale)
        return CGRect(x: (viewport.width - fitted.width) / 2, y: (viewport.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// rect为当前选框；三分线只供取景，不拦截手势或改变像素边界。
    private func grid(in rect: CGRect) -> some View {
        Path { path in
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                let x = rect.minX + rect.width * fraction
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }.stroke(.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false)
    }

    /// imageRect是本轮可见原图区域；将从手势起点算起的位移换算为像素，避免逐事件累计漂移。
    private func moveGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                // 双指捏合期间暂停平移；恢复时重新记录位移起点，避免松开一根手指后跳框。
                guard pinchStart == nil else { dragStart = nil; dragOrigin = value.translation; return }
                if dragStart == nil {
                    dragStart = crop; dragOrigin = value.translation
                }
                guard let dragStart else { return }
                crop = dragStart.translated(dx: Double((value.translation.width - dragOrigin.width) / imageRect.width) * Double(sourceSize.width),
                                            dy: Double((value.translation.height - dragOrigin.height) / imageRect.height) * Double(sourceSize.height), in: sourceSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// corner固定本次移动角，imageRect负责点数到像素换算；对角保持不动，松手后清除手势快照。
    private func resizeGesture(corner: AssetEditPixelCrop.Corner, in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                if dragStart == nil {
                    dragStart = crop
                }
                guard let dragStart else { return }
                crop = dragStart.resized(corner: corner,
                                         dx: Double(value.translation.width / imageRect.width) * Double(sourceSize.width),
                                         dy: Double(value.translation.height / imageRect.height) * Double(sourceSize.height), in: sourceSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// 捏合倍率只作用于当前草稿区域；不放大下载分辨率，也不改变旋转/镜像状态。
    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = crop; dragStart = nil
                }
                guard let pinchStart else { return }
                crop = pinchStart.magnified(by: Double(value), in: sourceSize)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// corner选择对应选框角；返回Canvas点坐标，角柄本身保持44点可交互区域。
    private func cornerPoint(_ corner: AssetEditPixelCrop.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// 返回角柄无障碍名称；精确像素输入同时提供不依赖拖拽的替代操作。
    private func cornerLabel(_ corner: AssetEditPixelCrop.Corner) -> String {
        switch corner {
        case .topLeft: "Resize top left crop corner"
        case .topRight: "Resize top right crop corner"
        case .bottomLeft: "Resize bottom left crop corner"
        case .bottomRight: "Resize bottom right crop corner"
        }
    }
}
