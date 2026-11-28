import XCTest

/// Opt-in acceptance against the device's existing, signed-in account.
/// The test runner must receive REMMICH_LIVE_DEVICE_TESTS=1 through its xctestrun environment.
/// Default CI skips this suite. No fixture arguments, preference suite, account reset, upload,
/// photo scan, explicit original-load action, privacy-button response, or app termination is performed here.
/// Only anonymous UI state/counts are attached to xcresult; no screenshots, full accessibility
/// trees, account details, album titles, filenames, or asset identifiers are recorded.
final class LivePhotoRoutingAcceptanceUITests: XCTestCase {
    private static let bundleIdentifier = "io.github.espeonblue.Remmich"
    private let localPhotoLabels = ["自动匹配并优先使用本机照片", "Automatically Match & Prefer Local Photos"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["REMMICH_LIVE_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Live-account device acceptance requires explicit REMMICH_LIVE_DEVICE_TESTS=1.")
        }
    }

    /// Reads the saved queue, enables only the shared local-browsing preference if needed,
    /// and opens settings to request Photos access/read album names without selecting any album.
    /// Normal foreground activity from the user's existing automatic rules can still run independently.
    @MainActor func testLivePhotoSyncStatusAndEnableLocalPhotos() throws {
        let app = try activateLiveApp()
        try openPhotoSync(in: app)
        recordSummary("live-photo-sync-status", app: app)

        let localPhotos = app.switches.matching(NSPredicate(format: "label IN %@", localPhotoLabels)).firstMatch
        let form = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 2 {
            if localPhotos.exists, localPhotos.isHittable {
                break
            }
            guard form.exists, form.isHittable else { break }
            form.swipeUp()
            try stopForSystemOrAppAlert(in: app)
        }
        guard localPhotos.exists, localPhotos.isHittable else {
            recordSummary("live-local-photo-switch-unavailable", app: app)
            throw XCTSkip("Local Photos preference")
        }
        guard localPhotos.isEnabled else {
            recordSummary("live-local-photo-switch-disabled", app: app)
            throw XCTSkip("Local Photos preference is disabled during current backup work; no backup controls were pressed.")
        }
        switch localPhotos.value as? String {
        case "0":
            localPhotos.tap()
            try stopForSystemOrAppAlert(in: app)
            let enabled = NSPredicate(format: "value == %@", "1")
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: localPhotos)], timeout: 3) == .completed else {
                recordSummary("live-local-photo-enable-unconfirmed", app: app)
                throw XCTSkip("Local Photos preference did not become enabled")
            }
        case "1":
            break
        default:
            recordSummary("live-local-photo-switch-unknown-value", app: app)
            throw XCTSkip("Unrecognized Local Photos preference value; left unchanged")
        }
        recordSummary("live-local-photo-enabled", app: app)

        guard let settings = visibleButton(identifiers: [], labels: ["Backup Settings", "备份设置"], in: app) else {
            recordSummary("live-backup-settings-unavailable", app: app)
            throw XCTSkip("Backup Settings")
        }
        settings.tap()
        // The settings view itself requests authorization and reads album collections. Never press
        // any system permission choice, select an album, or press Scan/Match & Back Up.
        _ = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.waitForExistence(timeout: 2)
        try stopForSystemOrAppAlert(in: app)
        recordSummary("live-photos-permission-or-album-status", app: app)
        try closeKnownSheet(titles: ["Backup Settings", "备份设置"], in: app)
        try closeKnownSheet(titles: ["Photo Sync", "照片同步"], in: app)
    }

    /// Samples only the current photo viewport and two adjacent screens. It does not seek a year,
    /// change zoom, open a photo, trigger a refresh, or loop through the library.
    @MainActor func testLiveGridCapture() throws {
        let app = try activateLiveApp()
        try closeKnownSheet(titles: ["Backup Settings", "备份设置"], in: app)
        try closeKnownSheet(titles: ["Photo Sync", "照片同步"], in: app)
        let root = app.descendants(matching: .any).matching(identifier: "photos-root").firstMatch
        // Retapping the already-selected Photos tab can reset its range/scroll position.
        if !root.exists || !root.isHittable {
            try tapPrimaryTab(identifiers: ["photos-tab"], labels: ["Photos", "照片"], in: app)
        }
        guard root.waitForExistence(timeout: 5) else {
            recordSummary("live-photo-root-unavailable", app: app)
            throw XCTSkip("Real photos-root")
        }
        guard let scroll = photoTimelineSurface(in: app, root: root) else {
            recordSummary("live-photo-grid-unavailable", app: app)
            throw XCTSkip("Photo timeline scroll container")
        }
        recordSummary("live-photo-grid-before-scroll", app: app)
        for index in 1 ... 2 {
            scroll.swipeUp()
            try stopForSystemOrAppAlert(in: app)
            recordSummary("live-photo-grid-scroll-\(index)", app: app)
        }
    }

    /// Retries only the existing timeline metadata index. Never presses Pause, rebuild, backup,
    /// warming or permission controls. Attachments contain only numeric progress and fixed states.
    @MainActor func testLiveRetryClientIndexing() throws {
        let app = try activateLiveApp()
        let page = app.descendants(matching: .any).matching(identifier: "profile-page-Index").firstMatch
        if !page.exists {
            try closeKnownSheet(titles: ["Backup Settings", "备份设置"], in: app)
            try closeKnownSheet(titles: ["Photo Sync", "照片同步"], in: app)
            try tapPrimaryTab(identifiers: ["profile-tab"], labels: ["Me", "我的"], in: app)
            let myRoot = app.descendants(matching: .any).matching(identifier: "my-root").firstMatch
            guard myRoot.waitForExistence(timeout: 5) else {
                throw XCTSkip("Real My page is not ready; no indexing control was pressed.")
            }
            let entries = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Library Sync & Index", "图库同步与索引"]))
            guard let entry = entries.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                throw XCTSkip("Known Library Sync & Index entry is not visible.")
            }
            entry.tap()
            try stopForSystemOrAppAlert(in: app)
        }
        guard page.waitForExistence(timeout: 5) else {
            throw XCTSkip("Known profile-page-Index did not open.")
        }
        let timelines = page.segmentedControls.buttons.matching(NSPredicate(format: "label IN %@", ["Timelines", "时间线"])).firstMatch
        guard timelines.exists, timelines.isSelected else {
            throw XCTSkip("Index page is not on its default Timelines section; no action was taken.")
        }
        let progress = page.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Library indexing progress", "图库索引进度"])).firstMatch
        guard progress.waitForExistence(timeout: 3) else {
            throw XCTSkip("Known timeline indexing progress is not exposed.")
        }
        func button(_ labels: [String]) -> XCUIElement? {
            page.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
        }
        func state() -> String {
            if button(["Pause", "暂停"]) != nil {
                return "runningOrWaiting"
            }
            if button(["Retry", "重试"]) != nil {
                return "failed"
            }
            if button(["Resume", "继续"]) != nil {
                return "paused"
            }
            if button(["Sync Now", "Sync now", "立即同步"]) != nil {
                return "idleOrComplete"
            }
            return "unknown"
        }
        func digits(_ text: Substring) -> String {
            text.compactMap(\.wholeNumberValue).map(String.init).joined()
        }
        func percentageNumber(_ text: Substring) -> String {
            var number = "", hasDecimal = false
            for character in text {
                if let digit = character.wholeNumberValue {
                    number += String(digit)
                } else if character == "." || character == "," || character == "٫" {
                    guard !hasDecimal else { return "unknown" }
                    if number.isEmpty {
                        number = "0"
                    }
                    number += "."; hasDecimal = true
                } else if !character.isWhitespace {
                    return "unknown"
                }
            }
            if number.last == "." {
                number.removeLast()
            }
            guard let value = Double(number), value.isFinite, (0 ... 100).contains(value) else { return "unknown" }
            return number // 28.52% stays 28.52; a decimal comma is normalized, never removed.
        }
        func record(_ event: String, action: String) {
            var percentage = "unknown", completed = "unknown", total = "unknown"
            // The source-defined progress value is "% (completed/total) assets indexed".
            // Read it only here, discard all nonnumeric content, and never attach the raw value.
            if let raw = progress.value as? String {
                if let end = raw.firstIndex(of: "%") {
                    percentage = percentageNumber(raw[..<end])
                }
                if let start = raw.firstIndex(of: "("), let end = raw.lastIndex(of: ")"), start < end {
                    let counts = raw[raw.index(after: start) ..< end].split(separator: "/")
                    if counts.count == 2 {
                        completed = digits(counts[0]); total = digits(counts[1])
                    }
                }
            }
            attachAnonymous(["event=\(event)", "indexState=\(state())", "action=\(action)",
                             "indexPercentage=\(percentage.isEmpty ? "unknown" : percentage)",
                             "indexedCount=\(completed.isEmpty ? "unknown" : completed)",
                             "expectedCount=\(total.isEmpty ? "unknown" : total)"], name: event)
        }
        record("live-client-index-before-retry", action: "none")
        var action = "noneAlreadyRunning"
        if button(["Pause", "暂停"]) == nil {
            let permitted: [(String, [String])] = [("retry", ["Retry", "重试"]), ("resume", ["Resume", "继续"]),
                                                   ("sync", ["Sync Now", "Sync now", "立即同步"])]
            guard let selected = permitted.first(where: { button($0.1) != nil }), let control = button(selected.1) else {
                throw XCTSkip("No permitted Retry/Resume/Sync Now action is visible; nothing was pressed.")
            }
            control.tap()
            action = selected.0
            try stopForSystemOrAppAlert(in: app)
        }
        let deadline = Date().addingTimeInterval(20)
        let dwell = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
        _ = XCTWaiter.wait(for: [dwell], timeout: 21)
        try stopForSystemOrAppAlert(in: app)
        record("live-client-index-after-passive-wait", action: action)
    }

    /// Opens only the first visible ordinary still photo in the current asset grid. Fixed Photo/
    /// Video/Live Photo/Stack accessibility tokens come from TimelineAssetThumbnail, not filenames.
    /// A bounded pinch can refine grouped covers into ordinary assets without opening media.
    @MainActor func testLiveCurrentPhotoDetails() throws {
        let app = try activateLiveApp()
        let root = app.descendants(matching: .any).matching(identifier: "photos-root").firstMatch
        if !root.waitForExistence(timeout: 5) {
            try tapPrimaryTab(identifiers: ["photos-tab"], labels: ["Photos", "照片"], in: app)
        }
        guard root.waitForExistence(timeout: 5), let surface = photoTimelineSurface(in: app, root: root) else {
            recordSummary("live-details-current-photo-grid-unavailable", app: app)
            throw XCTSkip("Leave the app on its existing ordinary Photos grid; no navigation or zoom was changed.")
        }
        let ordinaryPhoto = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND NOT (label CONTAINS %@) AND NOT (label CONTAINS %@) AND NOT (label CONTAINS %@)",
            "asset-", ", Photo", "Video", "Live Photo", "Stack of"
        )
        var selectedFrame = firstVisibleOrdinaryPhotoFrame(in: app, matching: ordinaryPhoto)
        for _ in 0 ..< 2 where selectedFrame == nil {
            surface.pinch(withScale: 2, velocity: 1)
            try stopForSystemOrAppAlert(in: app)
            _ = app.descendants(matching: .any).matching(ordinaryPhoto).firstMatch.waitForExistence(timeout: 2)
            selectedFrame = firstVisibleOrdinaryPhotoFrame(in: app, matching: ordinaryPhoto)
        }
        guard let frame = selectedFrame else {
            recordSummary("live-details-no-reliably-typed-visible-still", app: app)
            throw XCTSkip("No visible ordinary still-photo accessibility token; no grouped cover or video was opened.")
        }
        // Do not call tap() on the media element: XCTest can include its real UUID/date in logs.
        let origin = app.frame.origin
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).tap()
        try stopForSystemOrAppAlert(in: app)
        let containerIDs = ["asset-viewer-portrait", "asset-viewer-landscape", "asset-viewer-landscape-split"]
        let viewer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", containerIDs)).firstMatch
        guard viewer.waitForExistence(timeout: 5) else {
            recordDetailSummary("live-details-container-unavailable", app: app)
            throw XCTSkip("The coordinate tap did not expose a known still-viewer container.")
        }
        recordDetailSummary("live-details-opened", app: app)
        // A bounded passive dwell allows the app's own automatic original request to start.
        // No Load Original/Retry button is pressed. Info only reveals the automatic load state.
        let deadline = Date().addingTimeInterval(8)
        let dwell = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
        _ = XCTWaiter.wait(for: [dwell], timeout: 9)
        try stopForSystemOrAppAlert(in: app)
        recordDetailSummary("live-details-after-passive-dwell", app: app)
        let info = app.descendants(matching: .any).matching(identifier: "asset-viewer-info").firstMatch
        if info.exists, info.isHittable {
            info.tap()
            try stopForSystemOrAppAlert(in: app)
            _ = app.descendants(matching: .any).matching(identifier: "asset-viewer-load-original").firstMatch.waitForExistence(timeout: 3)
            recordDetailSummary("live-details-info-state", app: app)
        }
        let close = app.descendants(matching: .any).matching(identifier: "asset-viewer-back").firstMatch
        guard close.exists, close.isHittable else {
            throw XCTSkip("Known asset-viewer-back is not available; no unknown control was pressed.")
        }
        close.tap()
        try stopForSystemOrAppAlert(in: app)
    }

    /// Observes the already-open still viewer. Only Chrome/Info navigation is permitted; original
    /// loading stays entirely automatic and its completion must be explicitly exposed by the UI.
    @MainActor func testLiveInspectCurrentStillDetails() throws {
        let app = try activateLiveApp()
        let viewerIDs = ["asset-viewer-portrait", "asset-viewer-landscape", "asset-viewer-landscape-split"]
        let viewer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", viewerIDs)).firstMatch
        guard viewer.waitForExistence(timeout: 3) else {
            recordDetailSummary("live-current-still-no-viewer", app: app)
            throw XCTSkip("No known current still viewer is open; no photo was selected.")
        }
        let panel = app.descendants(matching: .any).matching(identifier: "asset-viewer-info-panel").firstMatch
        let info = app.descendants(matching: .any).matching(identifier: "asset-viewer-info").firstMatch
        if !panel.exists || !panel.isHittable {
            if !info.exists || !info.isHittable {
                let frame = viewer.frame
                guard frame.width.isFinite, frame.height.isFinite, frame.width > 100, frame.height > 100,
                      app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                else {
                    throw XCTSkip("Known viewer has no safe center for restoring Chrome.")
                }
                // Retained hidden panels can still exist in the accessibility tree.
                // mediaTapped only toggles Chrome; a hittable Info panel is left untouched.
                viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                try stopForSystemOrAppAlert(in: app)
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: info)
            guard XCTWaiter.wait(for: [ready], timeout: 2) == .completed else {
                recordDetailSummary("live-current-still-info-unavailable", app: app)
                throw XCTSkip("Known Info control is not available; no load or retry action was used.")
            }
            info.tap()
            try stopForSystemOrAppAlert(in: app)
        }
        guard panel.waitForExistence(timeout: 3) else {
            throw XCTSkip("Info did not expose its known panel; original state remains unknown.")
        }
        let originals = panel.descendants(matching: .any).matching(identifier: "asset-viewer-load-original")
        let loaded = originals.matching(NSPredicate(format: "label IN %@", ["Original loaded", "Original Loaded", "原片已载入"])).firstMatch
        let failed = panel.descendants(matching: .any).matching(identifier: "asset-viewer-full-resolution-error")
        let retry = originals.matching(NSPredicate(format: "label IN %@", ["Retry loading original", "重试载入原片"]))
        let terminal = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR (identifier == %@ AND label IN %@)",
            "asset-viewer-full-resolution-error", "asset-viewer-load-original",
            ["Original loaded", "Original Loaded", "原片已载入", "Retry loading original", "重试载入原片"]
        )).firstMatch
        recordDetailSummary("live-current-still-before-original-observation", app: app)
        _ = terminal.waitForExistence(timeout: 30)
        recordDetailSummary("live-current-still-after-original-observation", app: app)
        if failed.firstMatch.exists || retry.firstMatch.exists {
            XCTFail("The current still viewer explicitly reported automatic original-load failure; no retry was pressed.")
            return
        }
        guard loaded.exists else {
            try stopForSystemOrAppAlert(in: app)
            throw XCTSkip("Automatic original completion is not exposed after the bounded observation; state is unknown.")
        }
        let back = app.descendants(matching: .any).matching(identifier: "asset-viewer-back").firstMatch
        let canClose = back.exists && back.isHittable
        // Cleanup availability cannot erase a successfully observed Original loaded state.
        attachAnonymous(["event=live-current-still-original-loaded", "originalUILoaded=true",
                         "knownBackAvailable=\(canClose)", "closeAttempted=\(canClose)"], name: "live-current-still-completion")
        if canClose {
            back.tap()
        }
    }

    @MainActor private func firstVisibleOrdinaryPhotoFrame(in app: XCUIApplication, matching predicate: NSPredicate) -> CGRect? {
        let bounds = app.frame.insetBy(dx: 20, dy: 80)
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.prefix(80)
            .compactMap { element -> CGRect? in
                guard element.isHittable else { return nil }
                let frame = element.frame
                guard frame.width >= 20, frame.height >= 20,
                      bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
                return frame
            }.sorted { left, right in
                abs(left.minY - right.minY) > 1 ? left.minY < right.minY : left.minX < right.minX
            }.first
    }

    /// activate() preserves the running account, launch arguments, preferences and data container.
    /// It can cold-start a stopped app, including the app's normal foreground lifecycle work.
    @MainActor private func activateLiveApp() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        app.activate()
        recordSummary("live-initial-state", app: app)
        try stopForSystemOrAppAlert(in: app)
        return app
    }

    /// SwiftUI can expose photos-root separately from its UIKit scroll view. Match only visible
    /// containers overlapping the known root; a hittable root itself also accepts XCTest swipes.
    /// This helper never reads a media label/identifier or attaches a hierarchy or screenshot.
    @MainActor private func photoTimelineSurface(in app: XCUIApplication, root: XCUIElement) -> XCUIElement? {
        guard root.exists else { return nil }
        let bounds = root.frame
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 1, bounds.height > 1 else { return nil }
        let queries = [root.collectionViews, root.scrollViews, app.collectionViews, app.scrollViews]
        for query in queries {
            if let surface = query.allElementsBoundByIndex.first(where: { candidate in
                guard candidate.isHittable else { return false }
                let frame = candidate.frame
                let overlap = frame.intersection(bounds)
                return frame.width > 1 && frame.height > 1 && !overlap.isNull && !overlap.isEmpty
            }) {
                return surface
            }
        }
        return root.isHittable ? root : nil
    }

    @MainActor private func openPhotoSync(in app: XCUIApplication) throws {
        let localPhotos = app.switches.matching(NSPredicate(format: "label IN %@", localPhotoLabels)).firstMatch
        if localPhotos.exists {
            return
        }
        let root = app.descendants(matching: .any).matching(identifier: "my-root").firstMatch
        let entries = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["my-photo-backup", "my-photo-backup-entry"]))
        var scrolls = 0
        // Activation can replace the restoring shell and reset its temporary tab selection.
        // At most one extra explicit My tap is allowed; no unknown control is tried.
        for attempt in 0 ..< 2 {
            if attempt > 0 || !root.exists || !root.isHittable {
                guard let profile = visibleButton(identifiers: ["profile-tab"], labels: ["Me", "我的"], in: app) else {
                    recordNavigationSummary("live-profile-control-unavailable", app: app)
                    throw XCTSkip("Real My tab is not currently available.")
                }
                profile.tap()
                try stopForSystemOrAppAlert(in: app)
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: root)
            guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
                recordNavigationSummary("live-my-root-not-ready-\(attempt)", app: app)
                continue
            }
            recordNavigationSummary("live-my-root-ready-\(attempt)", app: app)
            while true {
                if let entry = entries.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                    // The static entry ID requires a real AppSessionController. Its UIKit/SwiftUI
                    // exposure can be Button, Cell or Other, so do not constrain its element type.
                    entry.tap()
                    try stopForSystemOrAppAlert(in: app)
                    return
                }
                guard scrolls < 2, root.exists, root.isHittable else { break }
                let scroll: XCUIElement = if [.collectionView, .table, .scrollView].contains(root.elementType) {
                    root
                } else if root.collectionViews.firstMatch.exists {
                    root.collectionViews.firstMatch
                } else if root.tables.firstMatch.exists {
                    root.tables.firstMatch
                } else {
                    root.scrollViews.firstMatch
                }
                guard scroll.exists, scroll.isHittable else { break }
                scroll.swipeUp()
                scrolls += 1
                try stopForSystemOrAppAlert(in: app)
            }
        }
        recordNavigationSummary("live-photo-sync-entry-unavailable", app: app)
        throw XCTSkip("Real My root/Photo Sync entry did not become hittable after one tab retry and at most two bounded scrolls.")
    }

    @MainActor private func tapPrimaryTab(identifiers: [String], labels: [String], in app: XCUIApplication) throws {
        guard let tab = visibleButton(identifiers: identifiers, labels: labels, in: app) else {
            recordSummary("live-primary-tab-unavailable", app: app)
            throw XCTSkip("Primary tab: \(labels.joined(separator: "/"))")
        }
        if !tab.isSelected {
            tab.tap()
        }
        try stopForSystemOrAppAlert(in: app)
    }

    @MainActor private func visibleButton(identifiers: [String], labels: [String], in app: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier IN %@ OR (label IN %@ AND identifier != %@)", identifiers, labels, "BackButton")
        // iPad's native tabs can expose duplicate parent/child buttons. Choose a hittable match.
        return app.buttons.matching(predicate).allElementsBoundByIndex.first { $0.isHittable }
    }

    @MainActor private func closeKnownSheet(titles: [String], in app: XCUIApplication) throws {
        try stopForSystemOrAppAlert(in: app)
        let bars = app.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", titles, titles))
        guard let bar = bars.allElementsBoundByIndex.first(where: { $0.isHittable }) else { return }
        let close = bar.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        guard close.exists, close.isHittable else {
            recordSummary("live-known-sheet-close-unavailable", app: app)
            throw XCTSkip("Done on \(titles.joined(separator: "/"))")
        }
        close.tap()
        try stopForSystemOrAppAlert(in: app)
    }

    /// Permission and other alerts need a person. Capture and finish immediately, never wait for
    /// manual input or install an interruption handler that could grant access on the user's behalf.
    /// Missing controls also produce an explicit skip rather than a false pass or private failure screenshot.
    @MainActor private func stopForSystemOrAppAlert(in app: XCUIApplication) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard system.alerts.firstMatch.exists || app.alerts.firstMatch.exists else { return }
        recordSummary("live-manual-alert-required", app: app)
        throw XCTSkip("A system/app alert requires manual action; no alert button was pressed.")
    }

    /// Only source-defined static IDs and anonymous type/presence flags are queried or recorded.
    @MainActor private func recordNavigationSummary(_ name: String, app: XCUIApplication) {
        var lines = ["event=\(name)", "timestampEpochSeconds=\(Date().timeIntervalSince1970)"]
        let types: [(String, XCUIElement.ElementType?)] = [("any", nil), ("button", .button), ("cell", .cell), ("other", .other)]
        for identifier in ["my-root", "my-photo-backup", "my-photo-backup-entry"] {
            let matches = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
            for (name, type) in types {
                let selected = matches.filter { type == nil || $0.elementType == type }
                lines.append("\(identifier).\(name).exists=\(!selected.isEmpty)")
                lines.append("\(identifier).\(name).hittable=\(selected.contains { $0.isHittable })")
            }
        }
        for identifier in ["profile-fixture-photos", "search-ui-test-host", "restoring-shell"] {
            lines.append("\(identifier).exists=\(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)")
        }
        attachAnonymous(lines, name: name)
    }

    @MainActor private func recordDetailSummary(_ name: String, app: XCUIApplication) {
        let button = app.descendants(matching: .any).matching(identifier: "asset-viewer-load-original")
        let loaded = button.matching(NSPredicate(format: "label IN %@", ["Original loaded", "Original Loaded", "原片已载入"])).firstMatch.exists
        let failed = app.descendants(matching: .any).matching(identifier: "asset-viewer-full-resolution-error").firstMatch.exists
            || button.matching(NSPredicate(format: "label IN %@", ["Retry loading original", "重试载入原片"])).firstMatch.exists
        let observed = button.firstMatch.exists
        let state = loaded ? "loaded" : failed ? "failed" : observed ? "availableOrLoading" : "unknown"
        var lines = ["event=\(name)", "timestampEpochSeconds=\(Date().timeIntervalSince1970)",
                     "originalUIState=\(state)", "originalUILoaded=\(loaded)", "originalUIFailed=\(failed)", "originalUIControlPresent=\(observed)"]
        for identifier in ["asset-viewer-portrait", "asset-viewer-landscape", "asset-viewer-landscape-split", "asset-viewer-back", "asset-viewer-info-panel"] {
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            lines.append("\(identifier).exists=\(element.exists)")
            lines.append("\(identifier).hittable=\(element.exists && element.isHittable)")
        }
        attachAnonymous(lines, name: name)
    }

    @MainActor private func attachAnonymous(_ lines: [String], name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name + "-anonymous-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func recordSummary(_ name: String, app: XCUIApplication) {
        let localPhotos = app.switches.matching(NSPredicate(format: "label IN %@", localPhotoLabels)).firstMatch
        let rawValue = localPhotos.exists ? localPhotos.value as? String : nil
        let value = rawValue == "0" || rawValue == "1" ? rawValue! : "unavailable"
        let photoRoot = app.descendants(matching: .any).matching(identifier: "photos-root").firstMatch
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let summary = [
            "event=\(name)",
            "timestampEpochSeconds=\(Date().timeIntervalSince1970)",
            "applicationState=\(app.state.rawValue)",
            "photosRootExists=\(photoRoot.exists)",
            "collectionViewCount=\(app.collectionViews.count)",
            "cellCount=\(app.cells.count)",
            "localPhotosPreference=\(value)",
            "systemAlertPresent=\(system.alerts.firstMatch.exists)",
            "appAlertPresent=\(app.alerts.firstMatch.exists)",
        ].joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = name + "-anonymous-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
