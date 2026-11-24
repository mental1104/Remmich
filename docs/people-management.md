# Native people management

The existing Library → People cards and person timelines remain the browsing flow. A native **Manage** sheet adds **rename your record**, **hide/show**, and a directed **two-person merge**. This is one stage-5 slice; native asset stacks, Fork scene stacks and Steam presentation remain separate unfinished work.

| Action | Verified source contract and client boundary |
| --- | --- |
| Load/Reload | Official `GET /api/people?withHidden=true&page=N&size=250`, `person.read`. The new SDK management reader preserves hidden state and actual update dates without changing the existing visible-only reader/model. The repository uses a foreground client, reads all real pages, checks cancellation/generation after every page and rejects a non-progressing continuation. A fresh complete result updates normal browsing with visible people only. |
| Rename | Public official `PUT /api/people/:id`, `person.update`, exact `200 PersonResponseDto`. Only `{name,userId:<current authenticated user>}` is sent. The UI says the change is for your account; an empty name is supported as Unnamed. No birthday or other users' records are intentionally rewritten. |
| Hide/show | Same public PUT and permission, only `{isHidden}` is sent. This changes the person list; it does not hide assets, change photo visibility, trash photos or delete media. Hidden people remain manageable for reversal. |
| Merge | Current official `POST /api/people/merge`, `person.merge`, exact200 `BulkIdResponseDto[]`. Sends `[targetID,sourceID]` in this order, requires exactly one successful error-free receipt for both UUIDs, and never treats HTTP200 or a target-only receipt as full success. No fallback to deprecated `/:id/merge`. |

The owning sources are `server/src/controllers/person.controller.ts`, `server/src/dtos/person.dto.ts`, `server/src/services/person.service.ts`, Web `PersonEditModal.svelte`, `person.service.ts` and `MergeFaceSelector.svelte` in the current parent official v3.4.2/Fork source. The service keeps the first defined name/birth date in merge order and can also merge linked people for other users in the cluster. The confirmation explains this actual cross-user effect and directs the chosen source into the chosen target. Photos are retained; this client offers no undo for the merged identities. Permissions remain server-authoritative, including per-person access and partial merge outcomes.

Each change requires a visible review/confirmation. The repository freshly GETs the selected person, or both merge participants, before writing; changed displayed fields stop the operation and require Reload. The server exposes no transactional If-Match contract here: this preflight does **not** eliminate a concurrent update between GET and PUT/POST. A successful response is checked against the requested UUID and changed value, then the UI reloads the full fresh list. Write errors, unexpected responses or partial results disable further writes until an explicit Reload succeeds; writes are never automatically replayed. If the write was accepted but list reload failed, the error says so and retains the previous list. Possible changes also notify the existing index refresh mechanism, without asserting success.

`PeopleMutationClient` exposes only a person GET, field-scoped person PUTs and the directed merge POST. It uses the same Bearer/no-cookie/no-cache/no-redirect rules and redirect delegate as the existing write channel; the existing `LibraryMutationClient` and SDK read-only policy are untouched. The original repository owns this client. Account, credential, endpoint and clear transitions invalidate its URLSession; every preflight and write rechecks the original repository generation/cancellation before continuing or publishing. The sheet owns its Tasks and clears records/confirmation on teardown/context change. No people list, pending confirmation or result is persisted across accounts by this feature.

## Validation status

Added tests cover a real Store→repository→SDK GET→person preflight→PUT→fresh GET rename cycle; exact request fields, auth/API prefix and directed IDs; hidden pagination/date mapping and repeated fresh reads; precise status failures with no replay; partial/missing/duplicate/wrong-ID merge receipts; stale preflight preventing a PUT; and account/endpoint/clear while an actual URLSession GET is in flight. Separate state tests hold a decoded successful provider return to prove late account results cannot publish or start a follow-up refresh, enforce Reload after partial merge, and distinguish accepted-write/failed-refresh states. HTTP fixtures are local URLProtocol/SDK byte loaders, not production requests.

NAS has no Swift/Xcode: scoped SwiftFormat0.64.5 and whitespace checks pass; **compilation, the new Swift tests, simulator UI and real-device/server acceptance have not run**. There is no claim of real face/media processing, physical-device acceptance or completed stage5. No workflow, CI run, push, server/API migration, production setting or private photo changed.

## Device/server acceptance still required

| Scenario | Expected result |
| --- | --- |
| iPhone15 Pro / iPad Pro2022 11-inch | People browsing and management sheet fit portrait/landscape; navigation, picker and confirmation remain reachable. |
| Rename/empty name | Confirmed personal rename appears after reload; another shared user's name is retained; empty name displays Unnamed. |
| Hide/show | Normal People cards omit hidden person; Manage can show the person again; asset visibility and photos remain unchanged. |
| Directed merge | Confirm target/source and any shared cluster consequences on synthetic people; both exact receipts and fresh list must agree. |
| Permission/partial result/offline | Visible failure; no automatic duplicate PUT/POST; Reload alone recovers write eligibility. |
| Account/endpoint/teardown | Old UI/confirmations clear; cancelled or late responses cannot update the next context or start another write. |

Rollback the new UI/domain/repository/client/SDK-reader additions. Server-side personal metadata or merged identities already changed by an explicitly confirmed action are not automatically undone by reverting the client. Do not delete photos or attempt a compensating merge during rollback.
