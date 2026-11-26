# Official native photo stack management

This branch `codex/feature-native-stack-integration` starts at the actual PR8 head `51e5d1099a60f90f3111e1d69d975b33fdecb24a`. It selects only the official stack slice from `87fabdaa1c455d61043d815f09602535c9ed46de`; it does not merge its ancestors or include scene commits `3492432`/`526b4a0`, Steam, iPad work or the independent candidate-denial patch `4413182`. The historical organization checkout remains `526b4a0`; compile-review `0f09949` only corrected people protocol isolation already present in51e5. NativeStackManaging is explicitly nonisolated.

## Concrete behavior

Library → **Photo stacks** shows a complete fresh official array with authenticated thumbnails, representative and visible-member count. Empty and permission/network failure remain separate. Missing representative or fewer than two visible members is read-only. Create/append candidates use real metadata search pages and retain their continuation even after filtering an empty page; selection cannot silently move members of another known stack.

Every relationship change is reviewed and confirmed with a fixed payload. Create chooses at least two own unstacked timeline images and an ordered representative. Add uses the official replacement-stack POST behavior, retaining the current representative. Changing representative, removing a non-primary member from a stack larger than two, or dissolving the whole relationship uses one corresponding official write. Originals are retained; there is no asset delete/trash, upload, original overwrite or keep-one/delete-others action.

Writes preflight the current visible member/representative set; new selected photos receive independent owner/type/visibility/trash/stack checks. Exact receipt identity/membership/status and a final fresh GET confirm success. Dissolution confirms absence in a fresh full owner list; an arbitrary400/404 does not prove deletion. Unknown/partial outcomes lock writes until explicit Reload and another confirmation, without replaying the write.

## Official API evidence and limits

Current parent source inspected at `120c93a6a266aab8344bf905b199d27251b88ca8`, plus the client's unchanged checked-in official schema. Source paths are `server/src/controllers/stack.controller.ts`, `dtos/stack.dto.ts`, `services/stack.service.ts`, `repositories/stack.repository.ts` and official Web `web/src/lib/services/stack.service.ts`. No service was started or changed during this work.

| Operation | Contract used |
| --- | --- |
| GET `/stacks` | `stack.read`, owner-scoped array,200, no invented pagination |
| GET `/stacks/:id` | `stack.read`, fresh preflight/final state,200; permission errors remain errors |
| POST `/stacks` | `stack.create` plus asset-update access; at least two UUIDs, first representative,201 |
| PUT `/stacks/:id` | `stack.update`, only `primaryAssetId`,200; chosen representative already a member |
| DELETE `/stacks/:id/assets/:assetId` | `stack.update`, non-primary current member,204; relation only |
| DELETE `/stacks/:id` | `stack.delete`,204; relation only, followed by fresh list absence |

Append follows official Web `[oldPrimary, ...newIds]`: the service creates a replacement stack and imports existing non-trashed members of included representatives. Hidden members may transfer but remain omitted from the visible response; trashed members lose the old relationship. Confirmation explicitly covers omitted members. No ETag/If-Match/CAS exists, so preflight cannot eliminate changes by another client between requests. The client detects observable mismatches and reports uncertainty; it cannot roll back an accepted remote relationship change.

The SDK additions are only two official GET operations in its generator-source filter and handwritten read wrappers/model. Raw OpenAPI, generated files, authentication/read-only operation policy and plugin dependency pins remain unchanged. Writes use the dedicated StackMutationClient with uncached ephemeral session, API-prefix-preserving paths, existing no-redirect delegate and no automatic retry.

## Account and cancellation ownership

ImmichTimelineRepository owns the writer. Account/token/endpoint changes and clear cancel the real session and advance the repository generation. Every async stack read/write success and error checks Task cancellation plus that generation before continuing. Store/view invalidation removes old lists, candidates, sheets, confirmations and cursors; old results cannot publish. Existing media management revision is published only for its original generation, so browsing can request refresh without claiming a device UI already reflects it.

The restored HTTP responder now uses explicit Sendable captures matching the current accepted fixture style. Actual write-request retirement waits for responder exit; gate cancellation and host cleanup release continuations. Held tests are time limited. Store late-list/write tests also clean up their gates.

## Four gates for this slice

| Gate | Credited | Concrete evidence |
| --- | ---: | --- |
| Implementation | 25/25 | Independent Library entry, relationship-only client/repository/Store, unchanged originals and current generation checks |
| Available NAS static checks | 25/25 | Eleven Swift files formatted/linted, full-tree lint, whitespace/shell syntax; Node verifies6 official routes/statuses, GET-only filters, complete synthetic DTO fields, unchanged raw schema/read-only policy/plugin pins and excluded scope |
| Swift runtime | 0/25 | No Swift compiler on NAS; contract script attempted and exits127 at `swiftc: command not found`. SDK generation, compilation and46 test cases unexecuted |
| Integration acceptance | 0/25 | No push/CI/dev merge, real server stack experiment, Photos/UI or device acceptance. Existing51e5 CI cannot validate this separate branch |
| Slice total | 50/100 | Stage5 as a whole remains incomplete |

`NativeStackManagementContractTests`:13 functions/40 cases through real repository/SDK reads and URLSession writes, including create/append/primary/remove/dissolve, exact statuses/body/receipts, unsafe candidates, repeated fresh reads, permission rejection, no replay and Task/account/endpoint/clear retirement at actual held requests. `NativeStackManagementStoreTests`:6 cases for uncertain-write lock, accepted-write/failed-refresh, late list/write rejection and empty/repeated cursor handling. Synthetic HTTP/system inputs are not real stack-service or device acceptance.

Rollback this isolated slice with its Library entry and SDK read additions. Preserve originals and existing account recovery files; no database/server migration is involved. Reverting the client does not undo explicitly confirmed stack relationships already accepted by the server.
