import CoreGraphics
import Testing
@testable import Remmich

/// iPad连续拖动/窗口缩放及像素键盘操作的领域回归；不使用真机、事件伪装或网络。
@Suite("Crop interaction continuity")
struct AssetEditCropInteractionTests {
    /// 平移过程中窗口缩小的第一事件重设锚点，后续按新视口比例移动，不叠加旧屏幕位移。
    @Test func movingAcrossWindowResizePreservesCropUntilTheNextDelta() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        var crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        var gesture = AssetEditCropDragSession()
        let wide = CGRect(x: 20, y: 30, width: 500, height: 400)
        let narrow = CGRect(x: 0, y: 40, width: 250, height: 200)
        crop = gesture.updated(crop: crop, translation: .zero, imageRect: wide, source: source)
        crop = gesture.updated(crop: crop, translation: .init(width: 50, height: 25), imageRect: wide, source: source)
        #expect(crop == AssetEditPixelCrop(x: 200, y: 150, width: 400, height: 300, in: source))
        let beforeResize = crop
        crop = gesture.updated(crop: crop, translation: .init(width: 80, height: 40), imageRect: narrow, source: source)
        #expect(crop == beforeResize)
        crop = gesture.updated(crop: crop, translation: .init(width: 90, height: 50), imageRect: narrow, source: source)
        #expect(crop == AssetEditPixelCrop(x: 240, y: 190, width: 400, height: 300, in: source))
    }

    /// 四角缩放在Stage Manager尺寸变化时同样不能跳框；固定对角不变，返回到新比例继续调整。
    @Test(arguments: AssetEditPixelCrop.Corner.allCases)
    func cornerResizeReanchorsForAChangedViewport(_ corner: AssetEditPixelCrop.Corner) throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let initial = try #require(AssetEditPixelCrop(x: 200, y: 200, width: 400, height: 300, in: source))
        var crop = initial
        var gesture = AssetEditCropDragSession()
        let wide = CGRect(x: 0, y: 0, width: 500, height: 400)
        let narrow = CGRect(x: 0, y: 0, width: 250, height: 200)
        crop = gesture.updated(crop: crop, translation: .zero, imageRect: wide, source: source, corner: corner)
        crop = gesture.updated(crop: crop, translation: .init(width: 10, height: 10), imageRect: wide, source: source, corner: corner)
        #expect(crop == initial.resized(corner: corner, dx: 20, dy: 20, in: source))
        let previous = crop
        crop = gesture.updated(crop: crop, translation: .init(width: 20, height: 20), imageRect: narrow, source: source, corner: corner)
        #expect(crop == previous)
        crop = gesture.updated(crop: crop, translation: .init(width: 30, height: 30), imageRect: narrow, source: source, corner: corner)
        #expect(crop == previous.resized(corner: corner, dx: 40, dy: 40, in: source))
    }

    /// 外部Stepper/VoiceOver修改或重置后，正在结束的旧手势不能覆盖刚确认的像素值。
    @Test func externalPixelAdjustmentsAndInvalidGeometryNeverRestoreAnOldAnchor() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        var crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        var gesture = AssetEditCropDragSession()
        let rect = CGRect(x: 0, y: 0, width: 500, height: 400)
        crop = gesture.updated(crop: crop, translation: .zero, imageRect: rect, source: source)
        crop = gesture.updated(crop: crop, translation: .init(width: 50, height: 25), imageRect: rect, source: source)
        crop = .full(source)
        #expect(gesture.updated(crop: crop, translation: .init(width: 55, height: 25), imageRect: rect, source: source) == .full(source))
        gesture.reset()
        #expect(gesture.updated(crop: crop, translation: .init(width: 500, height: 500), imageRect: rect, source: source) == crop)
        #expect(gesture.updated(crop: crop, translation: .zero, imageRect: .zero, source: source) == crop)
        #expect(gesture.updated(crop: crop, translation: CGSize(width: CGFloat.nan, height: CGFloat.zero), imageRect: rect, source: source) == crop)
    }

    /// 焦点键盘操作按原图像素走一步或十步，Option只改右下边；越界输入仍停在合法范围。
    @Test func keyboardNudgesUseOriginalPixelsAndKeepResizeOriginFixed() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        #expect(AssetEditCropKeyboardDirection.left.applied(to: crop, in: source, resizing: false, accelerated: false) == AssetEditPixelCrop(x: 99, y: 100, width: 400, height: 300, in: source))
        #expect(AssetEditCropKeyboardDirection.down.applied(to: crop, in: source, resizing: false, accelerated: true) == AssetEditPixelCrop(x: 100, y: 110, width: 400, height: 300, in: source))
        #expect(AssetEditCropKeyboardDirection.left.applied(to: crop, in: source, resizing: true, accelerated: true) == AssetEditPixelCrop(x: 100, y: 100, width: 390, height: 300, in: source))
        #expect(AssetEditCropKeyboardDirection.down.applied(to: crop, in: source, resizing: true, accelerated: false) == AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 301, in: source))
        for direction in AssetEditCropKeyboardDirection.allCases {
            #expect(direction.applied(to: .full(source), in: source, resizing: false, accelerated: true) == .full(source))
        }
        let minimum = try #require(AssetEditPixelCrop(x: 0, y: 0, width: 1, height: 1, in: source))
        #expect(AssetEditCropKeyboardDirection.left.applied(to: minimum, in: source, resizing: true, accelerated: true) == minimum)
    }
}
