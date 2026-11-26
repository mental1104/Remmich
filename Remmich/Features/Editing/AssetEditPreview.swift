import SwiftUI
import UIKit

/// 原始预览的方向和比例验证；只规范化已下载的有限预览，不下载原片或改变服务器资源。
enum AssetEditPreviewImage {
    /// image来自明确edited=false的预览；size是服务端原图坐标。方向/比例不一致时抛错，不能拉伸掩盖错误。
    static func normalized(_ image: UIImage, for size: AssetEditPixelSize) throws -> UIImage {
        guard let raw = image.cgImage else { throw AssetVisualEditingError.previewUnavailable }
        let swapsAxes = switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
        let width = CGFloat(swapsAxes ? raw.height : raw.width)
        let height = CGFloat(swapsAxes ? raw.width : raw.height)
        let expectedHeight = width * CGFloat(size.height) / CGFloat(size.width)
        // 缩略图整数缩放可能差一像素；较大比例差意味着方向或源版本不匹配，必须停止编辑。
        guard abs(height - expectedHeight) <= max(2, max(width, height) * 0.002) else {
            throw AssetVisualEditingError.invalidDimensions
        }
        if image.imageOrientation == .up {
            return UIImage(cgImage: raw, scale: 1, orientation: .up)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

/// 用SwiftUI裁切和正交变换实时显示有限预览；手势每帧不重新编码位图，最终保存仍是原图像素参数。
struct AssetEditResultPreview: View {
    let image: UIImage
    let draft: AssetEditDraft
    let showsOriginal: Bool

    var body: some View {
        GeometryReader { geometry in
            let crop = showsOriginal ? AssetEditPixelCrop.full(draft.sourceSize) : draft.crop ?? .full(draft.sourceSize)
            let transform = showsOriginal ? AssetEditTransform.identity : draft.transform
            let croppedSize = AssetEditPixelSize(width: crop.width, height: crop.height)!
            let output = transform.outputSize(for: croppedSize)
            let scale = max(0, min(geometry.size.width / CGFloat(output.width), geometry.size.height / CGFloat(output.height)))
            let cropDisplay = CGSize(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale)
            ZStack {
                Color.black.opacity(0.9)
                Image(uiImage: image).resizable()
                    .frame(width: CGFloat(draft.sourceSize.width) * scale, height: CGFloat(draft.sourceSize.height) * scale)
                    .offset(x: -CGFloat(crop.x) * scale, y: -CGFloat(crop.y) * scale)
                    .frame(width: cropDisplay.width, height: cropDisplay.height, alignment: .topLeading)
                    .clipped()
                    .transformEffect(transform.drawingTransform(for: cropDisplay))
                    .frame(width: CGFloat(output.width) * scale, height: CGFloat(output.height) * scale, alignment: .topLeading)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(showsOriginal ? "Original image" : "Edited image preview"))
        .accessibilityIdentifier(showsOriginal ? "asset-editor-original" : "asset-editor-result")
    }
}
