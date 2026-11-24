# Batch album photo management

This stage4 slice adds an account-owned album entry for selecting real album photos/videos, applying explicit batch actions and choosing an album cover. It retains the native SwiftUI layout and existing image cache. No upload, original replacement, permanent deletion, server code or API definition is added.

## Entry and integration

The intended reachable path is **Albums → options → 相簿管理 → owned album → Manage photos and cover**. `AlbumManagementView` accepts optional `source` and `media` arguments, preserving existing callers. Root owns the small `AlbumsView` sheet bridge that passes its actual `source` and `media`.

Batch management requires `ManagementTimelineProviding.managementTimelineReader()`. Every reload obtains an authenticated foreground reader instead of reusing completed durable GET responses. The ordinary time-bucket protocol is reused with the real album ID, nil visibility (including archived album members), all stacked members, no extra partner scope, and an explicit active/trash selector. Only loaded members can be selected; more pages are explicit and duplicate IDs are removed. The provider's repository implementation and conformance are owned by the parallel organization/root integration. Without that capability or media context, the batch entry stays disabled; a cached response is never advertised as freshly reloaded.

Root also owns refreshing the main Albums grid after writes. Its existing `store.load()` can still encounter completed album GET responses; root must bypass/invalidate those responses so the confirmed cover or membership changes become visible. The new batch page itself always obtains the foreground reader on reload.

## Actions and protocol

Actions use the existing explicit mutation client, with root's shared-contract commit `4a01d68` (local dependency `a054940`). They run serially through one real `LibraryManagementController.perform` operation so each selected item has an independently confirmed result; this is not an atomic server-wide batch.

| Action | Existing official request | Confirmation |
| --- | --- | --- |
| Favorite/unfavorite | `PUT /api/assets/:id`, only `isFavorite` | exact200 |
| Archive/timeline | `PUT /api/assets/:id`, only `visibility` | exact200 |
| Trash | `DELETE /api/assets`, one ID and `force:false` | exact204 |
| Restore | `POST /api/trash/restore/assets`, one ID | exact200 and count1 |
| Add/remove membership | `PUT`/`DELETE /api/albums/:id/assets`, one ID | exact200 and one matching successful result |
| Album cover | `PATCH /api/albums/:id`, only `albumThumbnailAssetId` | exact200 and matching album identity |

The owning server's controllers/DTOs/services were read at the local v3.4.2-based source. Asset property updates require `asset.update`; trash/restore require `asset.delete`; membership uses `albumAsset.create/delete` plus asset sharing/removal rules; cover requires `album.update` and the server verifies actual membership. Client property/trash actions additionally retain the existing owned-asset boundary. Cover/removal plans are restricted to the album that produced the current member list; cover requires one active member. Server permissions and membership remain authoritative even after a valid client selection.

## Confirmation, partial results and cancellation

The confirmation dialog captures the action, selected asset snapshots, album, read generation and manager account generation. Pagination or later selection changes cannot silently enlarge the confirmed set. Reloading or changing account/endpoint invalidates the old plan.

The UI retains separate states for confirmed items, explicitly rejected items, unknown results and remaining unsent items. A403 rejects that item and allows independent later items. A401/429 stops further sends. A timeout, cancellation,5xx, unexpected success status or unconfirmed membership response stops the rest and requires a fresh reload; no write is automatically retried. Existing membership wrappers do not expose individual failure reasons, so a `success:false` response is conservatively unconfirmed rather than falsely successful. The user can inspect/reselect after reload. Confirmed and uncertain changes trigger the existing publication signal once in the same account context; confirmed selections are removed and another operation is blocked until reload.

Result rows retain the confirmation-time thumbnail revision and show real thumbnails, not internal UUIDs. Reloaded items show favorite/archive/video badges so state can be checked. Stop cancels the in-flight task, preserves earlier confirmed results, marks a potentially accepted current write unknown and leaves later items unsent. Backgrounding stops sends. Account/endpoint changes cancel and clear the page; old reads and write completions cannot publish into the new context.

## Validation and boundaries

Added8 test functions with21 parameterized scenarios drive the actual Store→manager→URLSession→mutation-client chain. Only the read-page source and HTTP bytes are synthetic. They cover all action request paths/bodies/statuses, active/trash query scope, loaded-only selection and fixed confirmation,403 partial success versus401/429/201/503 stopping, owner restrictions, unconfirmed membership, a genuinely in-flight cancellation, account/endpoint changes, cover scope and invalid targets. Actor gates establish timing without sleeps; isolated per-host URLProtocol fixtures intercept every request and do not register globally or access the real network.

Actual NAS checks: SwiftFormat0.64.5 formatting/lint for six touched Swift files,13 fixed JSON fixture syntax checks using Node22.22.3, and `git diff --check`. There is no Swift compiler, Xcode or Apple device on NAS; these tests and the app have **not** been compiled or executed for this slice. Root owns the single CI chain after integrating the shared interfaces/entry. Search CI does not validate this branch.

Still unverified: root fresh-reader and main-grid invalidation integration, real authenticated server mutations, iPhone/iPad selection/confirmation/screenshots, user permissions and physical-device behavior. The broader stage4 work remains: global timeline/search selection, date/location/rating/tag writes, custom directory writes, shared-album roles/invites/public links and partner sharing. This slice does not claim those features or the full stage complete.

Rollback the independent batch UI/model/store/adapter/tests and album entry changes. Root's shared mutation/editor gateway is a separate dependency and may still be needed by other work. This feature has no persistent mutation queue or schema migration. Rolling back the client does not undo already confirmed user-initiated server changes; it does not permanently delete original media.
