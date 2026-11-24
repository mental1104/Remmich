import Foundation

/// 一次静态照片编辑草稿；裁剪始终使用原图坐标，旋转/镜像保存为视觉等价的正交变换。
nonisolated struct AssetEditDraft: Equatable, Sendable {
    let sourceSize: AssetEditPixelSize
    var crop: AssetEditPixelCrop?
    var transform: AssetEditTransform

    /// size为已验证的原图坐标空间；创建无调整草稿，不读取或写入服务器。
    init(size: AssetEditPixelSize) {
        sourceSize = size
        crop = nil
        transform = .identity
    }

    /// size为EXIF校正后的原图尺寸；list是服务端当前完整编辑。未知/重复/越界参数整组拒绝，不部分载入。
    init(size: AssetEditPixelSize, list: AssetEditList) throws {
        sourceSize = size
        crop = nil
        transform = .identity
        var slots = Set<String>()
        for (index, edit) in list.edits.enumerated() {
            let parameters = edit.parameters
            let slot = edit.action == "mirror" ? "mirror-\(parameters.axis ?? "")" : edit.action
            guard slots.insert(slot).inserted else { throw AssetVisualEditingError.invalidEdits }
            switch edit.action {
            case "crop":
                guard index == 0, let x = parameters.x, let y = parameters.y,
                      let width = parameters.width, let height = parameters.height,
                      parameters == .init(x: x, y: y, width: width, height: height),
                      let region = AssetEditPixelCrop(x: x, y: y, width: width, height: height, in: size)
                else { throw AssetVisualEditingError.invalidEdits }
                crop = region
            case "rotate":
                guard let angle = parameters.angle, [0, 90, 180, 270].contains(angle), parameters == .init(angle: angle)
                else { throw AssetVisualEditingError.invalidEdits }
                transform = transform.rotated(clockwise: angle)
            case "mirror":
                guard let axis = parameters.axis, ["horizontal", "vertical"].contains(axis), parameters == .init(axis: axis)
                else { throw AssetVisualEditingError.invalidEdits }
                transform = transform.mirrored(horizontal: axis == "horizontal")
            default: throw AssetVisualEditingError.invalidEdits
            }
        }
    }

    /// 返回官方请求体；裁剪必须第一项，后续变换已经做等价归一化，空数组由调用方走reset接口。
    var payload: AssetEditList {
        var edits: [AssetEditList.Edit] = []
        if let crop {
            edits.append(.init(action: "crop", parameters: .init(x: crop.x, y: crop.y, width: crop.width, height: crop.height)))
        }
        edits += transform.canonicalEdits
        return .init(edits: edits)
    }

    /// 当前裁剪与变换的输出像素尺寸，供预览及无障碍说明使用。
    var outputSize: AssetEditPixelSize {
        let size = crop.map { AssetEditPixelSize(width: $0.width, height: $0.height)! } ?? sourceSize
        return transform.outputSize(for: size)
    }
}

/// 固定编辑开始时的源身份与版本；预览完成及提交前都须与同一账户的新状态比较。
nonisolated struct AssetEditSourceVersion: Equatable, Sendable {
    let assetID: String
    let ownerID: String
    let checksum: String
    let updatedAt: String
    let originalFileName: String
    let size: AssetEditPixelSize

    /// 用于未编辑预览的独立缓存版本，不包含原始文件名或凭据。
    var previewCacheVersion: String {
        "\(checksum)|\(updatedAt)|\(size.width)x\(size.height)"
    }

    /// 字符串均为服务器当前响应的原值；checksum/updatedAt缺失时拒绝可视编辑，不猜测版本。
    init(assetID: String, ownerID: String, checksum: String?, updatedAt: String?, originalFileName: String, size: AssetEditPixelSize) throws {
        guard let checksum, !checksum.isEmpty, let updatedAt, !updatedAt.isEmpty else { throw AssetVisualEditingError.missingVersion }
        self.assetID = assetID
        self.ownerID = ownerID
        self.checksum = checksum
        self.updatedAt = updatedAt
        self.originalFileName = originalFileName
        self.size = size
    }
}
