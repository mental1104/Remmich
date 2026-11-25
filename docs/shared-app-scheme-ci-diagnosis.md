# Shared App scheme and the post-merge Build failure

The post-merge dev build fails before Swift compilation because Xcode cannot discover the requested `Remmich` scheme. The narrow repair adds an explicit shared App/logic-test scheme and verifies discovery of both shared schemes in the existing Build job.

## Evidence and attribution

- Fixed source: `c902a8f08867d0d5d3f00b4b2f971c68cfbd873a`, tree `37c38cc833ee6ae8075a1a764da14b2fe73c2a83`, identical to the successful PR8 source `fedba7a`. PR run `45530789116` passed compilation, API93, App982 and phone/tablet5/5 through `RemmichSearchUI`.
- Post-merge Build `45536384915`, job `138943891650`, raw log220: `xcodebuild: error: The project named "Remmich" does not contain a scheme named "Remmich"`; exit65. This is the supplied owning-run diagnostic, not a new NAS Xcode execution.
- The checked-in scheme directory contains only `RemmichSearchUI.xcscheme`. The existing Build selects that scheme for PRs and `Remmich` for dev; Tests consumes the latter build's `remmich-test-products` and runs only `RemmichTests` from its xctestrun.
- The app and unit-test targets still exist, with IDs `F84699433066C25E00C68930` and `F84699503066C25F00C68930`; the unit-test host is still the existing Remmich app. No source/type-checking or missing-target error is evidenced.
- History introduces the shared UI scheme at `af0d776`, while no shared `Remmich.xcscheme` was tracked. Earlier dev builds therefore depended on scheme generation outside the checked-in shared definition. The exact Xcode auto-generation suppression mechanism is an inference; the current absence and failing requested name are directly evidenced.

## Minimal repair and verification boundary

`Remmich.xcscheme` is shared under `Remmich.xcodeproj/xcshareddata/xcschemes`. Its Build action includes the App and `RemmichTests`, with only the latter enabled in its Debug Test action; the existing app is the macro/launch/profile target. Debug launch/analysis and Release profile/archive retain the App configuration and product. No UI bundle is substituted into the dev build.

The existing Build gains one pre-build discovery step: actual `xcodebuild -list -project Remmich.xcodeproj -json -quiet`, followed by jq requiring an array containing both exact scheme names. JSON stdout and progress/diagnostic stderr are separate; failures expose the original output. Unexpected non-JSON stdout fails instead of being filtered into a false success. Triggers, runner, draft gate, business tests, artifact/revision contracts and Tests remain unchanged.

The PR path continues to compile `RemmichSearchUI`. Its new discovery step directly covers the missing-scheme boundary, **but does not build the new App scheme**. After a successful PR, the original dev `Remmich` build-for-testing and downstream Tests must still establish the actual App-scheme build, generated xctestrun and test-product compatibility before promotion. NAS has no Xcode/Swift, so none of those runtime checks ran here.

Actual NAS checks:

- Standard-library XML parsing and semantic checks: two native target IDs/product types, App-host relation, two BuildAction entries, one enabled nonparallel logic Testable, macro expansion, launch/profile/analysis/archive configurations, all container references and the existing xctestrun consumer.
- Byte identity for project.pbxproj, original UI scheme and test.yml. YAML2.9.1 parses Build; removing the one new step makes its parsed structure exactly equal to the fixed baseline. Every run block passes Bash syntax.
- Seven cases execute the added Bash step with a synthetic Xcode command: both schemes with stderr progress succeeds; missing App, missing UI, invalid JSON, wrong shape, Xcode exit65 and unexpected stdout progress all fail. These are script-contract checks, not Xcode scheme-discovery evidence. Raw outputs/script are under `/volume2/codex-home/mental1104/tmp/remmich-scheme-discovery-vKBBts`.
- `git diff --check` passes. No Swift business/generated source, signing settings, production, parent gitlink, push, merge or CI execution changed during this subtask.

Rollback removes this shared scheme and its discovery step, restoring the known missing-name failure on a fresh dev build. No media, account or recovery-data rollback is needed.
