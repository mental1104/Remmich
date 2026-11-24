import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Remmich

/// 原图坐标、正交变换和真实预览方向的回归；所有尺寸、像素及身份均为合成资料。
@Suite("Visual non-destructive editing")
struct AssetVisualEditingTests {
    /// 方向交换规则必须与服务端getDimensions一致，竖拍照片不能使用未校正EXIF宽高裁剪。
    @Test(arguments: ["5", "6", "7", "8", "90", "-90", " 6 "])
    func swapsExifDimensions(_ orientation: String) throws {
        let size = try #require(AssetEditPixelSize(exifWidth: 6000, exifHeight: 4000, orientation: orientation))
        #expect(size.width == 4000 && size.height == 6000)
    }

    /// 缺失/非旋转方向保持服务端原值；无原图尺寸时禁止靠预览猜测。
    @Test func retainsUnswappedDimensionsAndRejectsMissingSizes() {
        for orientation in [nil, "1", "2", "3", "4", "0", "unknown"] {
            #expect(AssetEditPixelSize(exifWidth: 6000, exifHeight: 4000, orientation: orientation) == AssetEditPixelSize(width: 6000, height: 4000))
        }
        #expect(AssetEditPixelSize(exifWidth: nil, exifHeight: 4000, orientation: "6") == nil)
        #expect(AssetEditPixelSize(width: 0, height: 4000) == nil)
        #expect(AssetEditPixelSize(width: -1, height: 1) == nil)
    }

    /// 所有几何方法保持整数且位于原图内；测试决定性边界值而非实现内的中间变量。
    @Test func clampsDragCornerResizeAndMagnification() throws {
        let size = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let crop = try #require(AssetEditPixelCrop(x: 100, y: 100, width: 400, height: 300, in: size))
        #expect(crop.translated(dx: 999, dy: -999, in: size) == AssetEditPixelCrop(x: 600, y: 0, width: 400, height: 300, in: size))
        #expect(crop.resized(corner: .topLeft, dx: 999, dy: 999, in: size) == AssetEditPixelCrop(x: 499, y: 399, width: 1, height: 1, in: size))
        #expect(crop.resized(corner: .bottomRight, dx: 999, dy: 999, in: size) == AssetEditPixelCrop(x: 100, y: 100, width: 900, height: 700, in: size))
        #expect(crop.magnified(by: 2, in: size) == AssetEditPixelCrop(x: 200, y: 175, width: 200, height: 150, in: size))
        #expect(crop.magnified(by: 0.1, in: size) == .full(size))
        #expect(crop.translated(dx: .nan, dy: 0, in: size) == crop)
        #expect(crop.magnified(by: .infinity, in: size) == crop)
        #expect(crop.magnified(by: 0, in: size) == crop)
        #expect(AssetEditPixelCrop(x: 900, y: 0, width: 200, height: 1, in: size) == nil)
        #expect(AssetEditPixelCrop(x: Int.max, y: 0, width: 1, height: 1, in: size) == nil)
    }

    /// aspect-fit留白不能成为裁剪坐标；视口尺寸变化仅改变框的位置，不改变原始像素区域。
    @Test @MainActor func mapsCropOnlyWithinTheFittedImage() throws {
        let source = try #require(AssetEditPixelSize(width: 1000, height: 500))
        let crop = try #require(AssetEditPixelCrop(x: 100, y: 50, width: 200, height: 100, in: source))
        let phone = AssetEditCropCanvas.imageRect(source, in: CGSize(width: 300, height: 300))
        #expect(phone == CGRect(x: 0, y: 75, width: 300, height: 150))
        #expect(crop.displayRect(in: phone, source: source) == CGRect(x: 30, y: 90, width: 60, height: 30))
        let tablet = AssetEditCropCanvas.imageRect(source, in: CGSize(width: 1000, height: 600))
        #expect(crop.displayRect(in: tablet, source: source) == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(crop.x == 100 && crop.y == 50 && crop.width == 200 && crop.height == 100)
    }

