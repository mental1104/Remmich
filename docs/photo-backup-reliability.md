# Persistent photo backup

This branch is developing backup reliability independently of search CI. The original foreground upload UI still exists; the durable journal below is implemented but **not yet connected to that UI or its upload worker**. Do not advertise persistent backup as complete from these files alone.

The journal reuses the existing authenticated `MediaAccountScope` and per-account SQLite storage. It stores local PhotoKit identities/source modification versions, selected album identities, cloud-download consent, finite job stages and confirmed remote asset identities. It stores no credentials, original bytes, server error bodies or private paths. A separate auxiliary `photo_backups` table leaves existing schema/cache versions unchanged and is removed with its account storage.

| Event | Required behavior |
| --- | --- |
| Explicit album scan | Preserve scan order, deduplicate the same source, cancel unfinished older versions and recheck even previously completed items. A local receipt does not prove the server still retains that asset. |
| Upload start | Persist the next stage before any export or network side effect. Each explicit attempt increments once. |
| Live Photo | Motion receipt precedes the still upload; both identities and actual pairing verification are required before completion. No motion-only success. |
| Process interruption | Restore in-flight stages as paused with confirmed receipts retained. No upload starts merely because the journal was read. |
| Explicit resume/retry | Re-read the authorized source/version and perform server duplicate checks again; stored identities are not permission to skip validation. |
| Account/endpoint change | Cancel the old worker and revoke publication; jobs remain tied to the authenticated logical account scope. No cross-account replay. Runtime wiring remains to be implemented. |
| Deleted local account | Late journal writes fail rather than recreate the deleted account or overwrite another account. |
| Corrupt/future journal | Fail explicitly and preserve recovery data; do not replace it with an empty queue. |

Added Swift tests use real temporary SQLite files for cold reconnect/partial Live Photo recovery, account isolation, mismatched namespace and deletion followed by a late write. Domain scenarios cover stable order/dedup, explicit rescan verification, changed source versions, incomplete pairing and unknown format versions. NAS scoped SwiftFormat/diff checks pass; Swift compilation and test execution are pending unified CI. No real PhotoKit/iCloud account, private media, production server or background execution was used.

Remaining: connect the journal to a cancellable PhotoKit exporter, upload/verification worker and per-item UI; persist before network; stop old generations; validate real original/video/Live Photo/dedup responses with synthetic media; then add resumable/background scheduling, album exclusion/sync and explicit RAW+JPEG completeness. The existing foreground implementation still rejects unsupported RAW+JPEG combinations rather than counting partial backup as complete. Do not remove the device-space-cleanup exclusion or overwrite originals.

Rollback this component by reverting its model/storage/test methods. Existing account data and exports are unaffected; older app builds ignore the auxiliary table. Do not automatically delete pending backup journals or confirmed remote resources during a rollback.
