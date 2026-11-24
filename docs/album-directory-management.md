# Native album directory management

The stage4 directory slice adds **Albums → options → 相簿管理 → Manage categories and groups**. The sheet reads the current account's real directory and visible albums through the authenticated management channel. It does not require the separate batch timeline provider. Native SwiftUI remains the UI stack.

## Existing server behavior

Contracts were read from parent server `dev` at `65d467c788993a2b8ac3fcce13faff38be7a4f33`: `album-category.controller.ts`, its DTO/service/repository and table definitions, `album.controller.ts`/`album.service.ts`, `utils/access.ts`, and the Web `AlbumCategoryModal`, `AlbumEditModal` and bulk group behavior. No server, official mobile, generated SDK or API schema is changed.

| Intent | Actual existing request | Confirmation / permission |
| --- | --- | --- |
| Read personal categories and group placement | GET `/api/fork/album-categories` | 200, `album.read`; only this GET's 404/405/501 means extension unavailable |
| Read visible album group names | GET `/api/albums` | 200, real current response; group field may be missing/null for compatible decoding |
| Create category | POST `/api/fork/album-categories`, `{name}` | 201 plus valid UUID and matching name; `album.create` |
| Rename category | PATCH `/api/fork/album-categories/:id`, `{name}` | 200 plus matching ID/name; `album.update` |
| Delete category | DELETE `/api/fork/album-categories/:id`, no body | 204; `album.delete`; only the current user's category can be deleted |
| Move a whole group to a category | PUT `/api/fork/album-categories/group`, `{groupName,categoryId}` | 204; `album.update`; category must be owned and group must still be visible |
| Change an album's group | PATCH `/api/albums/:id`, `{customGroupName}` | 200 plus matching ID and an actual matching group field; `album.update` |

The system category `默认` is virtual. It cannot be renamed/deleted or created as a real category. Category names are trimmed, 1–100 UTF16 units; duplicate names return 409. An absent mapping means Default. Removing a category cascades only its personal group mappings: existing groups return to Default, and albums, media and sharing are preserved.

Groups have no separate persistent folder entity. Their names come from visible albums' trimmed `customGroupName`. Setting an owned album's name creates/joins a group; an empty input sends **explicit null** for Ungrouped. A category placement applies to every visible album with that group name for the current account, including the empty-string Ungrouped group. Assigning to Default sends **explicit null** as `categoryId`. New names use the server's actual existing placement after refresh, rather than assuming they inherit the source group category. An empty group is not retained as a new independent folder.

Personal category placement does not rewrite shared album properties. Changing `customGroupName` is an album property update visible to other authorized clients. The server permits album owners/editors; this slice's UI additionally restricts album moves to owned albums. Whole-group category placement still uses all visible groups, following the Web behavior.

## State, confirmation and refresh

Each change gets a fixed confirmation plan bound to page and account/endpoint generations. The store also binds its freshly read snapshot to the account generation, so the interval before SwiftUI observes a changed account cannot authorize a write from old data. Confirmation is consumed once; reusing it after a write or reload sends nothing.

Commands are single requests, without retry or a persistent upload/mutation queue. A confirmed write publishes one management revision, then performs new directory and album GET requests through the cache-disabled management URLSession. The page only re-enables writes after both succeed. These two GETs are not a server transaction, and the server remains authoritative for concurrent changes and permissions; there is no CAS contract.

A saved write followed by failed refresh keeps the saved notice and requires explicit reload. Permission/conflict/limit failures and unknown outcomes require reload before another confirmation. Wrong success status, malformed identity/field, 5xx or cancellation are never reported as saved and never automatically replayed; possibly affected readers are invalidated conservatively. Authentication failures do not become unsupported/empty success. Page dismissal cancels work, while account/endpoint changes also clear drafts, selection, confirmations and old publication rights. Raw responses, resource IDs, endpoints and credentials are not shown as error text.

The new sheet refreshes itself without the durable indexing GET cache. Root still owns the broader main Albums grid/category-filter refresh on management revisions, as recorded in the batch slice. No additional shared entry bridge is needed for this directory sheet once `AlbumManagementView` is reachable.

## Evidence and remaining work

Nine Swift test functions /39 parameterized scenarios are written against the real Store → manager → LibraryMutationClient → URLSession path. They independently assert all methods and complete request bodies, null/default/Ungrouped semantics, new server snapshots, delete preserving albums, exact status and ID/field checks, 401/403/404/409/429/503, unsupported GETs, failed refresh after a saved write, in-flight cancellation, and late reads/writes across account/endpoint transitions. Isolated random `.invalid` hosts and per-session URLProtocol reject all unintended network access; actor gates establish ordering without sleeps.

NAS checks completed: scoped SwiftFormat0.64.5 formatting/lint of seven touched Swift files, git diff whitespace checks, bash syntax for the offline contract script (its explicit compiler input list now includes the new directory domain), and Node22.22.3 syntax parsing of23 fixed JSON literals. Four dynamic JSON literals and all new Swift scenarios await actual Swift execution. Swift/Xcode is absent here: **compilation, tests, UI layout, real server writes and physical iPhone/iPad acceptance remain unverified**. No CI was started by this subtask; root controls unified CI. No production/private media was accessed or changed.

Stage4 still needs metadata writes (dates/location/rating/tags and relevant ownership/bulk behavior), shared-album member roles/invites/public links/partner sharing, and broader timeline/search selection. Group-wide album-name rewrites/bulk album movement are separate work; this slice provides single-owned-album movement and whole-group personal category placement. Existing batch management and cover selection still need the root integration and simulator/device evidence described in their document.

Rollback this independent directory branch's UI/domain/store/tests and newly added directory gateway methods while preserving earlier batch and shared editor work. There is no migration or local persistent directory queue. Rolling back the client does not undo user-confirmed directory writes.
