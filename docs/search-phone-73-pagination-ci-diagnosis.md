# Phone pagination acceptance: one exact AX query

The fixed PR9 head `73dda3df890057a754d7a0f6dfece379c48213a2`, run `45544821063`, executed all five phone UI methods. Four passed; `testPaginationFailureRetry` failed at the helper's10-second exact `Loaded 2 items` wait. Simulator preparation completed and is not this failure.

The original `xcodebuild.log`361–420 records real `search-load-more` and `search-retry` tap events. The error appeared and the first photo remained before Retry. A synthesized tap alone does not prove business completion; the raw xcresult runner diagnostic provides the decisive independent evidence:

- `04:37:31.847`: runner starts the `search-loaded-count` remote existence query.
- `04:37:39.240`: query completes after7.393 seconds.
- `04:37:39.241`: its actual results tree contains `StaticText, identifier: 'search-loaded-count', label: 'Loaded 2 items'`.
- `04:37:39.244`: the old `exists AND label` predicate performs another remote query to read label.
- `04:37:41.147–41.148`: the outer waiter expires and interrupts that second query. The debug attachment then contains only the query chain because snapshot retrieval was interrupted.

This is evidence of an unnecessarily repeated remote AX lookup after the expected UI state already existed. It does not establish a Store pagination race, ignored Retry tap, fixture failure or a device boot failure. No business state or fixture change is justified by this trace.

The minimal repair composes the original identifier and exact label into a single `XCUIElementQuery`, then waits for that matching element's existence. It retains the same10-second limit, all five methods, original32 `XCTAssert` call sites, exact expected labels, result deduplication/error-removal assertions and screenshot requirements. No sleep, retry of a failed test, fallback success branch, runner/workflow change or relaxed result condition is introduced.

Evidence is outside the repository, containing CI synthetic media only:

- Original artifact: `/volume2/codex-home/mental1104/tmp/remmich-pr9-73dda3d-phone/{xcodebuild.log,SearchUI.xcresult}`.
- Node24 zstd decompression: `/volume2/codex-home/mental1104/tmp/remmich-pr9-73dda3d-phone-decoded/` (578 decoded objects; originals unchanged).
- Original runner diagnostic object: `data.0~5mHc2ux-tmL-kc6n-AALMt0-gkzFfevqPDpPcn1O1-DUPSZGC9hviYwmXNiF7yI7YduUcFbsa2PCUxwuKjB7sQ==`, lines29014–29085. Exact AX and timing excerpts/source preservation checks are in `evidence/` beside the decoded objects.

NAS source-preservation and scoped SwiftFormat/lint/diff checks are recorded with this slice. Swift/Xcode/new UI execution remains **unverified**; the original4/5 result is not a pass for this repair. No production, server/API/SDK, Release app, SavedUI418, random/Scene/Stack code, active CI, push or dev merge is part of this change. Revert only this helper/query change if a real Xcode run disproves its behavior; retain the raw failure evidence and all acceptance conditions.
