import SwiftUI
import UIKit

/// 在未编辑原图的aspect-fit区域内交互裁剪；屏幕留白不参与像素换算，旋转/镜像显示在旁边结果预览。
struct AssetEditCropCanvas: View {
    let image: UIImage
    let sourceSize: AssetEditPixelSize
    @Binding var crop: AssetEditPixelCrop
    let focusRequest: Int
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var dragSession = AssetEditCropDragSession()
    @State private var pinchSession = AssetEditCropMagnificationSession()
    @GestureState private var isPinching = false
    @FocusState private var cropFocused: Bool

    /// image/sourceSize/crop沿用原图像素契约；focusRequest每次明确键盘聚焦意愿递增，缺省0保留旧调用。
    init(image: UIImage, sourceSize: AssetEditPixelSize, crop: Binding<AssetEditPixelCrop>, focusRequest: Int = 0) {
        self.image = image; self.sourceSize = sourceSize; _crop = crop; self.focusRequest = focusRequest
    }

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
                    .simultaneousGesture(magnificationGesture(in: rect))
                    .onTapGesture {
                        guard isEnabled, scenePhase == .active else { return }
                        cropFocused = true
                    }
                    .hoverEffect(.highlight)
                    .focusable().focused($cropFocused)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { keyPress($0) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("裁剪范围")
                    .accessibilityValue("X \(crop.x)，Y \(crop.y)，宽 \(crop.width)，高 \(crop.height) 像素")
                    .accessibilityHint("上下调整缩放范围，更多操作可按像素移动，或使用精确像素调整。")
                    .accessibilityAdjustableAction { direction in
                        guard isEnabled, scenePhase == .active else { return }
                        dragSession.reset(); pinchSession.reset()
                        switch direction {
                        case .increment: crop = crop.magnified(by: 1.05, in: sourceSize)
                        case .decrement: crop = crop.magnified(by: 1 / 1.05, in: sourceSize)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: Text("向左移动一像素")) { nudge(.left) }
                    .accessibilityAction(named: Text("向右移动一像素")) { nudge(.right) }
                    .accessibilityAction(named: Text("向上移动一像素")) { nudge(.up) }
                    .accessibilityAction(named: Text("向下移动一像素")) { nudge(.down) }
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
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            // 保留正在捏合的累积倍率锚点，由下一实际事件按新rect重锚，不能再乘整轮倍率。
            .onChange(of: geometry.size) { _, _ in dragSession.reset() }
            .onChange(of: focusRequest) { _, _ in
                // 焦点只属于当前可操作的前台裁剪页；旧请求不抢确认框、后台或账号失效后的焦点。
                guard isEnabled, scenePhase == .active else { return }
                cropFocused = true
            }
            .onChange(of: isPinching) { _, active in
                if !active {
                    pinchSession.reset(); dragSession.reset()
                }
            }
            .onDisappear { pinchSession.reset(); dragSession.reset() }
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
                guard isEnabled, scenePhase == .active, imageRect.width > 0, imageRect.height > 0 else { return }
                // 双指捏合期间暂停平移；恢复时重新记录位移起点，避免松开一根手指后跳框。
                guard !pinchSession.isActive, !isPinching else { dragSession.reset(); return }
                crop = dragSession.updated(crop: crop, translation: value.translation, imageRect: imageRect, source: sourceSize)
            }
            .onEnded { _ in dragSession.reset() }
    }

    /// corner固定本次移动角，imageRect负责点数到像素换算；对角保持不动，松手后清除手势快照。
    private func resizeGesture(corner: AssetEditPixelCrop.Corner, in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, scenePhase == .active, imageRect.width > 0, imageRect.height > 0 else { return }
                guard !pinchSession.isActive, !isPinching else { dragSession.reset(); return }
                crop = dragSession.updated(crop: crop, translation: value.translation, imageRect: imageRect, source: sourceSize, corner: corner)
            }
            .onEnded { _ in dragSession.reset() }
    }

    /// imageRect为当前真实视口；整轮累计倍率交给同一像素session，换窗后只消费重锚之后的倍率比。
    /// GestureState在系统取消时同样退休，避免失去onEnded后留下阻止后续单指平移的旧锚点。
    private func magnificationGesture(in imageRect: CGRect) -> some Gesture {
        MagnificationGesture()
            .updating($isPinching) { _, active, _ in active = true }
            .onChanged { value in
                guard isEnabled, scenePhase == .active else { return }
                dragSession.reset()
                crop = pinchSession.updated(crop: crop, magnification: Double(value), imageRect: imageRect, source: sourceSize)
            }
            .onEnded { _ in pinchSession.reset(); dragSession.reset() }
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

    /// key只在裁剪框取得硬件焦点后进入；Cmd/Control交给其余界面，Shift为10像素，Option调整右下边。
    /// iPad使用onKeyPress，Apple的onMoveCommand当前仅支持macOS/tvOS，不能拿它假装iPad键盘可用。
    private func keyPress(_ key: KeyPress) -> KeyPress.Result {
        guard isEnabled, scenePhase == .active, !key.modifiers.contains(.command), !key.modifiers.contains(.control) else { return .ignored }
        let direction: AssetEditCropKeyboardDirection
        switch key.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }
        dragSession.reset(); pinchSession.reset()
        crop = direction.applied(to: crop, in: sourceSize, resizing: key.modifiers.contains(.option), accelerated: key.modifiers.contains(.shift))
        return .handled
    }

    /// direction为VoiceOver的一像素移动意图；重设在途手势锚点，避免下一事件覆盖辅助功能调整。
    private func nudge(_ direction: AssetEditCropKeyboardDirection) {
        guard isEnabled, scenePhase == .active else { return }
        dragSession.reset(); pinchSession.reset()
        crop = direction.applied(to: crop, in: sourceSize, resizing: false, accelerated: false)
    }
}
