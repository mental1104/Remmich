import CryptoKit
import Foundation

/// 原片查重/上传后经fresh资产确认的来源证据；独立于只有iCloud ID匹配的false字节标记，也不覆盖官方mobile-app。
nonisolated struct PhotoBackupOrigin: Codable, Equatable, Sendable {
    static let keyPrefix = "remmich-backup-icloud-"
    let version: Int
    let method: String
    let byteVerified: Bool
    let checksum: String
    let metadata: LocalMediaMobileMetadata

    /// metadata来自本轮Photos观察，checksum来自实际导出文件SHA1；只能在资产身份/原片摘要回读确认后保存。
    init(metadata: LocalMediaMobileMetadata, checksum: String) throws {
        version = 1; method = "sha1"; byteVerified = true; self.checksum = checksum; self.metadata = metadata
        try validate()
    }

    /// 每个云ID有独立固定长度key；相同字节对应多个Photos对象时不互相覆盖，也不把opaque ID放进URL。
    static func metadataKey(for cloudID: String) -> String {
        keyPrefix + SHA256.hash(data: Data(cloudID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 校验从服务端读取的版本/方法/完整SHA1；未知格式不冒充字节证据。
    func validate() throws {
        guard version == 1, method == "sha1", byteVerified,
              metadata.cloudId.utf8.count <= 4096,
              let bytes = Data(base64Encoded: checksum), bytes.count == 20, bytes.base64EncodedString() == checksum
        else { throw LocalMediaMetadataError.invalidMetadata }
    }
}
