<img src=".github/assets/remmich-logo-credit.svg" alt="Remmich" width="128" align="left" />

<b><font>Remmich</font></b>

 Personal Immich client for iPhone and iPad: browsing, backup, editing and management.

This is [mental1104/Remmich](https://github.com/mental1104/Remmich), forked from [Ender-Wang/Remmich](https://github.com/Ender-Wang/Remmich). Develop and build on `dev`; `main` follows upstream. See [client/server contracts and current limitations](docs/fork-compatibility.md).

<br clear="all" />

<p align="center">
  <a href="https://github.com/Ender-Wang/Remmich/releases/latest"><img src="https://img.shields.io/github/v/release/Ender-Wang/Remmich?label=version&amp;color=blue" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" alt="Swift 6" />
  <img src="https://img.shields.io/badge/iOS-26.6%2B-black?logo=apple" alt="iOS 26.6+" />
  <a href="https://github.com/mental1104/Remmich/actions/workflows/build.yml"><img src="https://github.com/mental1104/Remmich/actions/workflows/build.yml/badge.svg" alt="Build" /></a>
  <a href="https://github.com/mental1104/Remmich/actions/workflows/test.yml"><img src="https://github.com/mental1104/Remmich/actions/workflows/test.yml/badge.svg" alt="Tests" /></a>
</p>

Remmich is a SwiftUI, UIKit, and AVKit client for your self-hosted Immich library. Browse photos, watch videos, revisit memories, and keep thumbnails and asset information available offline with explicit backup, non-destructive editing and management actions.

Browse Photos, Videos, Albums, and Library collections from your Immich account, with offline indexing, interactive album layouts, Sharing and Save to Photos. Search reads real account-scoped results with native filters and saved searches.

See the **[Roadmap](#roadmap)** for current and planned work.

<p align="center">
  <img src=".github/assets/screenshots/gallery-desktop.svg" alt="Remmich onboarding, timeline, asset viewer, Info, map, date cards, Profile, Albums, and Library collections" width="100%" />
</p>

## Install

Requires an iPhone or iPad running iOS/iPadOS 26.6 or later and an account on your Immich server.

This fork is currently installed from a local signed Xcode build. No downstream IPA has been released yet. Fork releases are manual and require a successful tested `dev` revision; the SideStore catalog intentionally has no versions until the first downstream release. Upstream releases contain the upstream product and are not builds of this fork.

You can also follow [Build and run](CONTRIBUTING.md#build-and-run) to build from source. After installing, sign in with your Immich server address and credentials. Add a Primary address and optional Fallback addresses in **Profile → Connection** if needed.

## Features

- **🔍 Timelines:** Separate Photos and Videos timelines with pinch-to-zoom, date cards and saved browsing positions. Cached timelines show about two screenfuls first, then load older items without moving the viewport. Videos, Albums, and Search prepare their first views while Photos loads its history.
- **📸 Photos and memories:** Zoomable photos, Live Photo playback, filmstrip navigation and rotating memories.
- **👆 Quick preview:** Long-press to preview, tap to open, and swipe down to dismiss with interruptible transitions.
- **🗺️ Places and maps:** Pan and zoom a live heatmap above the Places grid. Tap a locality to zoom to its captures and browse its timeline, then go back to restore the map and grid position. Place cards and titles follow per-country Photon language preferences when cached labels are available. Individual asset maps appear below Info.
- **🎬 Video:** Native playback, Picture in Picture and iOS Now Playing with titles and artwork.
- **💾 Offline browsing:** Cached timelines, thumbnails, asset information and place names, with background sync. Asset Cache and Place Cache have separate progress, Sync/Pause/Resume and automatic-cache settings; Rebuild and Clear maintain both caches together.
- **📥 Downloads:** Save a quality tier to Photos → Remmich, with background transfers, pause/resume, automatic recovery, and cancel/retry. Browse saved photos and videos in Library → On Device. Save History shows the latest completed download when its cover is available.
- **📚 Library collections** — Browse Recently taken, Recently added, Favorites, Memories, People, Places, Shared Links, Partners, Folders, Archive, and Trash. Recently taken and Recently added show their newest eligible covers and open full timelines ordered by capture or upload date. Optional cards follow the Immich account's feature settings. After Photos appears, Library warms its card covers. Switching to Library prepares up to two screenfuls of each enabled destination.
- **📤 Sharing:** Share the viewed quality from the viewer or preview, retaining supported metadata and cached image compression.
- **🗂️ Albums:** Browse owned and shared albums with inline search and six sorting options in a fixed top bar. Pinch between Cards and List around the album under your fingers, reopen album timelines at their saved positions, and browse indexed album metadata offline using the common timeline and viewer. Tap the active Albums or Library tab again to go back one page from an open card.
- **📊 Index controls.** Switch between **Timelines**, **Albums**, and **Library** by tapping or swiping. Each section places sync, pause, resume, and rebuild controls beneath its statistics. The Library Index reuses unchanged months and lets you reopen indexed cards offline. The profile Index card shows the status of all three indexes. Cache & Storage uses the same section layout, and available per-10K storage estimates update during sync.
- **🔐 Accounts and connections:** Saved-account switching, separate account caches and Primary/Fallback server addresses.
- **✨ Native appearance:** Adaptive iPhone/iPad layouts, Liquid Glass, swipe navigation and alternate app icons.

## Current limitations

- **Live Photo sharing:** shares the still image. Native motion sharing is limited by the investigated Apple public APIs; automatic export is unavailable in this implementation, and the system picker requires another selection step. Save to Photos preserves Live Photos.
- **Sharing:** single-asset sharing only. Shared files currently retain available GPS metadata.
- **Offline originals:** thumbnail caching does not retain originals or playable videos; explicitly saved Photos resources can be reused when the requested quality matches.
- **Search:** Real metadata and smart search are connected. Extended-filter integration and iPhone/iPad UI acceptance are still in progress; advanced smart combinations require the optional Fork extension. See [validation boundaries](docs/fork-compatibility.md).
- **Offline video:** saved Playback videos can load locally while the Photos resource remains accessible. Otherwise, streaming requires a reachable server.
- **Asset locations and maps:** maps require valid asset GPS and an enabled, compatible Immich map source. Place names and translated map labels depend on the provider's available data.

## Milestones

**M7 Library collections is complete. M8 Search and Filters is in progress.** The [Roadmap](#roadmap) shows planned work and dated achievements.

| Milestone | Status | Scope and expectations |
| --- | --- | --- |
| M0 | ✅ Done | Reproducible Xcode project, formatting, and baseline configuration |
| M1 | ✅ Done | Adaptive native app shell and demo destinations |
| M2 | ✅ Done | Sign-in, Keychain restoration, endpoint failover, and the typed read-only API boundary |
| M3 | ✅ Done | Shared media loading, caching, prefetching, and bounded memory use |
| M4 | ✅ Done | Real server-backed Photos timeline |
| M5 | ✅ Done | Timelines, viewers, preview, places/maps, Sharing and Download/Save to Photos with Pause/Resume |
| M6 | ✅ Done | Albums, automatic Album Index, interactive Card/List transitions and navigation refinements |
| M7 | ✅ Done | Read-only Library collections, Library Index, Save History, and the interactive Places heatmap |
| M8 | In progress | Server-backed Search with native filters |
| M9 | Planned | Further improvements and verification for iPad, accessibility, resilience, and performance |
| M10 | Planned | Broader real-device release verification and additional distribution options |

## Roadmap

The timeline places upcoming milestones above **Now** and completed work below it. Future milestones have no promised delivery dates.

![Remmich roadmap showing M8 Search and Filters in progress, M7 Library collections completed on November 23, and earlier milestones.](.github/assets/roadmap-timeline.svg)

### Now and next

| Priority | Feature | Status | Intended outcome |
| --- | --- | --- | --- |
| M8 | Search and filters | In progress | Real server-backed results, native filters and saved conditions; remaining extended filters and iPhone/iPad acceptance are in progress. |
| M9 | Wider native polish and resilience | Planned | Broader iPad, accessibility, interruption, offline and performance coverage across the completed workflows. |
| M10 | Release verification and distribution | Planned | Broader real-device verification and sideloading distribution; AltStore remains under consideration. |

## Personal fork capabilities

**Search → long-press a result → Find similar photos** uses that server asset as the reference and retains every selected filter. The reference card can return to text search, and saved searches preserve the reference and full conditions. This requires the authenticated Fork smart-search extension; missing routes and reference permissions remain visible errors. This follow-up awaits CI and device acceptance.

**Photos / Videos / Library / Search / Me** is the primary tab order, with Me at the far right. Library combines Albums and Collections while retaining their separate navigation histories. Me contains backup, local matching, server/connection, index, cache, and account settings. App Language follows the system by default and supports explicit Simplified Chinese or English, without changing the device language or restarting backup tasks.

**Me → Photo Backup** shows progress, matched/uploaded counts, scan and backup actions first; album selection, automatic rules, and optional history import live under Backup Settings. Without a SQLite import, existing server iCloud identities can be matched without downloading originals, with identity-only provenance saved separately. Unmatched no-import sources remain unconfirmed and are not automatically uploaded. Optional imported history retains the existing new-source admission policy. Persistent queues, separate foreground/background consent, and compound-resource receipt checks remain in the existing coordinator; a metadata match is never an original-byte or complete Live/RAW backup receipt. Device acceptance is pending.

**Photo viewer → sliders button** opens favorites, archive, caption, recycle-bin and album membership controls. Still images can use official non-destructive rotate/mirror/crop parameters; the current crop form uses pixel coordinates without a live preview. Existing edit parameters are loaded and checked again before replacement. **Albums → options → 相簿管理** creates, renames and deletes albums while retaining media.

Saved sessions stay in Keychain; local indexes and caches remain account scoped. Writes use a separate explicit API channel; the generated browsing SDK retains its read-only policy. No permanent media deletion or original replacement is provided. Server permissions remain authoritative. Public Photon coordinate lookup requires explicit consent under Maps & Places.

Sharing, Download and Save to Photos operate on local copies without changing the Immich server's library.

## Dependencies

Remmich connects to [Immich](https://github.com/immich-app/immich) through the local [ImmichAPI package](Packages/ImmichAPI), generated from Immich's OpenAPI schema.

| Library | Resolved version | Purpose |
| --- | --- | --- |
| [Nuke / NukeUI](https://github.com/kean/Nuke) | 13.2.2 | Image loading, caching, prefetching, and SwiftUI image views |
| [MapLibre Native](https://github.com/maplibre/maplibre-gl-native-distribution) | 7.0.0 | Native asset maps using Immich's configured styles |
| [Swift OpenAPI Runtime](https://github.com/apple/swift-openapi-runtime) | 1.12.1 | Runtime support for the generated API client |
| [Swift OpenAPI URLSession](https://github.com/apple/swift-openapi-urlsession) | 1.3.1 | URLSession transport for API requests |
| [Swift HTTP Types](https://github.com/apple/swift-http-types) | 1.8.0 | HTTP request, response, and header types |

Build and development tools:

- [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator) **1.13.1** generates the client during the build.
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) checks source formatting. CI pins version 0.64.5 and verifies its archive SHA-256; use the same version locally.
- Artwork regeneration uses **Python 3** and **librsvg's `rsvg-convert`**; see [Schema and artwork updates](CONTRIBUTING.md#schema-and-artwork-updates).

Swift packages resolve through Xcode. The [app lockfile](Remmich.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) and [API package lockfile](Packages/ImmichAPI/Package.resolved) record the complete resolved dependency graph, including transitive packages. SwiftUI, UIKit, AVKit/AVFoundation, and SQLite are provided by the operating system.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, the source layout, key implementation patterns, testing, and schema/artwork generation.

## License

[GNU GPLv3](LICENSE).
