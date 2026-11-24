import CoreGraphics
import Foundation

/// 编辑坐标使用服务端EXIF方向校正后的原图尺寸，而非缩略图或已裁剪结果的尺寸。
nonisolated struct AssetEditPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    /// width/height为正像素数；非法尺寸返回nil，不猜测缺失的原图边界。
    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// EXIF尺寸和orientation来自同一资产；交换规则与官方getDimensions一致，返回可用的原图坐标空间。
    init?(exifWidth: Int?, exifHeight: Int?, orientation: String?) {
        guard let exifWidth, let exifHeight, exifWidth > 0, exifHeight > 0 else { return nil }
        let direction = orientation.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let swapped = direction.map { [5.0, 6, 7, 8, -90, 90].contains($0) } ?? false
        self.init(width: swapped ? exifHeight : exifWidth, height: swapped ? exifWidth : exifHeight)
    }

    /// 返回用于预览排版的宽高比；尺寸已在初始化时验证。
    var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(height)
    }
}

/// 始终位于原图内的整数裁剪区域；所有手势结果先约束再转换，避免向服务端提交越界或零面积。
nonisolated struct AssetEditPixelCrop: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// 参数均为原图像素；size为原图边界。返回nil表示非法区域，减法校验避免整数相加溢出。
    init?(x: Int, y: Int, width: Int, height: Int, in size: AssetEditPixelSize) {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= size.width, y <= size.height,
              width <= size.width - x, height <= size.height - y else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 返回覆盖size全部像素的区域，供开启或重置裁剪使用。
    static func full(_ size: AssetEditPixelSize) -> Self {
        Self(x: 0, y: 0, width: size.width, height: size.height, in: size)!
    }

    /// dx/dy是从手势开始位置算起的像素位移；返回保持尺寸且不越界的新区域，非法浮点输入保留原值。
    func translated(dx: Double, dy: Double, in size: AssetEditPixelSize) -> Self {
        guard dx.isFinite, dy.isFinite else { return self }
        let left = min(Double(size.width - width), max(0, Double(x) + dx))
        let top = min(Double(size.height - height), max(0, Double(y) + dy))
        guard let left = Int(exactly: left.rounded()), let top = Int(exactly: top.rounded()) else { return self }
        return Self(x: left, y: top, width: width, height: height, in: size) ?? self
    }

    /// 四个角决定固定的对角；dx/dy为从手势起点算起的原图像素变化。
    enum Corner: CaseIterable, Hashable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    /// corner选择移动角，size限制原图边界；返回最少一像素的新区域，不反转左右或上下边。
    func resized(corner: Corner, dx: Double, dy: Double, in size: AssetEditPixelSize) -> Self {
        guard dx.isFinite, dy.isFinite else { return self }
        let movesLeft = corner == .topLeft || corner == .bottomLeft
        let movesTop = corner == .topLeft || corner == .topRight
        let right = Double(x) + Double(width)
        let bottom = Double(y) + Double(height)
        let left = movesLeft ? min(right - 1, max(0, Double(x) + dx)) : Double(x)
        let top = movesTop ? min(bottom - 1, max(0, Double(y) + dy)) : Double(y)
        let newRight = movesLeft ? right : min(Double(size.width), max(left + 1, right + dx))
        let newBottom = movesTop ? bottom : min(Double(size.height), max(top + 1, bottom + dy))
        guard let x = Int(exactly: left.rounded()), let y = Int(exactly: top.rounded()),
              let lastX = Int(exactly: newRight.rounded()), let lastY = Int(exactly: newBottom.rounded()) else { return self }
        return Self(x: x, y: y, width: lastX - x, height: lastY - y, in: size) ?? self
    }

    /// magnification为同一次捏合相对起点的倍率；放大图片会缩小取景区域，中心保持不动直到碰到边界。
    func magnified(by magnification: Double, in size: AssetEditPixelSize) -> Self {
        guard magnification.isFinite, magnification > 0 else { return self }
        let newWidth = min(Double(size.width), max(1, Double(width) / magnification))
        let newHeight = min(Double(size.height), max(1, Double(height) / magnification))
        guard let width = Int(exactly: newWidth.rounded()), let height = Int(exactly: newHeight.rounded()) else { return self }
        let left = min(Double(size.width - width), max(0, Double(x) + (Double(self.width) - Double(width)) / 2))
        let top = min(Double(size.height - height), max(0, Double(y) + (Double(self.height) - Double(height)) / 2))
        guard let x = Int(exactly: left.rounded()), let y = Int(exactly: top.rounded()) else { return self }
        return Self(x: x, y: y, width: width, height: height, in: size) ?? self
    }

    /// imageRect为屏幕内完整原图的aspect-fit区域；返回对应裁剪框，留白不参与坐标换算。
    func displayRect(in imageRect: CGRect, source: AssetEditPixelSize) -> CGRect {
        CGRect(x: imageRect.minX + CGFloat(x) / CGFloat(source.width) * imageRect.width,
               y: imageRect.minY + CGFloat(y) / CGFloat(source.height) * imageRect.height,
               width: CGFloat(width) / CGFloat(source.width) * imageRect.width,
               height: CGFloat(height) / CGFloat(source.height) * imageRect.height)
    }
}

