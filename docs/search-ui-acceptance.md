# Synthetic search UI acceptance

The shared `RemmichSearchUI` scheme builds the app, `RemmichTests` and `RemmichUITests` together. Its script selects five XCUITest scenarios against the real `SearchView`, `NativeSearchStore`, native grid and asset viewer. It does not test the normal app shell, HTTP wire behavior or a real account.

| Scenario | Assertion and evidence |
| --- | --- |
| Blank / results / viewer | Blank input has no results; synthetic query loads two assets; tapping a tile opens the native viewer and renders local pixels. Screenshots retained. |
| Pagination error / retry | First page remains on second-page failure; retry succeeds; duplicated server ID appears only once. |
| Filter / rotation / keyboard | Favorites changes two results to one; landscape and portrait screenshots retain a hittable search field while the keyboard is open. This is a basic layout assertion, not full visual or overlap approval. |
| Account switch / late response | Wait until alpha's request installs its suspension gate; switch real management generation; beta's request releases alpha's response; wait until alpha's store publication/cancellation check finishes and assert beta results remain. No timer substitutes for request entry/completion. |
| Empty / error | Empty response shows no-results; failure shows an explicit error with retry. |

## Execution

Use an existing macOS Xcode 27 installation with an available iOS 27+ simulator and `jq`. No device signing or real credentials are used. Run one build at a time:

```sh
bash Scripts/test-search-ui.sh phone /tmp/remmich-search-phone
bash Scripts/test-search-ui.sh tablet /tmp/remmich-search-tablet
```

The selector prefers iPhone 15 Pro and iPad Pro (11-inch) (4th generation, 2022). If the installed runtime lacks those names, it uses an available iPhone or 11-inch iPad Pro, respectively; `device.json` records the actual name, full runtime and UDID in both artifacts and stdout. Version parsing accepts runtime identifiers with a device suffix. iPhone XS is excluded. A simulator UDID can replace `phone`/`tablet`. An existing output directory is rejected to preserve previous evidence. The runner keeps `SearchUI.xcresult` screenshots and its log, and performs no workflow or remote CI operation. The script defaults to `-jobs 1`; `REMMICH_UI_BUILD_JOBS` can explicitly raise this on a capable host.

The UI test target is `RemmichUITests/SearchAcceptanceUITests`; scheme `RemmichSearchUI`, Debug configuration, `-parallel-testing-enabled NO`. App logic remains selectable as `-only-testing:RemmichTests`. A third script argument strictly reuses an already-built DerivedData directory: it requires exactly one `Build/Products/RemmichSearchUI_*.xctestrun`, uses `test-without-building -xctestrun` with only the UI target, and fails on missing/ambiguous manifests. It never falls back to compilation. For example, after the combined scheme's `build-for-testing`, invoke the phone/tablet commands above with the same DerivedData path appended as their third argument.

## Pull request CI

The existing Build job selects the combined scheme for ready PRs, builds the app/logic/UI bundles once, and runs API tests, app logic and the phone/tablet UI suites. UI devices execute sequentially on that runner with the same products; a device failure remains a job failure while the other device still executes if the build succeeded. The existing always-upload PR artifact now includes both devices' `device.json`, `xcodebuild.log` and `SearchUI.xcresult`, retaining failure screenshots when Xcode produces them. No error is converted to success and no signing/plugin-security bypass is added.

Before upload, an always-running PR/build-success step exports all attachments from each **existing** device result with `xcresulttool export attachments --path <result> --output-path <device>/attachments`. The original artifact also includes `attachments/` (original PNGs/other attachments and the tool-generated `manifest.json`) and `attachment-export.log`. These files can be reviewed on NAS without Xcode; the manifest maps the original exported attachment names to their tests. No screenshot or manifest is synthesized for an unrun device. A valid empty tool-generated manifest does not prove screenshot capture; review its actual entries. Export errors, missing/invalid manifests and existing output directories fail the step; the other device still gets an export attempt, and the original result/log/metadata stay available.

Apple's [Xcode 16.3 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes#xcresulttool) identify the attachment command and recommend the tool's own help for its exact options; the Apple-authored [xcresulttool CLI manual (mirror)](https://keith.github.io/xcode-man-pages/xcresulttool.1.html) documents `--path`/`--output-path` and the optional failure-only filter. The exporter deliberately omits that filter to retain successful test screenshots too. It records `xcresulttool version` and `help export attachments` from the installed runner before exporting; this provides the actual Xcode 27 CLI evidence when CI runs. The new export has **not** been executed with Xcode 27 on this NAS and does not turn previous test bundles into reviewed screenshots automatically.

Draft skipping and `ready_for_review` remain unchanged. No trigger, job, runner or runtime download is added. Existing `dev` push Build still uses the original `Remmich` scheme and preserves the product/revision receipt consumed by Tests and release validation. UI execution is added only to the PR path. CI notification settings are unchanged.

## Isolation and limitations

The host is compiled only with `DEBUG` and activated only when **both** `-ui-testing-search` and `-ui-testing-signed-in` are present. It bypasses `RootView`, background-sync registration and old background-session callbacks, constructs no real account repository, leaves media scope/endpoint unset and uses a fresh preferences suite. It calls the production management generation mechanism directly, rather than normal media configuration (which restores export queues). The unused export dependency has an isolated temporary store/empty transfer queue and is never configured or started. Search reads are an actor with no HTTP dependencies; detail reads are pure memory without GPS; thumbnails/viewer pixels reuse the existing explicitly flagged PNG fixture. People/tag/suggestion loading sees a nil repository; preset writes see a nil management client. Release builds have no host or data source.

No photo library permission, uploads, edits, server writes or real photos are required. The fixtures cover UI state publication, not API success or actual server capabilities. The independently defined API/unit tests must still run. True device UI, iPad multitasking, accessibility/Dynamic Type, screenshot review, preset CRUD, all filter combinations, actual photo/video/Live Photo display and official-client coexistence remain separate acceptance items.

Added on Linux/NAS without Swift, Xcode or Apple devices. Swift compilation, cross-device reuse of the combined Xcode products, simulator execution and the amended workflow are **not yet verified** on macOS; SwiftFormat, static project/shell checks and mock-only script orchestration are reported in `change.log`. Do not count these scenarios as passed until the macOS execution evidence exists. This branch has not pushed or started CI; the main maintainer schedules the validation run.