    /// 导入任意合法镜像/旋转顺序后，保存规范化结果仍须视觉等价；裁剪保持第一项及原图坐标。
    @Test func normalizesEditsWithoutReorderingTheirMeaning() throws {
        let size = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let crop = AssetEditList.Edit(action: "crop", parameters: .init(x: 100, y: 50, width: 400, height: 300))
        for angle in [0, 90, 180, 270] {
            let rotate = AssetEditList.Edit(action: "rotate", parameters: .init(angle: angle))
            for axis in ["horizontal", "vertical"] {
                let mirror = AssetEditList.Edit(action: "mirror", parameters: .init(axis: axis))
                for edits in [[crop, rotate, mirror], [crop, mirror, rotate]] {
                    let draft = try AssetEditDraft(size: size, list: .init(edits: edits))
                    #expect(draft.payload.edits.first == crop)
                    #expect(try AssetEditDraft(size: size, list: draft.payload) == draft)
                    #expect(draft.outputSize == AssetEditPixelSize(width: angle == 90 || angle == 270 ? 300 : 400,
                                                                   height: angle == 90 || angle == 270 ? 400 : 300))
                }
            }
        }
        let rotate = AssetEditList.Edit(action: "rotate", parameters: .init(angle: 90))
        let mirror = AssetEditList.Edit(action: "mirror", parameters: .init(axis: "horizontal"))
        #expect(try AssetEditDraft(size: size, list: .init(edits: [rotate, mirror])).transform != AssetEditDraft(size: size, list: .init(edits: [mirror, rotate])).transform)
    }

    /// 不认识、重复、越界或错误参数整组拒绝，不以可表示子集覆盖其他客户端的编辑。
    @Test func rejectsUnsupportedOrMalformedEditLists() throws {
        let size = try #require(AssetEditPixelSize(width: 1000, height: 800))
        let crop = AssetEditList.Edit(action: "crop", parameters: .init(x: 100, y: 100, width: 400, height: 300))
        let rotation = AssetEditList.Edit(action: "rotate", parameters: .init(angle: 90))
        let invalid: [[AssetEditList.Edit]] = [
            [rotation, crop], [crop, crop], [rotation, rotation],
            [.init(action: "rotate", parameters: .init(angle: 45))],
            [.init(action: "rotate", parameters: .init(x: 1, angle: 90))],
            [.init(action: "mirror", parameters: .init(axis: "diagonal"))],
            [.init(action: "crop", parameters: .init(x: 900, y: 0, width: 200, height: 100))],
            [.init(action: "future-filter", parameters: .init())],
        ]
        for list in invalid {
            #expect(throws: AssetVisualEditingError.self) { try AssetEditDraft(size: size, list: .init(edits: list)) }
        }
    }

    /// 预期色块来自官方compose→Sharp.affine实跑；UIKit预览变换必须给出同一排列，而非只比较矩阵自身。
    @Test(arguments: ["rotate90", "rotate180", "rotate270", "horizontal", "vertical", "horizontal-rotate90", "rotate90-horizontal"])
    @MainActor func matchesOfficialSharpPixelOrder(_ scenario: String) throws {
        let size = try #require(AssetEditPixelSize(width: 60, height: 40))
        let rotation90 = AssetEditList.Edit(action: "rotate", parameters: .init(angle: 90))
        let rotation180 = AssetEditList.Edit(action: "rotate", parameters: .init(angle: 180))
        let rotation270 = AssetEditList.Edit(action: "rotate", parameters: .init(angle: 270))
        let horizontal = AssetEditList.Edit(action: "mirror", parameters: .init(axis: "horizontal"))
        let edits: [AssetEditList.Edit]
        let expected: [[Int]]
        switch scenario {
        case "rotate90": edits = [rotation90]; expected = [[4, 1], [5, 2], [6, 3]]
        case "rotate180": edits = [rotation180]; expected = [[6, 5, 4], [3, 2, 1]]
        case "rotate270": edits = [rotation270]; expected = [[3, 6], [2, 5], [1, 4]]
        case "horizontal": edits = [horizontal]; expected = [[3, 2, 1], [6, 5, 4]]
        case "vertical": edits = [.init(action: "mirror", parameters: .init(axis: "vertical"))]; expected = [[4, 5, 6], [1, 2, 3]]
        case "horizontal-rotate90": edits = [horizontal, rotation90]; expected = [[6, 3], [5, 2], [4, 1]]
        default: edits = [rotation90, horizontal]; expected = [[1, 4], [2, 5], [3, 6]]
        }
        let draft = try AssetEditDraft(size: size, list: .init(edits: edits))
        let result = renderTiles(tileImage(), draft: draft)
        for (row, values) in expected.enumerated() {
            for (column, value) in values.enumerated() {
                #expect(try tileValue(result, x: column * 20 + 10, y: row * 20 + 10) == value)
            }
        }
    }

    /// 缩略图orientation必须被真正展开，错误比例必须拒绝；不能把不匹配的图拉伸到合法尺寸。
    @Test @MainActor func normalizesPreviewOrientationAndRejectsWrongAspect() throws {
        let input = tileImage()
        let raw = try #require(input.cgImage)
        let right = UIImage(cgImage: raw, scale: 1, orientation: .right)
        let upright = try AssetEditPreviewImage.normalized(right, for: #require(AssetEditPixelSize(width: 4000, height: 6000)))
        #expect(upright.imageOrientation == .up && upright.size == CGSize(width: 40, height: 60))
        #expect(throws: AssetVisualEditingError.self) {
            try AssetEditPreviewImage.normalized(input, for: #require(AssetEditPixelSize(width: 4000, height: 6000)))
        }
    }

    /// 直接渲染产品SwiftUI预览，防止裁剪offset/布局框与数学矩阵各自正确但组合后取错区域。
    @Test @MainActor func renderedPreviewMatchesCropAndOriginalComparison() throws {
        let size = try #require(AssetEditPixelSize(width: 60, height: 40))
        let draft = try AssetEditDraft(size: size, list: .init(edits: [
            .init(action: "crop", parameters: .init(x: 20, y: 0, width: 40, height: 40)),
            .init(action: "rotate", parameters: .init(angle: 90)),
            .init(action: "mirror", parameters: .init(axis: "horizontal")),
        ]))
        let renderer = ImageRenderer(content: AssetEditResultPreview(image: tileImage(), draft: draft, showsOriginal: false)
            .frame(width: 40, height: 40))
        renderer.scale = 1
        let result = try #require(renderer.uiImage)
        let expected = [[2, 5], [3, 6]]
        for (row, values) in expected.enumerated() {
            for (column, value) in values.enumerated() {
                #expect(try tileValue(result, x: column * 20 + 10, y: row * 20 + 10) == value)
            }
        }
        let originalRenderer = ImageRenderer(content: AssetEditResultPreview(image: tileImage(), draft: draft, showsOriginal: true)
            .frame(width: 60, height: 40))
        originalRenderer.scale = 1
        let original = try #require(originalRenderer.uiImage)
        #expect(try tileValue(original, x: 10, y: 10) == 1)
        #expect(try tileValue(original, x: 50, y: 30) == 6)
    }

    /// 真实DTO解码后的方向与不透明版本进入同一快照，更新校验和/版本或尺寸都使快照不同。
    @Test func requiresRealVersionAndRejectsUnsupportedMedia() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","ownerId":"synthetic","isFavorite":false,"visibility":"timeline","isTrashed":false,"type":"IMAGE","originalFileName":"synthetic.jpg","livePhotoVideoId":null,"projectionType":null,"updatedAt":"2026-11-24T00:00:00Z","checksum":"synthetic-one","exifInfo":{"description":null,"exifImageWidth":6000,"exifImageHeight":4000,"orientation":"6"}}"#
        let asset = try JSONDecoder().decode(ManagedAsset.self, from: Data(json.utf8))
        let version = try AssetEditingView.sourceVersion(asset, userID: "synthetic")
        #expect(version.size == AssetEditPixelSize(width: 4000, height: 6000))
        let changed = try JSONDecoder().decode(ManagedAsset.self, from: Data(json.replacingOccurrences(of: "synthetic-one", with: "synthetic-two").utf8))
        #expect(try AssetEditingView.sourceVersion(changed, userID: "synthetic") != version)
        let dateChanged = try JSONDecoder().decode(ManagedAsset.self, from: Data(json.replacingOccurrences(of: "00:00:00Z", with: "00:00:01Z").utf8))
        #expect(try AssetEditingView.sourceVersion(dateChanged, userID: "synthetic") != version)
        #expect(throws: AssetVisualEditingError.self) { try AssetEditingView.sourceVersion(asset, userID: "other") }
        for replacement in [json.replacingOccurrences(of: "\"checksum\":\"synthetic-one\"", with: "\"checksum\":null"),
                            json.replacingOccurrences(of: "\"IMAGE\"", with: "\"VIDEO\""),
                            json.replacingOccurrences(of: "synthetic.jpg", with: "synthetic.GIF"),
                            json.replacingOccurrences(of: "\"projectionType\":null", with: "\"projectionType\":\"EQUIRECTANGULAR\"")]
        {
            let invalid = try JSONDecoder().decode(ManagedAsset.self, from: Data(replacement.utf8))
            #expect(throws: AssetVisualEditingError.self) { try AssetEditingView.sourceVersion(invalid, userID: "synthetic") }
        }
    }

    /// 六个20×20灰度色块，独立给每个原始位置固定编号，不读取照片或写入Photos。
    @MainActor private func tileImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40), format: format).image { context in
            for row in 0 ..< 2 {
                for column in 0 ..< 3 {
                    let level = CGFloat(1 + column + 3 * row) * 30 / 255
                    UIColor(red: level, green: level, blue: level, alpha: 1).setFill()
                    context.fill(CGRect(x: CGFloat(column * 20), y: CGFloat(row * 20), width: 20, height: 20))
                }
            }
        }
    }

    /// image为合成未编辑源，draft使用与实际SwiftUI预览相同的绘制矩阵；返回输出像素以独立采样。
    @MainActor private func renderTiles(_ image: UIImage, draft: AssetEditDraft) -> UIImage {
        let crop = draft.crop ?? .full(draft.sourceSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(draft.outputSize.width), height: CGFloat(draft.outputSize.height)), format: format).image { context in
            context.cgContext.concatenate(draft.transform.drawingTransform(for: CGSize(width: CGFloat(crop.width), height: CGFloat(crop.height))))
            image.draw(in: CGRect(x: -CGFloat(crop.x), y: -CGFloat(crop.y), width: CGFloat(draft.sourceSize.width), height: CGFloat(draft.sourceSize.height)))
        }
    }

    /// x/y为结果图中一个色块中心；转为明确RGBA字节后读灰度编号，不依赖UIImage底层字节序。
    @MainActor private func tileValue(_ image: UIImage, x: Int, y: Int) throws -> Int {
        let raw = try #require(image.cgImage?.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(raw, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int((Double(pixel[0]) / 30).rounded())
    }
}
