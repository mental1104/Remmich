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

- Saved-search contracts are local and pending CI: full typed conditions preserve null/missing values and unknown-field rejection; explicit CRUD methods use existing authenticated fork routes and exact statuses. SearchView capture/restore/management UI is not connected yet, so saved searches are not advertised as supported. No production writes performed.

- EXIF/orientation/album-state follow-up is local and awaits CI: metadata supports numeric atomic comparisons and exact extra filters; invalid values/slots reject before network. Smart+advanced combinations are explicitly unavailable until reliable pagination is implemented; no silent condition dropping. Minimal schema augmentation is pinned to the owning Fork. Saved conditions and other extended fields remain unfinished.

- Search suggestions follow-up adds current-account city/camera choices through official GET suggestions, with manual input fallback and stale-owner rejection. New synthetic request tests and Xcode validation are pending; no public Photon lookup is involved. Fork EXIF and saved conditions remain unfinished.

- Consolidated PR #3 now includes native domain search models plus filename/description/path/OCR/smart modes. PR #2 app checks found two forbidden Feature SDK imports; those checks remain intact, and mapping moved to Infrastructure. This revision awaits new CI. Metadata uses opaque cursors, smart uses official legacy page numbers; no claim that smart V3 has pagination. Fork EXIF, suggestions and saved conditions remain unfinished.

- People/date filter follow-up is implemented on codex/feature-search-people-dates but awaits CI: account-scoped people, optional local calendar boundaries, invalid-range rejection and explicit SDK error messages. Smart search, suggestions, Fork EXIF and saved conditions remain unfinished. Do not use older successful CI for this follow-up.

- Native search work in progress (PR #3): real metadata cursor results and legacy smart page results, people/calendar-day/city/camera/media filters, account-scoped suggestions, and Fork EXIF/orientation/album filters. Country/state and favorites/archive follow-ups are pushed asbcaf66f; CI45338292119 is running. A local rating follow-up adds metadata Any/Unrated/0–5 and legacy smart Any/Unrated/1–5, plus saved-condition reuse. Documented generator type overrides and equivalent extraction of a nullable schema leaf preserve explicit null; no generated Swift is hand-edited and no server contract changes. Swift validation is pending. Smart with advanced filters, including0, remains unavailable until reliable combined pagination is implemented. Favorites off means unrestricted; archive off preserves timeline scope, excluding hidden/locked content. Read-only search POST remains separate from durable GET indexing.
- Saved-search follow-up adds an account-scoped panel for create/rename/apply/confirmed replacement/delete using existing authenticated fork/search-presets routes. Reuse validates all conditions before replacing the query; unsupported conditions are preserved and cannot be partially applied. Rename re-reads full conditions; replacement re-reads the latest name, but the server has no compare-and-swap contract. Failed or cancelled writes require a reload, without automatic retry or photo changes. ca271bb passed complete CI45336010250, including the panel/codec tests, API tests, app compilation and simulator app tests; local region/visibility follow-ups still need separate CI. Neither this nor earlier successful builds establish device acceptance. Parent remains pinned to verified0af1897.

- CI simulator repair: Build and Tests independently select an installed iPhone with iOS 27+ using Scripts/select-ci-simulator.sh. The previous fixed iPhone 17 Pro was absent on the runner; this is unrelated to the user's physical iPhone 15 Pro. NAS syntax/synthetic checks passed; GitHub Xcode validation is pending.

- Initial downstream app build for physical iOS succeeded (unsigned compile).
- Offline write/category contract checks passed, including the multipart upload path, against fixtures only.
- Full formatting lint and git diff --check passed before final integration.
- Signed app and test build succeeded. iPhone 15 Pro installation and launch succeeded (0.7.1 build 5). Focused device tests: 35 passed, one parameterized location-route regression failed; privacy and account-generation tests passed. Regression patch is present; final rerun is pending. See change.log.
- No private production media mutation was used to test these changes. Compilation and mocked contracts do not establish complete official-client coexistence or iOS backup acceptance. See [security boundaries](fork-security.md).

## Known Mac build pitfalls

On the M1 Mac with 8 GB RAM, concurrent compilation caused excessive swap/disk pressure. Use `xcodebuild ... -jobs 1 COMPILER_INDEX_STORE_ENABLE=NO`; preserve existing dependency/build caches. Both app and test targets must use the local Apple Team and unique bundle identifiers. Personal signing is for local builds; CI creates unsigned products, and distribution remains subject to the account's signing capabilities.
