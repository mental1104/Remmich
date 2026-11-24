# Persistent photo backup

This branch is developing backup reliability independently of search CI. The original foreground upload UI still exists; the durable journal below is implemented but **not yet connected to that UI or its upload worker**. Do not advertise persistent backup as complete from these files alone.

The journal reuses the existing authenticated `MediaAccountScope` and per-account SQLite storage. It stores local PhotoKit identities/source modification versions, selected album identities, cloud-download consent, finite job stages and confirmed remote asset identities. It stores no credentials, original bytes, server error bodies or private paths. Auxiliary `photo_backup_headers` and `photo_backup_jobs` tables leave existing schema/cache versions unchanged and are removed with their account storage. Each job has a stable ID, immutable scan position and indexed stage. Upload checkpoints validate/decode/encode only that job and update its existing row; they do not scan or rewrite completed history.

`loadPhotoBackups` remains the full cold snapshot, and `savePhotoBackups` remains the full transactional explicit-scan interface. Bulk replacement also validates existing recovery data before replacing it. They are intentionally O(N) in the number of stored jobs; the upload loop must not call them or the journal's linear `update` for each stage. Individual checkpoints use the primary key, and queue selection uses `(scope,stage,position)` with `LIMIT 1`; this removes the previous full-history serialization on every transition. This is a source-level complexity change, **not a measured device throughput result**.

| Worker call | Required boundary |
| --- | --- |
| `savePhotoBackups(journal,scope:)` | First persist an explicit scan to create tasks. Existing unknown versions or corrupt recovery rows fail instead of being replaced. Await success before starting any external work. |
| `nextQueuedPhotoBackup(scope:)` | Read one queued task in the original scan order. This is not a claim/lock: the caller still owns the single-worker and account/endpoint generation checks. |
| `savePhotoBackupJob(job,scope:)` | Update an already-created ID with exactly the same source snapshot. Unknown IDs/source replacement fail; a late single-item save cannot insert a deleted task, including after the same account reauthenticates. Keep a local mutable job and await every checkpoint before the next export/network side effect. |
| `pausePhotoBackupWork(scope:)` | Atomically pause queued and in-flight rows only, retaining confirmed receipts and terminal history. It persists cleanup even if the calling Task was cancelled. |
| `recoverPhotoBackupWork(scope:)` | Pause only interrupted in-flight rows. Queued rows remain queued, but this call does not run a worker or resume uploads. |

All entry points check the authenticated namespace/header version; hot writes do not create an absent header. Bulk and single-job writes, and queue reads, honor cancellation. Stop/recovery calls intentionally remain usable from cancellation cleanup. Storage alone cannot distinguish a superseded worker using the same authenticated scope: runtime account/endpoint generation checks remain mandatory before and after awaits.

An existing version-1 `photo_backups` blob is validated and converted once in a transaction: write the complete header/ordered jobs, then delete that old row. Any decoding/version/namespace/duplicate failure rolls back and retains the original blob. A simultaneous legacy blob and row header is rejected as ambiguous rather than choosing a snapshot. Future/corrupt row headers and corrupt existing job rows also block replacement. This unpublished component has no production migration; tests use only synthetic temporary files.

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

Added Swift tests use real temporary SQLite files for cold reconnect/partial Live Photo recovery, account isolation, mismatched namespace and deletion followed by a late write. A 512-task fixture installs actual SQLite INSERT/UPDATE/DELETE audit triggers, expects five checkpoints to update only the chosen Live Photo row, compares every other payload/position and checks the queue's query plan. Other scenarios cover indexed pause/recovery, rejection after deletion and same-account reauthentication, one-time legacy conversion, future/corrupt formats retaining raw recovery data, stable order/dedup, explicit rescan verification, changed source versions and incomplete pairing. NAS scoped SwiftFormat/diff checks pass; **these Swift/SQLite tests have not executed**, and compilation/execution are pending unified CI. No real PhotoKit/iCloud account, private media, production server or background execution was used.

Remaining: connect the journal to a cancellable PhotoKit exporter, upload/verification worker and per-item UI; persist before network; stop old generations; validate real original/video/Live Photo/dedup responses with synthetic media; then add resumable/background scheduling, album exclusion/sync and explicit RAW+JPEG completeness. The existing foreground implementation still rejects unsupported RAW+JPEG combinations rather than counting partial backup as complete. Do not remove the device-space-cleanup exclusion or overwrite originals.

Rollback this unpublished component by reverting its model/storage/test methods. Existing account data and exports are unaffected. Once a legacy blob has converted, older builds cannot read the new rows; preserve the account database and use the new reader or an explicitly reviewed export/conversion before resuming with an older build. Do not treat an old build's empty journal as permission to overwrite the row-based recovery data. Do not automatically delete pending backup journals or confirmed remote resources during rollback.
