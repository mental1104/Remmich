# Local media routing through the real pipeline

Independent `codex/test-local-media-nuke-routing` starts from root966e3c6 and takes only requested controller6375053, deferred-read guardc46022d and instance-level profile-session441d737 dependencies. Dependency cherry-picks resolve only documentation/log placement conflicts, preserving both records. The route-identity assertion additionally requires rootfde79a5 in the final candidate; that product fix is not repeated here. The delivery commit adds one test file and docs/log; it does not edit product code, change CI or access production.

`LocalMediaNukeRoutingTests` has11 functions/19 parameterized cases. Fixtures save an association in a real temporary atomic JSON store, restore it and run real LocalMediaMatchController automatic fresh validation before calling MediaLibraryController. The actual configured Nuke ImagePipeline and memory cache are used. Only inventory/metadata/current Photos results, fresh remote details, DataLoading bytes and unrelated export/audio dependencies are synthetic. No private map or routing result is set by the fixture.

| Real boundary | Assertions |
| --- | --- |
| Thumbnail, preview, fullsize | Existing ordinary remote memory image does not displace local. All3 routes return local3×2 pixels, pass target-pixel caps, report device Photos and make zero image DataLoading calls. |
| Local miss | Actual fallback decodes11×7 PNG through normal edited=true GET with expected path/Bearer. Second miss still checks Photos but reuses remote cache without a second DataLoading request. |
| Cancel/account/endpoint | Actual local reader enters a held await before retirement. Late nil cannot publish or start old remote loading. A return signal also waits for reader cleanup, instead of relying only on Nuke's outer cancellation. |
| Cached/deferred request | First prove local image exists in memory using a separate read-enabled probe. Reuse the unchanged original request after disable or authorization revocation: remote pixels return without reading the invalid local object. A constructed but unexecuted request checks the same boundary. |
| Precise version/original | Another remote revision and explicit original requests never select the old current-display association. |
| Video helper/prepare | Helper and actual VideoPlaybackSession.prepare(autoplay:false) select the same synthetic current item, record device source and make zero image DataLoading calls. Existing startPlayback calls fake audio once before checking autoplay; no product audio change. Pre-cancelled no-association prepare invokes it zero times and installs no item. |
| Late video helper | Cancel/account change throw; disable returns nil instead of the old item. No helper starts remote requests. |

The video item is an empty AVMutableComposition: identity/selection is tested, **not playability, frames, duration, actual audio or codecs**. Existing fail() pauses/deactivates but does not replace player.currentItem; an asynchronous empty-item failure is not a new source decision. Remote AVPlayer transport/playback and source-label UI remain separate acceptance.

No real network is allowed. Image DataLoading returns local PNGs and records requests. The instance-injected profile URLSession uses a private URLProtocol: only synthetic profile-image paths receive404; other URLs fail and all requests are intercepted. No global protocol/shared-session override. Transfer/SQLite/export roots are unique temporary directories, native transfer providers are empty and the Photos-writing fake never accesses the system library. Cleanup releases held readers. Counts refer to image DataLoading, not the separate mocked profile404 or measured network bytes.

Actual NAS checks: scoped SwiftFormat0.64.5 format/lint, diff whitespace, static dependency/protocol inspection and pinned Nuke13.2.2 public image-source/cache API checks. No Swift/Xcode here: compilation and19 cases remain **unexecuted**. Root's unified macOS chain must validate them. No earlier CI receipt covers this branch. Real PhotoKit permissions/cloud-only/current edits, server HTTP, device rendering and complete automatic matching remain unverified integration/device acceptance.

Rollback removes only this test/docs delivery. Product/controller dependencies are separately owned; this slice creates no server/media or persistent user data changes.
