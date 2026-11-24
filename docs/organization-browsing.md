# Native random photos and pending albums

Library now exposes **Random photos** and **Pending albums** through the existing native card navigation. Both use authenticated account data, existing thumbnails/viewer and account/endpoint invalidation. They do not create fixture photos, alter the normal Albums page or write server media.

| Entry | Owning contract and behavior |
| --- | --- |
| Random photos | Official `POST /api/search/random`, `asset.read`, structured `filter.type.eq=IMAGE`, `visibility.eq=timeline`, `trashedAt.eq=null`, `size=60`, `withExif=true`. Each call asks the server for a random selection from the eligible scope. The response is an **unpaged array**; there is no cursor or Load more. Shuffle/pull-to-refresh requests another batch, which can overlap the previous batch. Duplicate IDs within one response are shown once. |
| Pending albums | Matches `web/src/lib/queries/album.query.ts:getPendingAlbumsQuery`: only albums owned by the signed-in user whose server `customGroupName.trim()` is exactly `待整理`. This does **not** mean assets without albums or tags. The directory comes from existing Fork category/group reads; standard servers without the extension show an explicit unavailable state while ordinary Albums stays usable. |
| Pending album contents | Uses the existing native `LibraryCollectionTimeline`, real album-scoped time buckets and lazy bucket loading. Includes stacked/archived album members, excludes trash and does not mix partners. No invented offset or local randomization substitutes for server queries. |

The random endpoint matches the existing Web `/random` contract in `web/src/lib/queries/search.query.ts`; only its request is expressed with the already pinned structured filter. The SDK operation is added to the generator filter, with exact operation/method/path read-policy checks. Queued clients forward that POST to the existing ephemeral foreground transport; the durable GET loader is never used. Default random reads also reuse that no-cookie/no-cache/no-redirect transport. Authentication, 401/403/429/5xx errors and late cancellation remain actual failures, never successful empty batches. Responses outside the requested type/visibility/trash/size scope are rejected.

Refresh replaces a confirmed random batch; failures retain its prior media plus an explicit error. Opening the native viewer freezes that batch and order until it closes. Changing account/endpoint clears results and selection and revokes old responses. Pending albums distinguish unavailable extension, a confirmed empty result and an error. They read a fresh foreground album list plus the existing fresh directory instead of reusing a completed GET from the Library index queue; both reads must still match the same original repository generation.

## Fresh management reader shared with stage 4

`ImmichTimelineRepository.managementTimelineReader()` returns a facade bound to the original repository and the generation at its creation. Each bucket/asset call re-enters the original actor, checks cancellation/generation, performs a new foreground SDK GET without transfers/collection caches, and checks generation/cancellation again before returning. Old facades cannot start new reads after an account, credential or endpoint change; already-in-flight successes cannot publish afterward.

The SDK's narrow `foregroundReadClient` factory reuses the existing restricted foreground session and normal middleware; default clients and indexing queues are unchanged. A repository test `readLoader` remains injectable but does not pass through persistent transfer logs. Management-album `memories()` returns an empty list, matching existing AlbumTimelineReader semantics, with generation/cancellation checks. It does not fetch unrelated global memories. The root maintainer connects the stage-4 `ManagementTimelineProviding` conformance when integrating both branches; this branch deliberately does not depend on that unmerged protocol.

## Evidence and limits

Added SDK contracts check exact random POST JSON/scope, refresh calls, queue separation, authentication/status errors, invalid responses, forbidden operation reuse and late cancellation. Native tests check the exact owned/group rule, album timeline scope, replacement/deduplication/error states, absent extension and late account results. Fresh-reader tests drive real SDK GET construction/authentication and decoding, show repeated same-scope calls reach the loader again, reject obsolete facades/in-flight responses for account/endpoint/clear changes, and propagate cancellation.

All accounts, URLs, media metadata and HTTP bytes are synthetic. NAS has no Swift or Xcode: scoped SwiftFormat0.64.5 and whitespace checks passed; **Swift compilation, package/app tests, iPhone/iPad UI and actual server/media acceptance have not executed**. No workflow, CI run, PR, push, production configuration/migration or private photo was used for this subtask. Generated Swift and schema snapshots remain unchanged. Source endpoint/permission evidence is from the current parent official v3.4.2/Fork source, not a claim of production deployment.

Rollback this client feature and generator operation selection; no server data or stored media requires recovery. Ordinary Library collections, Albums and official clients retain their routes.

## Remaining stage-5 slices

| Slice | Next concrete behavior and owning source |
| --- | --- |
| People management | Implemented in the following independent slice: native Manage sheet, personal rename, hide/show and directed two-person merge with fresh reads, confirmations and exact receipts. Swift/device/server acceptance remains pending; [people management](people-management.md) records the boundaries. Birth dates, favorites, face reassignment and feature-face selection remain outside this slice. |
| Official native stacks | Browse members and add primary/create/merge/unstack actions via official `/api/stacks` read/create/update/delete permissions. `StackCreateDto.assetIds` requires at least two IDs and first becomes primary; do not substitute scene grouping for this relationship. |
| Fork scene stacks | Read authenticated `POST /api/fork/scene-stacks/query` with at most5000 currently loaded IDs; response `available/groups{id,coverId,members}` is an outer presentation layer. Validate complete/non-overlapping visible members, preserve original stack semantics, handle unavailable/invalid evidence by showing the original timeline, and retain a user switch. |
| Steam scene presentation | Reuse existing backend grouping evidence and rendering policy. The current scene reply exposes IDs/cover/members, **not game names or engine controls**; first inspect the actual manifest/data contract before promising game labels. Keep GPU/scanning/model scheduling on the server. |

The random/pending entries do not implement the remaining stack/scene/Steam slices. The separate people-management slice is implemented in source with unexecuted Swift/device acceptance; it does not complete stage5.
