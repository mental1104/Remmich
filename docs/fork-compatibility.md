# Client and server maintenance

Lens follow-up: native lens filtering, make/model-scoped official suggestions and saved lens reuse are implemented on top of validated dev67ec731. New two-page wire/candidate/codec checks await CI after nullable repair PR #4 is integrated. The owning Fork's Chinese/EXIF lens-conversion correction is tested locally but not deployed; do not treat code presence as production or device acceptance. No photo writes or new server routes are introduced.

Server: mental1104/immich, local feature baseline `aa9aa667f` (official stable v3.4.2); new smart pagination is not deployed.
Client: mental1104/Remmich, `dev293c3e8`; upstream `main` 672f02e. Advanced smart follow-up is a draft and awaits its own CI. Branch spelling is lowercase, matching the existing server.

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
| Search OR expansion, registered conditions, EXIF filters and scene stacks | Native real metadata/legacy smart pagination, basic/EXIF/rating/lens filters and account presets are in dev | Advanced Fork smart cursor follow-up awaits CI; remaining fields, synthetic UI and scene grouping are unfinished |
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

- Advanced smart follow-up uses the existing local server's POST /api/fork/search/smart for complete structured combinations and a separate opaque continuation type. Missing404/405/501 is an explicit unsupported state only for that route; no silent filter stripping or fallback, and account/endpoint generation checks remain. Standard search and saved conditions remain usable. Full contract and validation scope: [advanced smart search](fork-smart-search.md). New Swift execution is pending; do not infer it from the successful lens CI.

- PR #4 passed full CI45346238915 at eabc102 (59 API tests, simulator app tests, artifact/source checks) and merged to dev5cd3acf with the same tree. Post-merge Build45348642591 is still running. Lens PR #5 now integrates that baseline while preserving both filters/tests, adds Any/Unrated/0/5 plus lens preset round trips, and stays draft pending its own CI after dev verification. Parent gitlink remains67ec731; no device acceptance or production deployment.

- PR #4 head8825298 failed CI45343739181 after successful app/test compilation and offline checks: one of59 API tests used the default SDK date transcoder but expected the application's millisecond encoding (five timestamp assertions). Simulator app tests were skipped. The fixture now explicitly uses the production ImmichDateTranscoder with all assertions retained; new CI is required before merging or updating the parent gitlink. No application or server behavior changed in this repair.

- Saved-search contracts are local and pending CI: full typed conditions preserve null/missing values and unknown-field rejection; explicit CRUD methods use existing authenticated fork routes and exact statuses. SearchView capture/restore/management UI is not connected yet, so saved searches are not advertised as supported. No production writes performed.

- EXIF/orientation/album-state follow-up is local and awaits CI: metadata supports numeric atomic comparisons and exact extra filters; invalid values/slots reject before network. Smart+advanced combinations are explicitly unavailable until reliable pagination is implemented; no silent condition dropping. Minimal schema augmentation is pinned to the owning Fork. Saved conditions and other extended fields remain unfinished.

- Search suggestions follow-up adds current-account city/camera choices through official GET suggestions, with manual input fallback and stale-owner rejection. New synthetic request tests and Xcode validation are pending; no public Photon lookup is involved. Fork EXIF and saved conditions remain unfinished.

- Consolidated PR #3 now includes native domain search models plus filename/description/path/OCR/smart modes. PR #2 app checks found two forbidden Feature SDK imports; those checks remain intact, and mapping moved to Infrastructure. This revision awaits new CI. Metadata uses opaque cursors, smart uses official legacy page numbers; no claim that smart V3 has pagination. Fork EXIF, suggestions and saved conditions remain unfinished.

- People/date filter follow-up is implemented on codex/feature-search-people-dates but awaits CI: account-scoped people, optional local calendar boundaries, invalid-range rejection and explicit SDK error messages. Smart search, suggestions, Fork EXIF and saved conditions remain unfinished. Do not use older successful CI for this follow-up.

- Native search is integrated in dev67ec731: real metadata cursor results, legacy smart page results, people/calendar-day/country/state/city/camera/media/favorite/archive filters, account suggestions, and Fork EXIF/orientation/album filters. PR #3 passed full CI45338292119; dev then passed Build45340652820 and Tests45341601145. Read-only search POST remains separate from durable GET indexing. Favorites off means unrestricted; archive off preserves timeline visibility, excluding hidden/locked content.
- PR #4 adds nullable rating/date encoding: metadata Any/Unrated/0–5, legacy smart Any/Unrated/1–5, saved rating reuse, and explicit non-trash filters for normal search/videos. Type overrides and equivalent nullable-leaf extraction preserve explicit null without hand-editing generated Swift or changing the server contract. New Swift/wire validation is pending; smart0/advanced combinations still need reliable pagination. Parent gitlink updates require pushed, validated child revisions.
- Saved searches in dev use existing authenticated Fork routes for create/rename/apply/confirmed replacement/delete. Reuse validates the complete supported query; unknown/unsupported fields are preserved and cannot be partially applied. Rename re-reads full conditions and replacement re-reads the latest name; the server has no CAS. Failed/cancelled writes require reload without automatic retry or photo changes. Package/simulator tests passed in dev67ec731, but physical-device acceptance remains unverified.

- CI simulator repair: Build and Tests independently select an installed iPhone with iOS 27+ using Scripts/select-ci-simulator.sh. The previous fixed iPhone 17 Pro was absent on the runner; this is unrelated to the user's physical iPhone 15 Pro. NAS syntax/synthetic checks passed; GitHub Xcode validation is pending.

- Initial downstream app build for physical iOS succeeded (unsigned compile).
- Offline write/category contract checks passed, including the multipart upload path, against fixtures only.
- Full formatting lint and git diff --check passed before final integration.
- Signed app and test build succeeded. iPhone 15 Pro installation and launch succeeded (0.7.1 build 5). Focused device tests: 35 passed, one parameterized location-route regression failed; privacy and account-generation tests passed. Regression patch is present; final rerun is pending. See change.log.
- No private production media mutation was used to test these changes. Compilation and mocked contracts do not establish complete official-client coexistence or iOS backup acceptance. See [security boundaries](fork-security.md).

## Known Mac build pitfalls

On the M1 Mac with 8 GB RAM, concurrent compilation caused excessive swap/disk pressure. Use `xcodebuild ... -jobs 1 COMPILER_INDEX_STORE_ENABLE=NO`; preserve existing dependency/build caches. Both app and test targets must use the local Apple Team and unique bundle identifiers. Personal signing is for local builds; CI creates unsigned products, and distribution remains subject to the account's signing capabilities.
