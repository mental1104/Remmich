# Local media association for browsing

This independent `codex/feature-local-media-match` slice is based on424a22a. It supplies metadata candidates for local-first Immich browsing, enlargement and playback. It does not yet change media-loading entry points. Backup workers/journals, mutations, SQLite, server/API, workflows and tonight's candidate are untouched; association is not backup completion, original-byte identity or device-space-cleanup evidence.

## Exact official metadata

`LocalMediaMobileMetadata` decodes `iCloudId`, `createdAt`, `adjustmentTime`, `latitude` and `longitude`. The Swift property is `cloudId`; the wire key is exactly `iCloudId`. IDs remain complete opaque strings; do not interpret the internal suffix as SHA1. Empty/whitespace/known incomplete trailing-colon IDs cannot match. Failed or missing mappings remain unknown.

The official `mobile/lib/domain/models/asset/asset_metadata.model.dart` custom toJson omits nil entries. Only those four known nullable fields therefore permit missing/null equivalence. Nonempty bad dates, wrong types, nonfinite or out-of-range coordinate strings throw rather than becoming nil. Remote fractional time stays precise; only local creation/adjustment times follow the official native bridge's truncation toward zero to whole Unix seconds. Coordinates and optional values compare exactly. A missing native creation time cannot reproduce the official client's current-time fallback, so no time is invented.

The reference is `mobile/lib/infrastructure/repositories/local_asset.repository.dart:222`: the official client reconciles checksums using equal Cloud ID, creation/adjustment time and coordinates before computing missing hashes. This slice uses that identity/version relationship only to find a display candidate. Duplicate candidates, including duplicate UUID records, are ambiguous. `LocalMediaMatch.resolve(expected:snapshot:candidates:)` rejects changed local observations; Photos edits are allowed when their public adjustment time is known and equal. Live Photo/RAW+JPEG objects can associate for Photos current rendering, without proving their original resources or remote motion pairing were backed up.

`LocalMediaRemoteCandidate` holds only asset UUID and decoded metadata. Root integration must fresh-read owner/type/version/server edit state before selecting local display. Immich nondestructive edits may change display without changing uploaded mobile metadata; until the local renderer applies that edit chain, server-edited display must retain the remote edited-media path.

## Public PhotoKit reader

`PhotoKitLocalPhotoMetadataReader.snapshots(for:validateContext:)` accepts at most64 nonempty distinct local IDs, preserving request order. It reads authorized PHAsset metadata and PHAssetResource descriptions, performs Cloud ID mapping off the main executor, then re-reads the metadata before returning. Changed metadata, cancellation or revoked account/page generation cannot publish old associations. System mapping has no cancellation handle; cancelled results are discarded after it returns. Only Sendable values cross the executor boundary, with no PHAsset objects.

Captured fields are local identity/modification time, creation/adjustment time, hasAdjustments, coordinates, pixels/duration/subtypes and resource type/filename/UTI/dimensions. Resource ordering is canonical and duplicates remain visible. These are structure/version observations, not a hash. Asset dimensions describe current edited content. No private KVC, isCurrent, fileSize, locallyAvailable or official-device-ID reconstruction is used. Required APIs fit minimum26.6: resource dimensions are public from16, hasAdjustments from15 and adjustmentTimestamp from18. The27-only optional dataSize is unused. The old macOS-only PHCloudIdentifier.notFound constant is not used with iOS's Result mapping.

This reader never calls requestImage, requestData, media export or image/video loaders. Cloud ID mapping can be expensive and may involve system metadata networking; this is not a promise of zero iCloud network activity. It does not request original photo/video bytes.

## Display integration boundary

Use public PHImageManager requestImage for current photos/posters, requestPlayerItem(forVideo:) for video and requestLivePhoto for motion/sound. Each future adapter must set version.current and isNetworkAccessAllowed=false, retain its PHImageRequestID and cancel through cancelImageRequest. Keep target pixels bounded to the existing pipeline. A degraded thumbnail is temporary, not a full-quality result. If local current content is unavailable, use Immich without silently downloading an iCloud original. A Live Photo still uses requestImage; its image PHAsset is not a normal video asset. AVPlayerItem may represent Photos compositions, so do not assume AVURLAsset. Recheck local version and account generation before publishing results.

Those loading paths are recommendations only: local render/playback, cloud-only fallback, actual permission changes and device behavior remain unimplemented/unverified in this slice.

## Validation and rollback

New pure-domain and actual-reader tests cover exact tuple/null/version/current-edit rules, duplicate ambiguity, failed mappings, strict wire values,64-item bounds, invalid identities, changed resources and cancellation/revocation during a real held await. System metadata is synthetic. NAS scoped SwiftFormat0.64.5, diff and fixed-JSON syntax checks pass; Swift compilation/tests and actual Photos/iCloud/device behavior have not run. No private media, real account, service mutation or CI execution was used.

Sources: official source paths above; Apple [resource metadata](https://developer.apple.com/documentation/photos/phassetresource/assetresources(for:)-27o4l), [public adjustment time](https://developer.apple.com/documentation/photos/phasset/adjustmenttimestamp), [Cloud mapping](https://developer.apple.com/documentation/photos/phphotolibrary/cloudidentifiermappings(forlocalidentifiers:)), [image loading](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:)), [video](https://developer.apple.com/documentation/photos/phimagemanager/requestplayeritem(forvideo:options:resulthandler:)) and [Live Photos](https://developer.apple.com/documentation/photos/phimagemanager/requestlivephoto(for:targetsize:contentmode:options:resulthandler:)).

Rollback removes these isolated models/reader/tests without a data migration. The separate real-container resize work is preserved and paused; it is not included here.
