# Phone search evidence for 51e5, attempt 3

The actual evidence is [run 45437064970 attempt 3/job 138907981130](https://github.com/mental1104/Remmich/actions/runs/45437064970/attempts/3), source `51e5d1099a60f90f3111e1d69d975b33fdecb24a`, artifact 14984001429 `remmich-pr-search-phone-evidence` (42,829,771 bytes). SHA256 `74c451883cdec3577fed7afa58d6b612707beca85574cb5c084937ee13161f21` matches GitHub's digest. The device descriptor is **iPhone 17e Simulator, iOS 27.2**, with Xcode 27.1 and test-without-building. This is not signed-device acceptance.

## Exact five-case result

Original `xcodebuild.log` records 5 cases, 4 passed/1 failed, 118.661 seconds:

| Case | Actual result | Original log evidence |
| --- | --- | --- |
| AccountSwitchRejectsLateResponse | Failed, 26.567s | line 69/test 81: failed to tap account-button, no matching element; case result 87 |
| BlankSearchAndViewer | Passed, 27.911s | line 156; existing page-ID/rendered-pixel/square/hittable/nonoverlap checks ran |
| EmptyAndErrorStates | Passed, 18.970s | line 229 |
| FavoriteFilterRotationAndKeyboard | Passed, 24.566s | line 326; original keyboard/hit/bounds/overlap/rotation assertions ran |
| PaginationFailureRetry | Passed, 20.648s | line 392 |

Suite totals are at lines 394/396/398. The phone failure/upload steps completed; tablet was still in progress when inspected. No whole-run conclusion is inferred here.

## Proven account-control boundary

Raw failure AX is losslessly decoded `decoded/0363.bin`, 7,163 bytes. Its pid 43841 matches the log's failure snapshot request at line 68. Lines 8–12 show NavigationBar `Search`, active `File name` SearchField (value `late`) and a native button **label `Close`**, frame x330/y47/44×44. Lines 17–19 show `Synthetic account alpha`, `started late`, `none`. No account-button appears anywhere in this AX tree.

The source already has the explicit phone DEBUG account toolbar (`SearchUITestHost.swift:36–44`). During active native search it is replaced by the search/Close navigation controls. The original helper (`SearchAcceptanceUITests.swift:152–158`) checks `Cancel` and lowercase `close`; log lines 61–62 confirm both checks, neither matched, followed by direct account-button tap at line 63. The dismissal helper misses the actual native label.

The independent repair adds only the exact `Close` branch between the two existing compatibility labels. It follows the real UI: dismiss native search, then click the unchanged account button and execute every original account-generation/retired-late-response assertion. The late request is not released by the helper, no fixture action is directly invoked, and none of the five cases/assertions/screenshots/timeouts is removed or relaxed. No product, DEBUG host, Native/Media, API/SDK or workflow code changes.

## Persistent evidence and checks

Exclusive download directory: `/volume2/codex-home/mental1104/tmp/remmich-pr8-51e5d10-attempt3-phone/`.

- `phone-evidence.zip`, original `xcodebuild.log`, `device.json`, complete `SearchUI.xcresult`.
- `decoded/manifest.json`: 643 original data-object IDs, sizes, decompressed paths and SHA256 digests. NAS Node 22.22.3's zstdDecompressSync decoded the Zstandard bytes; original xcresult objects remain unchanged. Index 0363 is the raw AX tree.
- `decoded/0462.png` shows the actual synthetic native Viewer image; `0638.png` shows the search keyboard. These are original PNG bytes.
- `evidence-receipt.json` records the sanitized run/artifact/device/results and source-preservation checks. No token or signed download URL is saved.

Actually run: archive SHA256 comparison, raw log/AX/PNG inspection, scoped SwiftFormat 0.64.5 lint (0/1 files require formatting), whitespace and an independent source comparison against 51e5. The entire UITest file matches the baseline after removing only the new label branch and updated comment, preserving all cases/assertions/timeouts.

No Swift/Xcode execution is available on NAS. The repair is **not rerun** and cannot claim account switching now passes or the whole CI passed. Four repair gates: implementation 25/25, static 25/25, repaired runtime 0/25, integration 0/25 = 50/100. Root alone owns the continuing CI and future serialized integration/push. This task never cancels, retries or starts CI, and makes no production change.

Rollback removes this one UITest branch and its documentation; no data, pipeline, original media or recovery format changes.

## Tablet follow-up and iPad exit repair

Root downloaded tablet artifact 14983818510 from the same run/attempt to `/volume2/codex-home/mental1104/tmp/remmich-pr8-51e5d10-attempt3-tablet/`. Its original `device.json` identifies iPad Pro 11-inch (M5), iPadOS 27.2. `xcodebuild.log` records 5 cases, 4 passed/1 failed in 137.684s (totals at 420/422/424). Account switching fails at test 81/log 73, case result 90; the four other cases pass at 163/242/347/418. The snapshot request at 72 identifies pid 53558. Log 65–66 checks Cancel/close, then 67 taps the absent account button.

The matching raw object is `SearchUI.xcresult/Data/data.0~TmgWzaQ3DLSLHi1QdUksIw863uCEAKC_MkwG8JlbG9n89As9zVBm1Xoa6h_u6TVz49uyNp4BCFm-N7s_8k8NwA==`. Read-only in-memory Zstandard decoding yields 7,155 bytes/47 lines: line 1 has pid 53558; 9–12 show full-width SearchField (value `late`) and Clear text; 17–19 show alpha/started late/none; 43–44 contain an empty Toolbar. The complete tree has neither Close/Cancel/close nor account-button. The tablet artifact was not downloaded again or modified.

Apple documents [`searchable(text:isPresented:placement:prompt:)`](https://developer.apple.com/documentation/swiftui/view/searchable(text:ispresented:placement:prompt:)-5hhxx) with `Binding<Bool>` and the existing `Text?` prompt overload. It is available from iOS/iPadOS 17, earlier than this app's minimum. [Managing search interface activation](https://developer.apple.com/documentation/swiftui/managing-search-interface-activation) describes presentation binding and dismissal: focus can leave a field while search remains presented, so keyboard dismissal alone is insufficient.

The follow-up changes SearchView to own this presentation state, bind it to the existing native field and show an iPad-only active-search Close header using safeAreaInset. Pinning the content header keeps it reachable when results scroll. Its action only sets the binding false; the query, request lifecycle and account action remain unchanged. The ordinary account-generation reset also clears presentation. Explicit UIKit import owns the UIDevice dependency. Phone adds no custom header, and the inherited exact Close helper lets the original UI case use the real exit before the original account tap and every late-response assertion.

Actually checked on NAS: scoped SwiftFormat 0.64.5 lint (0/1 files require formatting), diff whitespace, source preservation of query/request code, and byte equality of the original UITest, store and DEBUG host. No new test mirrors this trivial binding action; the five existing UI cases provide the pending real-flow regression. Swift compilation, repaired iPad/phone interaction and account-toolbar restoration remain **unverified** until macOS execution. Four gates are 25 implementation + 25 static + 0 runtime + 0 integration = 50/100. This follow-up makes no push/CI/production action; rollback is this one SearchView/docs commit.
