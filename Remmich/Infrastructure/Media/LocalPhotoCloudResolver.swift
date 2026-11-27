import Foundation
import Photos

/// 只对当前可见候选做有限反向映射；歧义/不可见对象不猜测，不读取任何原片。
nonisolated enum LocalPhotoCloudResolver {
    @concurrent static func localIDs(for cloudIDs: Set<String>) async throws -> [String: String] {
        try Task.checkCancellation()
        guard cloudIDs.count <= 64 else { throw LocalMediaMetadataError.invalidBatch }
        let identifiers = cloudIDs.compactMap { PHCloudIdentifier(archivalStringValue: $0) }
        let mappings: [PHCloudIdentifier: Result<String, any Error>] = if #available(iOS 27, *) {
            PHPhotoLibrary.shared().localIdentifierMappings(forSynced: identifiers)
        } else {
            PHPhotoLibrary.shared().localIdentifierMappings(for: identifiers)
        }
        try Task.checkCancellation()
        var result: [String: String] = [:]
        for identifier in identifiers {
            if case let .success(localID)? = mappings[identifier], !localID.isEmpty {
                result[identifier.archivalStringValue] = localID
            }
        }
        return result
    }
}
