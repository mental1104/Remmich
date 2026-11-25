# Saved-search panel UI acceptance

Independent branch `codex/test-saved-search-panel-ui`, based on `888e944ef4304ec1f5187139663749ffd8e8ab84`. This fills one specific acceptance gap after the existing search/preset state and HTTP-contract suites passed. It does not block or modify the active PR9 scheme repair.

## Real user flows

| New XCTest scenario | Actual user actions and independent evidence |
| --- | --- |
| Create, rename and apply | Enter Before and select Favorite; expand Saved searches and Reload; type Created and Save; rename to Renamed using its row menu; change current query/favorite, then click the saved row. Independently inspect actual POST/PATCH JSON and SDK metadata-search JSON for the saved text/favorite. |
| Replace and delete confirmation | Save Target; change text/favorite/media to After/nonfavorite/video; cancel replacement and verify zero PATCH, then confirm and inspect complete request. Change all three values again before Apply and verify saved values return in actual metadata JSON. Cancel deletion and verify zero DELETE/row retained; confirm deletion and require204-backed row removal. |
|409 draft and explicit retry | Existing is a preexisting synthetic server record. Attempt to Save that name; require the real409 error, draft retained and Save disabled. Change draft to Unique and prove no write; explicitly Reload, then click Save and verify confirmed new row/request. |

The three methods are in RemmichUITests/SavedSearchPanelAcceptanceUITests.swift. Tests use actual fields, toggles, buttons, menus and confirmation dismissal, bounded scrolling and independently parsed AX-captured HTTP JSON. Every scenario retains screenshots in xcresult. No fixture method performs a user action or marks a UI result complete. Empty metadata responses are deliberate fixtures; search-result rendering remains covered by the unchanged original five tests.

## Isolation and real code path

Only DEBUG plus all three arguments `-ui-testing-search`, `-ui-testing-signed-in` and `-ui-testing-search-presets` can select the host. Release still directly enters RootView. SearchView's DEBUG manager injection selects the real LibraryManagementController with an explicit session; the panel, Store, codec, mutation client, error mapping and confirmations run unchanged.

The host installs an actual URLSession into the original ImmichTimelineRepository through one DEBUG-only setup method. Reuse reaches existing repo→ImmichClient→authentication/SDK JSON→URLSession code. The fixture observes those bytes; it does not manufacture expected filters from the UI query. Wire filter.type versus preset mediaType are independently checked.

Two explicit ephemeral sessions use one session-local URLProtocol class with per-process random.invalid registration. All URLs are intercepted; unexpected host/path/auth/body yields a visible violation and failure. No global URLProtocol registration, real network, service/database, persisted account, media, Keychain or production context is used. Existing isolated media dependencies remain unconfigured with no account scope/endpoint, and their URL loader rejects access. Retirement closes sessions and removes private registration. In-memory records simulate documented HTTP statuses; they are not new service-persistence or HTTP-blackbox evidence.

This slice covers the critical409/draft failure rather than another account-late UI scenario. Existing search account-late UI and preset cancellation tests remain, but these3 cases do not prove saved-panel cross-account interaction acceptance.

## Selection and actual checks

Scripts/test-search-ui.sh now includes SearchAcceptanceUITests and SavedSearchPanelAcceptanceUITests selectors. It retains serial execution, xcodebuild exit propagation, preparation bounds and original five cases/32 assertions byte-for-byte. Future phone/tablet runs each select eight tests. The attachment exporter handles the whole xcresult without class/count whitelist, so new screenshots require no exporter edits. No workflow, trigger, runner or active CI was changed.

Actual NAS results:7 Swift files format/lint clean; shell syntax and whitespace clean;28/28 real-script simulator/xcodebuild stub assertions pass, including both selectors and prior failure/cleanup cases. Project/scheme XML files, original test file, SDK schema, production clients and Store source are unchanged from888. Evidence: `/volume2/codex-home/mental1104/tmp/remmich-saved-search-ui-20261125/`. These shell stubs never execute Xcode or UI tests.

NAS has no swiftc/xcodebuild. Compilation,3 new UI methods, actual AX/popover/keyboard behavior, target-server operation, physical devices and later integrated CI remain unverified. Current888/fed logs cannot fill this slice's runtime gate. Four gates: implementation25/25; available static25/25; client runtime0/25; integration0/25 (50/100). Root alone schedules subsequent CI/integration. No push/dev merge/production action occurred. Revert the DEBUG host, AX IDs and selector without data restoration.
