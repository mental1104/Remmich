# Client and server maintenance

Server: mental1104/immich, local `dev` e69e65fba (official stable v3.4.2).
Client: mental1104/Remmich, `dev`; upstream `main` 672f02e. Branch spelling is lowercase, matching the existing server.

## API boundary

Official Immich clients keep their existing endpoints, authorization, DTOs and behavioral semantics. Remmich-specific incompatible requirements must use separate authenticated `/api/fork/...` routes. Do not change existing login, timeline, album, upload, edits or sync semantics. This change adds no server code, migration, database operation or production deployment.

The native album directory reads existing `GET /api/fork/album-categories` and `GET /api/albums` (optional customGroupName). Missing extension routes 404/405/501 fall back to standard albums. Authentication/network/schema failures are distinct from unsupported capabilities; standard albums remain usable. Results are memory-only and bounded to the current account/endpoint generation. Redirects are rejected.

## Inheritance assessment

| Server dev feature | Current client support | Remaining work |
| --- | --- | --- |
| Metadata extraction, job recovery, directory watches and deduplication | Existing server-side behavior benefits this client | Keep pipeline administration server-side; no NAS deployment performed |
| Standard media, HLS, EXIF and timeline/index APIs | Existing native rendering/playback/indexing | Representative playback acceptance; no X5 spherical renderer |
| Album groups/categories and flat album display | Native category/group filters and directory-name search | Category/group creation and assignment still Web-only |
| Original-file backup and upload deduplication | Manual foreground backup of selected phone albums, videos and Live Photo pairs | Persistent queues, automatic/background backup, original RAW+JPEG combinations and retrying individual failed items are not implemented |
| Favorites, archive, captions and recycle bin | Native viewer actions through official routes; trash/restore, no permanent delete | Batch selection and broader shared-editor UI |
| Albums | Create/rename/delete; add/remove a photo | Batch membership, shared album role management and directory writes |
| Non-destructive editing | Existing edits loaded; crop/rotate/mirror via official APIs; reset edits | Pixel-coordinate crop form has no real-time preview; no video/Live Photo editor. Server rejects unsupported panoramas/GIF/SVG |
| Search OR expansion, registered conditions, EXIF filters and scene stacks | Contracts audited, not exposed natively | Upstream Search still demo data; real paginated search, saved conditions and opt-in scene grouping remain |
| Photo copilot, AI edit advice/revisions/review | Not yet implemented | Native interaction and permission/error acceptance; use existing fork routes, add separate APIs only where required |
| Admin iPhone backup pipeline and queue dashboard | Remains server/Web functionality | This is distinct from the new native user photo backup flow |

NAS uncommitted `codex/feature-media-ai-analysis` work is excluded from the baseline. Do not publish it or treat it as a deployed API. The fork has no inherited read-only product restriction; deferred features are engineering gaps, not policy restrictions.

## Branches and builds

- Client `main`: fast-forward upstream/main only. Personal changes/builds are on `dev`; merge main into dev normally, preserving history.
- Server `main`: retain its existing official **stable release** policy; don't replace it with the Immich development main branch. Server personal changes/builds stay on dev.
- Build push/PR and workflow-run Tests target dev. Manual release is restricted to a successful tested dev revision. The Xcode 27 hosted runner uses an installed iPhone simulator without hard-coding an obsolete OS runtime.
- Run `Scripts/sync-upstream.sh` in a fresh clean clone, or dispatch **Prepare upstream sync** from dev. It fast-forwards client main then normally merges main into a uniquely named integration branch. Conflicts stop without reset/force-push. The workflow opens a PR targeting dev; it never automatically merges dev or deploys anything. PRs created with GITHUB_TOKEN need manually dispatched checks or a new human push because GitHub suppresses recursive workflow events.
- Push a validated child commit first. The parent submodule `clients/remmich` tracks dev but pins a specific commit: `git submodule update --init clients/remmich`, `git -C clients/remmich switch dev`, fetch/merge --ff-only origin/dev, validate, then commit the gitlink on server dev.
- Parent integration uses an isolated registered NAS worktree; preserve the dirty original media-AI workspace and all other worktrees. NAS filesystem execute bits may differ; use `git -c core.filemode=false` for this isolated integration's explicit staging rather than committing thousands of permission-only changes.

## Verification

- Initial downstream app build for physical iOS succeeded (unsigned compile).
- Offline write/category contract checks passed, including the multipart upload path, against fixtures only.
- Full formatting lint and git diff --check passed before final integration.
- Signed app/test build, on-device focused tests and final installation are recorded after execution in change.log.
- No private production media mutation was used to test these changes. Compilation and mocked contracts do not establish complete official-client coexistence or iOS backup acceptance. See [security boundaries](fork-security.md).

## Known Mac build pitfalls

On the M1 Mac with 8 GB RAM, concurrent compilation caused excessive swap/disk pressure. Use `xcodebuild ... -jobs 1 COMPILER_INDEX_STORE_ENABLE=NO`; preserve existing dependency/build caches. Both app and test targets must use the local Apple Team and unique bundle identifiers. Personal signing is for local builds; CI creates unsigned products, and distribution remains subject to the account's signing capabilities.
