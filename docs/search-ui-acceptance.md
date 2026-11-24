# Synthetic search UI acceptance

The shared `RemmichSearchUI` scheme builds the app and `RemmichUITests`. It runs five XCUITest scenarios against the real `SearchView`, `NativeSearchStore`, native grid and asset viewer. It does not test the normal app shell, HTTP wire behavior or a real account.

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

The selector prefers iPhone 15 Pro and iPad Pro (11-inch) (4th generation, 2022). If the installed runtime lacks those names, it uses an available iPhone or 11-inch iPad Pro, respectively; `device.json` records the actual name, runtime and UDID. iPhone XS is excluded. A simulator UDID can replace `phone`/`tablet`. An existing output directory is rejected to preserve previous evidence. The runner keeps `SearchUI.xcresult` screenshots and its log, and performs no workflow or remote CI operation. The script defaults to `-jobs 1`; `REMMICH_UI_BUILD_JOBS` can explicitly raise this on a capable host.

The equivalent test target is `RemmichUITests/SearchAcceptanceUITests`; scheme `RemmichSearchUI`, Debug configuration, `-parallel-testing-enabled NO`. The ordinary `RemmichTests` suite remains separate. A maintainer may reuse a built simulator product via `build-for-testing` and `test-without-building` in their CI integration; this change does not modify CI triggers or notifications.

## Isolation and limitations

The host is compiled only with `DEBUG` and activated only when **both** `-ui-testing-search` and `-ui-testing-signed-in` are present. It bypasses `RootView`, background-sync registration and old background-session callbacks, constructs no real account repository, leaves media scope/endpoint unset and uses a fresh preferences suite. It calls the production management generation mechanism directly, rather than normal media configuration (which restores export queues). The unused export dependency has an isolated temporary store/empty transfer queue and is never configured or started. Search reads are an actor with no HTTP dependencies; detail reads are pure memory without GPS; thumbnails/viewer pixels reuse the existing explicitly flagged PNG fixture. People/tag/suggestion loading sees a nil repository; preset writes see a nil management client. Release builds have no host or data source.

No photo library permission, uploads, edits, server writes or real photos are required. The fixtures cover UI state publication, not API success or actual server capabilities. The independently defined API/unit tests must still run. True device UI, iPad multitasking, accessibility/Dynamic Type, screenshot review, preset CRUD, all filter combinations, actual photo/video/Live Photo display and official-client coexistence remain separate acceptance items.

Added on Linux/NAS without Swift, Xcode or Apple devices. Swift compilation and simulator execution are **not yet verified**; SwiftFormat and static project/shell checks are reported in `change.log`. Do not count these scenarios as passed until the macOS execution evidence exists.
