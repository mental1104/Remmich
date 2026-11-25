import CoreGraphics
import Testing
@testable import Remmich

/// 产品Canvas实际使用的累积捏合状态机；只核原图像素语义，不声称已模拟硬件捏合或窗口体验。
@Suite("Crop magnification continuity")
struct AssetEditMagnificationTests {
    /// 捏合1.25已得到320宽后改变视口，首事件不再乘1.30，后续只按1.625/1.30缩放。
    @Test func viewportChangeDoesNotApplyTheCumulativeScaleTwice() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        var crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        var pinch = AssetEditCropMagnificationSession()
        let wide = CGRect(x: 20, y: 30, width: 500, height: 400)
        let narrow = CGRect(x: 0, y: 40, width: 250, height: 200)
        crop = pinch.updated(crop: crop, magnification: 1, imageRect: wide, source: source)
        crop = pinch.updated(crop: crop, magnification: 1.25, imageRect: wide, source: source)
        #expect(crop == AssetEditPixelCrop(x: 140, y: 130, width: 320, height: 240, in: source))
        let beforeResize = crop
        crop = pinch.updated(crop: crop, magnification: 1.30, imageRect: narrow, source: source)
        #expect(crop == beforeResize && pinch.isActive)
        crop = pinch.updated(crop: crop, magnification: 1.625, imageRect: narrow, source: source)
        #expect(crop == AssetEditPixelCrop(x: 172, y: 154, width: 256, height: 192, in: source))
    }

    /// 精确像素/辅助操作修改或取消后，旧累积值只能建立新锚点，不能恢复旧框或再乘整轮倍率。
    @Test func externalChangesAndCancellationRetireTheOldAnchor() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let rect = CGRect(x: 0, y: 0, width: 500, height: 400)
        var crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        var pinch = AssetEditCropMagnificationSession()
        crop = pinch.updated(crop: crop, magnification: 1, imageRect: rect, source: source)
        crop = pinch.updated(crop: crop, magnification: 1.25, imageRect: rect, source: source)
        crop = try #require(AssetEditPixelCrop(x: 20, y: 30, width: 500, height: 400, in: source))
        let external = crop
        crop = pinch.updated(crop: crop, magnification: 1.30, imageRect: rect, source: source)
        #expect(crop == external)
        crop = pinch.updated(crop: crop, magnification: 1.56, imageRect: rect, source: source)
        #expect(crop == AssetEditPixelCrop(x: 62, y: 64, width: 417, height: 333, in: source))
        pinch.reset()
        #expect(!pinch.isActive)
        #expect(pinch.updated(crop: crop, magnification: 2, imageRect: rect, source: source) == crop)
    }

    /// scale为坏累计倍率；不创建活动捏合，不改像素，空/无限视口也不能产生新的锚点。
    @Test(arguments: [Double.nan, Double.infinity, 0, -1])
    func invalidScalesAndGeometryNeverChangeTheDraft(_ scale: Double) throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: source))
        let rect = CGRect(x: 0, y: 0, width: 500, height: 400)
        var pinch = AssetEditCropMagnificationSession()
        #expect(pinch.updated(crop: crop, magnification: scale, imageRect: rect, source: source) == crop && !pinch.isActive)
        for invalid in [CGRect.zero, CGRect.infinite] {
            #expect(pinch.updated(crop: crop, magnification: 1, imageRect: invalid, source: source) == crop && !pinch.isActive)
        }
    }

    /// 原图像素尺寸改变会使旧源锚点失效；新源的首事件不能使用旧源的倍率基准。
    @Test func changedPixelSourceRequiresANewScaleAnchor() throws {
        let original = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let changed = try #require(AssetEditPixelSize(width: 2000, height: 1600))
        let crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: original))
        let rect = CGRect(x: 0, y: 0, width: 500, height: 400)
        var pinch = AssetEditCropMagnificationSession()
        _ = pinch.updated(crop: crop, magnification: 1, imageRect: rect, source: original)
        #expect(pinch.updated(crop: crop, magnification: 3, imageRect: rect, source: changed) == crop)
        #expect(pinch.updated(crop: crop, magnification: 3.75, imageRect: rect, source: changed)
            == AssetEditPixelCrop(x: 140, y: 130, width: 320, height: 240, in: changed))
    }
}
