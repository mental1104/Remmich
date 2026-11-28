import Foundation

/// Runtime source choice. Existing album fixtures remain explicit legacy clients; production selects nativeLibrary.
nonisolated enum PhotoBackupScanSource: String, Codable, Sendable { case selectedAlbums, nativeLibrary }

/// An authorized native image/video inventory, independent of album membership or the Recently Added smart album.
/// Only the complete metadata scan can construct a plan. It contains no original bytes or upload permission.
nonisolated struct PhotoBackupLibraryScan: Sendable {
    let sources: [PhotoBackupSource]

    static func plan(_ assets: [PhotoBackupScannedAsset]) throws -> Self {
        var byID: [String: PhotoBackupScannedAsset] = [:]
        for (index, item) in assets.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard !item.source.localID.isEmpty else { throw PhotoBackupAlbumSelectionError.invalidSelection }
            if let previous = byID[item.source.localID], previous != item {
                throw PhotoBackupAlbumSelectionError.changedSource
            }
            byID[item.source.localID] = item
        }
        try Task.checkCancellation()
        return .init(sources: byID.values.sorted {
            let left = $0.capturedAt ?? .distantPast, right = $1.capturedAt ?? .distantPast
            return left == right ? $0.source.localID < $1.source.localID : left < right
        }.map(\.source))
    }

    private init(sources: [PhotoBackupSource]) {
        self.sources = sources
    }
}
