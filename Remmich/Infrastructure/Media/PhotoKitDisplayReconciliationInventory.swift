import Foundation
import Photos

/// Enumerates identifiers only. Hidden/burst items remain subject to the system's current authorization.
@MainActor struct PhotoKitDisplayReconciliationInventory: LocalPhotoInventoryReading {
    var authorization: LocalPhotoLibraryAccess {
        PhotoKitLocalPhotoInventory().authorization
    }

    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        await PhotoKitLocalPhotoInventory().requestAuthorization()
    }

    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try Task.checkCancellation(); try validateContext()
        let access = authorization
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(with: options)
        #if DEBUG
            let session = UUID().uuidString
            var imageCount = 0, videoCount = 0, hiddenCount = 0
            var burstMemberCount = 0, burstRepresentativeCount = 0
            var burstAutoPickCount = 0, burstUserPickCount = 0
        #endif
        var ids: [String] = []
        ids.reserveCapacity(fetched.count)
        for index in 0 ..< fetched.count {
            if index.isMultiple(of: 256) {
                await Task.yield()
                try Task.checkCancellation(); try validateContext()
                guard authorization == access else { throw LocalMediaMetadataError.permission }
            }
            let id = autoreleasepool {
                let asset = fetched.object(at: index)
                #if DEBUG
                    if asset.mediaType == .image {
                        imageCount += 1
                    }
                    if asset.mediaType == .video {
                        videoCount += 1
                    }
                    if asset.isHidden {
                        hiddenCount += 1
                    }
                    if asset.burstIdentifier != nil {
                        burstMemberCount += 1
                    }
                    if asset.representsBurst {
                        burstRepresentativeCount += 1
                    }
                    if asset.burstSelectionTypes.contains(.autoPick) {
                        burstAutoPickCount += 1
                    }
                    if asset.burstSelectionTypes.contains(.userPick) {
                        burstUserPickCount += 1
                    }
                #endif
                return asset.localIdentifier
            }
            ids.append(id)
        }
        try Task.checkCancellation(); try validateContext()
        guard authorization == access else { throw LocalMediaMetadataError.permission }
        guard Set(ids).count == ids.count else { throw LocalMediaMetadataError.invalidBatch }
        #if DEBUG
            let standardOptions = PHFetchOptions()
            standardOptions.predicate = options.predicate
            standardOptions.includeHiddenAssets = false
            standardOptions.includeAllBurstAssets = false
            let standardCount = PHAsset.fetchAssets(with: standardOptions).count
            try Task.checkCancellation(); try validateContext()
            guard authorization == access else { throw LocalMediaMetadataError.permission }
            let coverage: [String: Any] = [
                "schemaVersion": 1, "session": session, "authorization": access.rawValue,
                "fullCount": fetched.count, "standardCount": standardCount,
                "difference": fetched.count - standardCount,
                "differenceIsCountComparisonNotSetDifference": true,
                "classificationsApplyToFullFetch": true, "classificationsMayOverlap": true,
                "burstCountsAreNotAdditionalPhotoCounts": true,
                "classifications": [
                    "imageCount": imageCount, "videoCount": videoCount, "hiddenCount": hiddenCount,
                    "burstMemberCount": burstMemberCount, "burstRepresentativeCount": burstRepresentativeCount,
                    "burstAutoPickCount": burstAutoPickCount, "burstUserPickCount": burstUserPickCount,
                ],
            ]
            // Anonymous counts only; diagnostics never affect inventory or matching success.
            if let bytes = try? JSONSerialization.data(withJSONObject: coverage, options: [.sortedKeys]) {
                let destination = URL.documentsDirectory.appendingPathComponent("photokit-inventory-coverage.json")
                try? bytes.write(to: destination, options: .atomic)
            }
        #endif
        return ids
    }
}