/// 精确表示旋转和镜像组成的八种正交变换；按官方请求数组顺序作用，不把镜像与旋转随意交换。
nonisolated struct AssetEditTransform: Equatable, Sendable {
    private let a: Int
    private let b: Int
    private let c: Int
    private let d: Int
    static let identity = Self(a: 1, b: 0, c: 0, d: 1)

    /// 四个系数是行布局正交矩阵；仅本类型的单位变换和组合方法构造合法矩阵。
    private init(a: Int, b: Int, c: Int, d: Int) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    /// angle为0/90/180/270的顺时针旋转；调用方需先校验服务端输入。
    func rotated(clockwise angle: Int) -> Self {
        let next: Self = switch angle {
        case 90: .init(a: 0, b: -1, c: 1, d: 0)
        case 180: .init(a: -1, b: 0, c: 0, d: -1)
        case 270: .init(a: 0, b: 1, c: -1, d: 0)
        default: .identity
        }
        return followed(by: next)
    }

    /// horizontal为true时左右镜像，否则上下镜像；操作相对当前可见结果，不相对旧的原图轴。
    func mirrored(horizontal: Bool) -> Self {
        followed(by: horizontal ? .init(a: -1, b: 0, c: 0, d: 1) : .init(a: 1, b: 0, c: 0, d: -1))
    }

    /// next在当前变换之后作用；前乘保留官方数组中的操作顺序。
    private func followed(by next: Self) -> Self {
        Self(a: next.a * a + next.b * c, b: next.a * b + next.b * d,
             c: next.c * a + next.d * c, d: next.c * b + next.d * d)
    }

    /// size是裁剪后的像素空间；返回旋转后结果尺寸，镜像不改变宽高。
    func outputSize(for size: AssetEditPixelSize) -> AssetEditPixelSize {
        AssetEditPixelSize(width: a == 0 ? size.height : size.width, height: d == 0 ? size.width : size.height)!
    }

    /// size为待绘制预览的像素大小；返回含平移的UIKit坐标变换，保证结果左上角位于零点。
    func drawingTransform(for size: CGSize) -> CGAffineTransform {
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        let xs = corners.map { CGFloat(a) * $0.x + CGFloat(b) * $0.y }
        let ys = corners.map { CGFloat(c) * $0.x + CGFloat(d) * $0.y }
        return CGAffineTransform(a: CGFloat(a), b: CGFloat(c), c: CGFloat(b), d: CGFloat(d),
                                 tx: -(xs.min() ?? 0), ty: -(ys.min() ?? 0))
    }

    /// 返回至多一次旋转与一次水平镜像的等价官方操作；先归一化再编码，不能简单重排原始操作。
    var canonicalEdits: [AssetEditList.Edit] {
        for angle in [0, 90, 180, 270] {
            let rotation = Self.identity.rotated(clockwise: angle)
            for horizontal in [false, true] {
                let candidate = horizontal ? rotation.mirrored(horizontal: true) : rotation
                if candidate == self {
                    var edits: [AssetEditList.Edit] = []
                    if angle != 0 {
                        edits.append(.init(action: "rotate", parameters: .init(angle: angle)))
                    }
                    if horizontal {
                        edits.append(.init(action: "mirror", parameters: .init(axis: "horizontal")))
                    }
                    return edits
                }
            }
        }
        // 私有构造只生成正交矩阵，所有可达状态均在上方八种组合内。
        return []
    }
}

/// 只包含可安全展示的编辑失败原因，不携带原图路径、账户信息或服务器响应体。
nonisolated enum AssetVisualEditingError: Error, LocalizedError {
    case unsupportedMedia, invalidDimensions, invalidEdits, missingVersion, changedSource, changedEdits, previewUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: "This media type cannot use the still-image editor."
        case .invalidDimensions: "Original image dimensions are unavailable. Reload the photo before editing."
        case .invalidEdits: "Existing edits cannot be represented safely. No changes were sent."
        case .missingVersion: "The server did not provide an image version. Reload before editing."
        case .changedSource: "The photo changed while editing. Reopen the editor before saving."
        case .changedEdits: "Another client changed these edits. Reopen the editor before saving."
        case .previewUnavailable: "The unedited preview could not be loaded. Check connection and retry."
        }
    }
}
