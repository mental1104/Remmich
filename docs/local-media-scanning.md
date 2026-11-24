# Automatic local media association

`codex/feature-local-media-scan` starts fromb79bfa2 with the independent current-reader9251200 and checksum-reader288ed84. It adds a real Controller, independent settings page, public PhotoKit inventory/change observer and account-scoped atomic JSON recovery. Root owns MediaLibraryController/settings/foreground entry wiring. No server/official-client API, backup, SQLite, production, push or CI change is made here.

## Entry and lifecycle

The host keeps one LocalMediaMatchController. After configuring media, call configure(using:manager,scope:mediaScope) and restoreAndRefresh(using:manager,scope:mediaScope); explicit nil scope clears login. Single-argument configure is an online-manager convenience. Explicit scope is required offline, because management.backupScope becomes nil without its client. Same namespace route/offline changes cancel scans while retaining confirmed maps; different server/account clears memory and restores its own namespace. association(assetID:revision:) requires the configured manager generation, exact remote Date, enabled preference and unchanged Photos authorization. Observable revision changes with the maps. Actual native media reads still recheck expected local modification version.

Opening/restoring never prompts for Photos permission. User enable/scan is the only requestAuthorization path. Enabled preference is saved even if access is denied. Next launch restores enabled state/maps; existing authorization plus connectivity starts one automatic foreground refresh per management generation. Repeated lifecycle calls reuse work or avoid another full scan. The host must also call restoreAndRefresh on foreground return to observe Settings permission changes. No background scheduler is added.

Public Photos notifications immediately invalidate old sources and coalesce a400ms refresh. Permission loss makes association return nil so the same account can use Immich fallback. Changed sources are saved as invalidated; no new permission prompt or original download is triggered. Disable unregisters observation and saves disabled config. Cancel stops current work; another local change or new connection generation may refresh an enabled feature later.

## Scan and proof

Only current authorized image/video IDs are enumerated; limited access is a visible subset. Enumeration yields every256 objects. Metadata uses <=64-item batches; pass one keeps only Cloud IDs, one complete server stream is read, then pass two reads fresh local snapshots in finite batches. This avoids retaining all resource snapshots or repeatedly requesting the full stream per64 objects.

Unique exact official Cloud ID/time/adjustment/location candidates take precedence. Bad metadata blocks that Cloud ID's metadata path; duplicate valid candidates stay ambiguous. Every selected candidate fresh-checks exact remote ID, owner, IMAGE/VIDEO type, explicit non-trash/non-offline/non-edited state, finite precise revision and canonical20-byte Base64 SHA1. Missing state remains unknown. Scanning never reads remote photo/video bytes.

Otherwise LocalPhotoChecksumReading can supply a strict network-disabled current-byte proof. proof.source must exactly equal the local snapshot after only cloudIdentity becomes unavailable. At most64 SHA1 queries are sent per batch, with exact response-ID correspondence. noMatch/trashed is only unconfirmed, never upload/restore. Existing results need the same fresh checks plus exact Base64 checksum equality. Edited/RAW+JPEG/Live Photo resources without a safe metadata relationship can remain unconfirmed under the conservative hash policy.

Counters describe real processed local items and distinct confirmed remote associations by metadata/checksum source; progress never implies success or backup. Network/protocol errors show incomplete scanning. Negative fresh details remove old same-ID associations immediately; successful completion retains only this scan's confirmed remote IDs. Every await checks cancellation, manager generation, scope and authorization. Cancellation/account changes revoke final atomic-write permission; late work cannot replace a newer context's document.

## Recovery and offline semantics

LocalMediaAssociationStore writes Application Support/LocalMediaAssociations/<namespace>.json with Data.write(.atomic). Namespace is existing server/user SHA256. Versioned data contains enabled preference, observed authorization and associations, without tokens or media bytes. Unknown future/corrupt documents, duplicate IDs, bad SHA1 and wrong namespace fail closed without replacement. Actor serialization and a synchronous permit lock order cancellation against final atomic commit. Newly confirmed partial progress is usable in this run; only completed confirmation snapshots are saved as the latest scan.

Offline cold restore accepts previously confirmed maps at the exact indexed remote revision and authorization range. Without networking it cannot assert new remote edits/deletion; it retains the last verified version while actual native reads validate Photos identity/version. Reconnection refreshes details. Maps are display hints, never original-byte backup receipts or authority to delete photos. Server isEdited=true retains remote edited display. Local Live Photo still is supported; motion remains outside this slice.

## Verification and rollback

Thirteen functions/31 parameterized cases exercise real Controller/atomic JSON over synthetic inventory/metadata/hash/network boundaries: unique/unsafe details, ambiguity, hash/fresh checks,64-item batching, held fresh cancellation/account change, offline/cold/automatic recovery, permission loss, lifecycle deduplication, strict version wire, future documents, revoked writes and namespace isolation. No real Photos/account/media/network access is used. Seven-file scoped SwiftFormat0.64.5 and diff checks passed on NAS. Swift compilation/runtime, Photos notifications/permissions, cloud-only fallback and iPhone image/video/UI acceptance remain unverified pending root's CI/device work.

Revert these isolated files and their root host bridges together. Retain recovery files on temporary rollback; never downgrade an unknown format. No server or media migration is required. iPad work remains paused.
