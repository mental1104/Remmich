# Immich OpenAPI snapshot

- Source: sibling checkout `../immich/open-api/immich-openapi-specs.json`
- Upstream commit: `520a70891b0e0fdb3f7d3fbca18232bfee322916`
- Upstream describe: `v3.1.0-447-g520a70891`
- OpenAPI document version: `3.2.0`
- Upstream SHA-256: `4e15b58113426d59ffb991a82875308b3eeb64e6c916395e5c923a0632fcc67f`
- Prepared SHA-256: `15ca29352b3cbe04993c6ba7767e960c0cf7f76d89345354f74d850435533833`
- Copied: 2026-09-27

2026-11-24 nullable-rating follow-up: extract the original SmartSearchDto.rating leaf unchanged into NullableLegacySearchRating and replace the inline leaf with a reference. The generator's documented typeOverrides maps that leaf and NumberFilterNullable to handwritten Codable types, allowing explicit null while retaining omitted fields. Normalizing the reference back to its leaf produces a document identical to the prior prepared snapshot; min/max/nullable/history and every other schema value are preserved. Raw upstream hash remains unchanged, preparation is idempotent, and generated Swift remains build-plugin output. New Swift compilation/wire tests are pending; this is not a server API change.
- Transformations: `Scripts/prepare-immich-schema.py` removes deprecated flat metadata request fields. It retains `SearchAssetResponseDto.nextPage`, now used for official legacy smart pagination, alongside metadata `nextCursor`. It also limits the authenticated user config decoder to map settings and the optional external domain used for shared links. This lets Remmich load maps from server responses that omit unrelated fields such as `theme`.

2026-11-24 search update: regenerate with the same upstream commit above, whose raw SHA-256 was rechecked unchanged. Compared with the previous prepared snapshot, the only Schema change is restoring the original nextPage property and required entry (22 lines); all other JSON values match. Preparation is idempotent. Generated Swift remains build-tool output and was not edited. Smart legacy deprecations remain visible rather than suppressed.

2026-11-24 EXIF follow-up: the preparation script additionally consumes committed `search-extensions.json` (SHA-256 `d3ec71dba687fb67cebe520f05c9d0672b78b915a00d43010b10cc6dbd85a43a`). That input records the owning Fork commit and complete source-schema hash. Only iso/fNumber/focalLength/exposureTime/orientation are added to SearchFilter and SearchFilterBranch, with MediaOrientationFilter/SearchOrientation dependencies. A whole-document comparison proves all other values match the prior prepared snapshot; the selected definitions exactly match the parent Fork source. This does not refresh other API schemas or claim these fields work on every official server. Actual API errors remain visible. Regeneration and idempotence were checked on Python3.8; generated Swift is still produced by the build plugin.

The generator configuration includes only operations used by the wrapper and their dependencies. This avoids generating unused legacy search DTOs and operations whose initializers reference deprecated properties. The preparation step removes the equivalent unused aliases from the search DTO that Remmich does use; it does not suppress compiler diagnostics or edit generated Swift files.

Album reads were enabled on 2026-11-11 using the same pinned snapshot: `getAllAlbums` and `getAlbumInfo` are in the operation filter, and the wrapper forwards `albumId` to `getTimeBuckets`/`getTimeBucket`. Album-scoped queries include stacked members and omit the root timeline visibility filter so archived album members remain readable. No album create/edit/delete or membership mutation operation is enabled. This expands the generated read surface; it does not refresh the schema snapshot or change the provenance hashes above. Regression coverage is in [AlbumReadTests](Tests/ImmichAPITests/AlbumReadTests.swift).

Map configuration uses authenticated `getUserConfig`. `getServerConfig` and `getServerFeatures` remain intentionally in use during pre-login validation. In this snapshot, `getPublicConfig` does not expose initialization/onboarding/maintenance state or the full feature set. `getUserConfig` requires authentication. Preserve the startup checks until a complete replacement is available; the two validation call-site deprecation warnings therefore remain visible.

Migration was rechecked and deferred on 2026-11-08. Upstream `main`'s OpenAPI document version `3.4.0-rc.0` still exposes initialization/admin-onboarding state through `ServerConfigDto`, not `PublicConfigDto`; separate admin-onboarding reads require authentication. The [upstream web server-config manager](https://github.com/immich-app/immich/blob/main/web/src/lib/managers/server-config-manager.svelte.ts) also still calls `getServerConfig`. Keep the current calls until an appropriate replacement is available.

Run `Scripts/update-immich-schema.sh` from the Remmich repository root to refresh the snapshot deliberately. Review and update this provenance record in the same change.
