# Security review for the personal fork

Reviewed 2026-11-24 against upstream 672f02e and the downstream change set. This is a source/provenance review and focused testing, not proof that every dependency or future release is malware-free.

## Reviewed boundaries

- Xcode build phases run a local formatter and embed the Git revision. The only package build plugin is Apple's Swift OpenAPI generator at the resolved revision. No new remote build script, analytics, advertising, remote-code loader or credential destination was added.
- The app's new write channel sends authenticated requests only to the currently validated Immich endpoint. Account, credential or endpoint changes invalidate the old URLSession and generation; stale completions cannot publish to the new account. Requests do not follow redirects, retain cookies, cache authenticated responses or disable TLS verification. Existing user-configured HTTP endpoints remain supported; use HTTPS across untrusted networks.
- The generated browsing SDK retains its mutation denial policy. New writes have explicit methods and fixed official routes, UUID validation and field-limited bodies. Tokens and media are not logged or committed. Errors show HTTP status rather than raw private server responses. There is no permanent-media-delete or original-replacement method.
- Deleting a photo sends `force=false` and is labeled as moving to trash. Retention/cleanup remains a server policy. Album deletion removes organization, retaining media. Both have confirmation dialogs. Removing an image from an album does not delete it.
- Uploads require selecting phone albums and starting backup; iCloud downloads are off initially. Original resources and multipart bodies use temporary files and bounded chunks, cleaned on completion/error. Live Photo pairing failures and unsupported RAW+JPEG originals are not reported as complete. Failed uploads may leave a hidden motion asset on the server; retries use server checksum deduplication, without silently deleting remote data.
- Upstream public Photon reverse geocoding sends photo coordinates to photon.komoot.io on demand. This fork defaults public lookup to **off**, including migrated preferences, and provides an explicit switch in Maps & Places. Existing cached place names may still display. Map tiles still follow the server-configured source; Test & Save makes an explicit endpoint probe.

## Dependency/build provenance

- Swift packages are resolved in committed Package.resolved files. Direct package versions: Nuke 13.2.2, MapLibre distribution 7.0.0, Swift OpenAPI generator 1.13.1/runtime 1.12.1/URLSession 1.3.1, HTTP Types 1.8.0. MapLibre's binary dependency uses the package's checksum. Transitive dependencies and prebuilt binaries were not exhaustively audited internally.
- All GitHub Actions references are pinned to full commits resolved from the official actions/* repositories. SwiftFormat 0.64.5 is downloaded from its official GitHub release; SHA-256 `ec017c91fdd46233e5a22dc43ff9564a3cc4b37023d3b4681b6c7d7b781de113` is checked before execution (matched GitHub release asset metadata).
- Build/test default branch is dev; releases are manual and require matching successful Build/Tests receipts for a dev revision. No NAS deployment, image push, database migration or automatic media changes are part of CI.
- The downstream SideStore catalog has no versions until a downstream release exists; upstream IPAs must not masquerade as this fork's builds.

## Checks and limits

`bash Scripts/check-fork-contracts.sh` runs against an in-process URLProtocol fixture, not a real library: route/auth headers, no-force trash, ID rejection, permission denial, album partial failures, streaming SHA1, duplicate/trashed duplicate handling, multipart upload, crop-first edits and fork category filtering. App tests cover public-coordinate consent and account generation isolation.

No real private photo was uploaded, edited or deleted by the agent for testing. Foreground backup/export, quota failures, iCloud originals, Live Photos, edit rendering, actual shared-account permissions and official-client coexistence need representative device acceptance. GET-before-PUT edit checks detect changes since opening the form but are not an atomic cross-client compare-and-swap; the current official API has no such precondition.
