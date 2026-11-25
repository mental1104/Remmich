import Foundation
import UniformTypeIdentifiers

/// 单份PhotoKit原始静态图的公开描述；不含文件路径、字节或私有resource身份，顺序不能表示RAW/JPEG角色。
nonisolated struct PhotoBackupOriginalImage: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, alternatePhoto, unsupported }
    let kind: Kind
    let uniformTypeIdentifier: String
    let originalFilename: String
    let pixelWidth: Int
    let pixelHeight: Int

    /// 只用公开UTI分类；未知类型不能根据扩展名推断成RAW或JPEG。
    var format: PhotoBackupImageRole? {
        guard let type = UTType(uniformTypeIdentifier) else { return nil }
        if type.conforms(to: .rawImage) {
            return .raw
        }
        return type.conforms(to: .jpeg) ? .jpeg : nil
    }
}

/// 同一逻辑照片的两个原始图像角色；固定RAW先行仅决定上传次序，不假定PhotoKit枚举顺序或photo角色就是RAW。
nonisolated enum PhotoBackupImageRole: String, Codable, Sendable { case raw, jpeg }

/// 扫描冻结的一RAW一JPEG原始组合；完整描述参与source版本比较，不能只用PHAsset的可空修改时间证明资源一致。
nonisolated struct PhotoBackupRawJPEGSource: Codable, Hashable, Sendable {
    let raw: PhotoBackupOriginalImage
    let jpeg: PhotoBackupOriginalImage

    /// originals必须恰含photo/alternatePhoto各一份、公开UTI各RAW/JPEG一份；编辑/附加/未知资源一律拒绝。
    /// hasAdjustments/adjustmentTime来自公开PHAsset属性；失败仅返回安全资源分类，不读取任何媒体字节。
    init(originals: [PhotoBackupOriginalImage], hasAdjustments: Bool, adjustmentTime: Date?) throws {
        guard !hasAdjustments, adjustmentTime == nil, originals.count == 2,
              Set(originals.map(\.kind)) == [.photo, .alternatePhoto],
              originals.allSatisfy({ !$0.originalFilename.isEmpty && $0.pixelWidth > 0 && $0.pixelHeight > 0 }),
              originals.filter({ $0.format == .raw }).count == 1,
              originals.filter({ $0.format == .jpeg }).count == 1,
              let raw = originals.first(where: { $0.format == .raw }), let jpeg = originals.first(where: { $0.format == .jpeg })
        else { throw PhotoBackupStateError.invalidJournal }
        self.raw = raw; self.jpeg = jpeg
    }

    /// 解码后的资源也必须满足相同公开规则，不能用手工拼出的错误角色绕过扫描分类。
    func validate() throws {
        let canonical = try Self(originals: [raw, jpeg], hasAdjustments: false, adjustmentTime: nil)
        guard canonical == self else { throw PhotoBackupStateError.invalidJournal }
    }
}

/// 一份完整原始图像已上传/查重并fresh确认的持久回执；checksum为实际文件SHA1的规范Base64，不是源元数据猜测。
nonisolated struct PhotoBackupImageReceipt: Codable, Equatable, Sendable {
    let assetID: UUID
    let checksum: String
    let duplicate: Bool

    /// 只接受20字节SHA1的规范Base64；错误回执不能进入可恢复资料，更不能算作整组成功。
    func validate() throws {
        guard let bytes = Data(base64Encoded: checksum), bytes.count == 20, bytes.base64EncodedString() == checksum else {
            throw PhotoBackupStateError.invalidJournal
        }
    }
}
