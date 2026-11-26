import Observation
import OSLog
import SwiftUI
import UIKit

@MainActor
@Observable
final class NativeTabSelectionState {
    var selection: NativeTabDestination = .photos
    var isAlbumSearchExpanded = false
    @ObservationIgnored var isPageInteractionActive = false

    func canActivateContent(in destination: NativeTabDestination) -> Bool {
        selection == destination && !isPageInteractionActive
    }
}

@MainActor
@Observable
final class NativeTabContentActivationState {
    private(set) var activeDestination: NativeTabDestination = .photos
    private(set) var hydratedDestinations: Set<NativeTabDestination> = [.photos]
    private(set) var preparedDestinations: Set<NativeTabDestination> = []

    func prepare(_ destination: NativeTabDestination) {
        preparedDestinations.insert(destination)
    }

    func activate(_ destination: NativeTabDestination) {
        activeDestination = destination
        hydratedDestinations.insert(destination)
    }

    func isHydrated(_ destination: NativeTabDestination) -> Bool {
        hydratedDestinations.contains(destination) || preparedDestinations.contains(destination)
    }
}

@MainActor
@Observable
final class TimelineRotationState {
    private(set) var generation = 0
    private(set) var targetSize: CGSize?
    private(set) var isRotating = false
    private var visualHandoffEligibleDestinations = Set<NativeTabDestination>()
    var visualHandoffResolved: ((Int, Bool, String) -> Void)?

    func begin(to targetSize: CGSize) {
        generation &+= 1
        self.targetSize = targetSize
        isRotating = true
    }

    func complete() {
        isRotating = false
        targetSize = nil
    }

    func setVisualHandoffEligible(
        _ eligible: Bool,
        for destination: NativeTabDestination
    ) {
        if eligible {
            visualHandoffEligibleDestinations.insert(destination)
        } else {
            visualHandoffEligibleDestinations.remove(destination)
        }
    }

    func isVisualHandoffEligible(for destination: NativeTabDestination) -> Bool {
        visualHandoffEligibleDestinations.contains(destination)
    }

    func resolveVisualHandoff(
        generation: Int,
        verified: Bool,
        reason: String
    ) {
        guard generation == self.generation else { return }
        visualHandoffResolved?(generation, verified, reason)
    }
}

/// 导航身份不使用本地化标题；相簿与分类共用图库位置，账户入口始终独立。
enum NativeTabDestination: Hashable {
    case photos
    case videos
    case albums
    case library
    case account
    case years
    case months
    case weeks
    case search
}

enum NativeTabPageDirection: Equatable {
    case previous
    case next
}

@MainActor
enum NativePageSlideAnimation {
    static let duration: TimeInterval = 0.36

    static func makeAnimator(from source: UIView, to destination: UIView,
                             direction: NativeTabPageDirection, width: CGFloat) -> UIViewPropertyAnimator
    {
        let travel = direction == .next ? width : -width
        let sourceTransform = source.transform
        let destinationTransform = destination.transform
        destination.transform = destinationTransform.translatedBy(x: travel, y: 0)
        return UIViewPropertyAnimator(duration: duration, curve: .easeInOut) {
            source.transform = sourceTransform.translatedBy(x: -travel, y: 0)
            destination.transform = destinationTransform
        }
    }
}

@MainActor
enum NativeTabTransitionTrace {
    private static let signposter = OSSignposter(
        subsystem: "io.github.ender-wang.Remmich",
        category: "NativeTabs"
    )
    private static var startedAtByDestination: [NativeTabDestination: ContinuousClock.Instant] = [:]
    private static var intervalByDestination: [NativeTabDestination: OSSignpostIntervalState] = [:]

    static func begin(destination: NativeTabDestination) {
        if let interval = intervalByDestination.removeValue(forKey: destination) {
            signposter.endInterval("TabSelection", interval)
        }
        startedAtByDestination[destination] = .now
        intervalByDestination[destination] = signposter.beginInterval(
            "TabSelection",
            id: signposter.makeSignpostID(),
            "destination=\(String(describing: destination))"
        )
    }

    static func elapsedMilliseconds(for destination: NativeTabDestination) -> Int? {
        guard let startedAt = startedAtByDestination[destination] else { return nil }
        let components = startedAt.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    static func end(destination: NativeTabDestination) {
        guard let interval = intervalByDestination.removeValue(forKey: destination) else { return }
        signposter.endInterval("TabSelection", interval)
    }
}

/// 生成五项底栏；时间范围模式和主模式都将“我的”放在最右，避免产生More溢出入口。
enum NativeTabLayout {
    static let primaryDestinations: [NativeTabDestination] = [
        .photos, .videos, .library, .search, .account,
    ]

    /// compactOwner选择照片或视频的时间范围布局；nil返回完整主布局，数组顺序即显示顺序。
    static func destinations(compactOwner: NativeTabDestination?) -> [NativeTabDestination] {
        switch compactOwner {
        case .photos:
            [.photos, .weeks, .months, .years, .account]
        case .videos:
            [.videos, .weeks, .months, .years, .account]
        default:
            primaryDestinations
        }
    }

    /// destination为当前逻辑页，direction给出滑动方向，compactOwner限定可见布局；边界返回nil。
    static func adjacentDestination(
        from destination: NativeTabDestination,
        direction: NativeTabPageDirection,
        compactOwner: NativeTabDestination?
    ) -> NativeTabDestination? {
        let destinations = destinations(compactOwner: compactOwner)
        // 相簿与分类共享图库底栏位置，仍保留各自导航和手势身份。
        let canonical = destination == .albums ? NativeTabDestination.library : destination
        guard let index = destinations.firstIndex(of: canonical) else { return nil }
        let adjacentIndex = direction == .next ? index + 1 : index - 1
        guard destinations.indices.contains(adjacentIndex) else { return nil }
        return destinations[adjacentIndex]
    }

    /// source/destination为逻辑身份，compactOwner限定当前布局；同一物理标签或不存在时不产生页面动画。
    static func pageDirection(
        from source: NativeTabDestination,
        to destination: NativeTabDestination,
        compactOwner: NativeTabDestination?
    ) -> NativeTabPageDirection? {
        let destinations = destinations(compactOwner: compactOwner)
        let source = source == .albums ? NativeTabDestination.library : source
        let destination = destination == .albums ? NativeTabDestination.library : destination
        guard let sourceIndex = destinations.firstIndex(of: source),
              let destinationIndex = destinations.firstIndex(of: destination),
              sourceIndex != destinationIndex
        else { return nil }
        return destinationIndex > sourceIndex ? .next : .previous
    }
}

enum NativeTabPageGesturePolicy {
    static func blocksRootPaging(startingAt touchedView: UIView?) -> Bool {
        var responder: UIResponder? = touchedView
        while let current = responder {
            if let controller = current as? UIViewController,
               let navigation = controller.navigationController,
               navigation.viewControllers.count > 1
            {
                return true
            }
            responder = current.next
        }
        var candidate = touchedView
        while let view = candidate {
            if let scrollView = view as? UIScrollView,
               scrollView.alwaysBounceHorizontal
               || scrollView.contentSize.width > scrollView.bounds.width + 1
            {
                return true
            }
            candidate = view.superview
        }
        return false
    }
}

/// One UIKit-owned tab bar on both devices. UIKit owns the Liquid Glass treatment
/// and animates the range tabs when either media timeline changes browsing mode.
nonisolated struct NativeLibraryContentRevision: Equatable {
    let profile: ConnectionProfile?
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus

    static let restoring = Self(
        profile: nil,
        activeRoute: nil,
        routeStatus: .waitingForNetwork
    )
}

/// UIKit拥有底栏和既有手势转场；SwiftUI提供各页与语言，更新根内容时保留导航和任务实例。
struct NativeAppTabShell: UIViewControllerRepresentable {
    @Binding var selection: NativeTabDestination
    @Binding var tabBarTop: CGFloat
    let rotationState: TimelineRotationState
    let contentActivationState: NativeTabContentActivationState
    var preparedDestinations: Set<NativeTabDestination> = []
    let compactOwner: NativeTabDestination?
    let isViewerPresented: Bool
    let pageSwipeEnabled: Bool
    var albumSearchExpanded: () -> Bool = { false }
    var pageInteractionChanged: (Bool) -> Void = { _ in }
    let photosScrollRequest: Int
    let videosScrollRequest: Int
    var albumsScrollRequest: Int = 0
    let groupedScrollRequests: [NativeTabDestination: Int]
    let groupedMediaOwner: NativeTabDestination
    var timelineRangeRequestGeneration = 0
    var languageCode: String = L10n.language.resolvedCode()
    var librarySection: NativeTabDestination = .albums
    var libraryAtRoot = true
    var selectLibrarySection: (NativeTabDestination) -> Void = { _ in }
    let libraryContentRevision: NativeLibraryContentRevision
    let photosRetapped: () -> Void
    let videosRetapped: () -> Void
    var albumsRetapped: () -> Void = {}
    let libraryRetapped: () -> Void
    let groupedTabRetapped: (NativeTabDestination) -> Void
    var account: AnyView = .init(EmptyView())
    let photos: AnyView
    let videos: AnyView
    let albums: AnyView
    let library: AnyView
    let years: AnyView
    let months: AnyView
    let weeks: AnyView
    let search: AnyView
    var locations: AssetLocationStore?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = MeasuringTabBarController()
        controller.bindRotationState(rotationState)
        controller.tabBarTopChanged = { [weak coordinator = context.coordinator] top in
            coordinator?.setTabBarTop(top)
        }
        controller.mode = .tabBar
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.installPrimaryPageSwipeRecognizers(on: controller)
        context.coordinator.update(self, animated: false)
        return controller
    }

    func updateUIViewController(_: UITabBarController, context: Context) {
        context.coordinator.controller?.bindRotationState(rotationState)
        context.coordinator.update(self, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITabBarControllerDelegate {
        private static let logger = Logger(
            subsystem: "io.github.ender-wang.Remmich",
            category: "NativeTabs"
        )

        fileprivate weak var controller: MeasuringTabBarController?
        private var parent: NativeAppTabShell
        private var installedTabs: [NativeTabDestination]?
        private var isUpdatingTabs = false
        private var didResolveLibrary = false
        private var tabBarInteractionBlockedByViewer = false
        private var didResolveVideos = false
        private var laidOutPreparedDestinations: Set<NativeTabDestination> = []
        private var contentActivationGeneration = 0
        private var contentActivationTask: Task<Void, Never>?
        private var lastDestinationChange: (
            destination: NativeTabDestination,
            instant: ContinuousClock.Instant
        )?
        private var pendingPageDirection: NativeTabPageDirection?
        private var pageInteractionDirection: NativeTabPageDirection?
        private var pageInteractionController: UIPercentDrivenInteractiveTransition?
        private var pageInteractionDestination: NativeTabDestination?
        private weak var pageInteractionPreviousTab: UITab?
        private var pendingTabBarTop: CGFloat?

        private lazy var pagePanRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(primaryPagePanned(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        private lazy var photosController = tabHostingController(
            rootView: parent.photos,
            destination: .photos,
            ignoresContainerSafeArea: true
        )
        private lazy var videosController = tabHostingController(
            rootView: parent.videos,
            destination: .videos,
            ignoresContainerSafeArea: true
        )
        private lazy var libraryController = tabHostingController(rootView: libraryRoot, destination: parent.librarySection)
        private lazy var accountController = tabHostingController(rootView: parent.account, destination: .account)

        /// 两个图库子页保持挂载，以保留独立滚动、相簿搜索与导航历史。
        private var libraryRoot: AnyView {
            AnyView(LibraryTabContent(selection: parent.librarySection, atRoot: parent.libraryAtRoot,
                                      select: parent.selectLibrarySection, albums: parent.albums, collections: parent.library))
        }

        private lazy var yearsController = tabHostingController(
            rootView: parent.years,
            destination: .years,
            ignoresContainerSafeArea: true
        )
        private lazy var monthsController = tabHostingController(
            rootView: parent.months,
            destination: .months,
            ignoresContainerSafeArea: true
        )
        private lazy var weeksController = tabHostingController(
            rootView: parent.weeks,
            destination: .weeks,
            ignoresContainerSafeArea: true
        )
        private lazy var searchController = tabHostingController(
            rootView: parent.search,
            destination: .search
        )

        private func tabHostingController(
            rootView: AnyView,
            destination: NativeTabDestination,
            ignoresContainerSafeArea: Bool = false
        ) -> TabContentHostingController {
            let controller = TabContentHostingController(rootView: hostedRoot(rootView))
            if ignoresContainerSafeArea {
                controller.safeAreaRegions = .keyboard
            }
            controller.didAppear = { [weak self] in
                self?.scheduleContentActivation(destination)
            }
            return controller
        }

        /// view为已有页面；独立HostingController显式接收位置服务和应用语言，不依赖跨UIKit的环境继承。
        private func hostedRoot(_ view: AnyView) -> AnyView {
            AnyView(view.environment(\.assetLocations, parent.locations).environment(\.locale, Locale(identifier: parent.languageCode)))
        }

        private lazy var photosTab = UITab(
            title: L10n.string("Photos", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "photo.on.rectangle.angled"), identifier: "photos"
        ) { [weak self] _ in self?.photosController ?? UIViewController() }

        private lazy var videosTab = UITab(
            title: L10n.string("Videos", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "play.rectangle"), identifier: "videos"
        ) { [weak self] _ in self?.videosController ?? UIViewController() }

        private lazy var libraryTab = UITab(
            title: L10n.string("Library", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "square.grid.2x2"), identifier: "library"
        ) { [weak self] _ in
            guard let self else { return UIViewController() }
            didResolveLibrary = true
            return libraryController
        }

        private lazy var yearsTab = UITab(
            title: L10n.string("Years", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "calendar.circle"), identifier: "years"
        ) { [weak self] _ in self?.yearsController ?? UIViewController() }

        private lazy var monthsTab = UITab(
            title: L10n.string("Months", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "calendar"), identifier: "months"
        ) { [weak self] _ in self?.monthsController ?? UIViewController() }

        private lazy var weeksTab = UITab(
            title: L10n.string("Weeks", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "7.circle"), identifier: "weeks"
        ) { [weak self] _ in self?.weeksController ?? UIViewController() }

        /// 普通搜索标签遵循数组顺序，保证“我的”始终在最右；不使用系统独立的尾部搜索槽。
        private lazy var searchTab = UITab(title: L10n.string("Search", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "magnifyingglass"), identifier: "search") { [weak self] _ in
            self?.searchController ?? UIViewController()
        }

        private lazy var accountTab = UITab(title: L10n.string("Me", language: AppLanguage(rawValue: parent.languageCode)), image: UIImage(systemName: "person.crop.circle"), identifier: "account") { [weak self] _ in
            self?.accountController ?? UIViewController()
        }

        init(_ parent: NativeAppTabShell) {
            self.parent = parent
        }

        deinit {
            contentActivationTask?.cancel()
        }

        func installPrimaryPageSwipeRecognizers(on controller: UITabBarController) {
            controller.view.addGestureRecognizer(pagePanRecognizer)
        }

        private func scheduleContentActivation(_ destination: NativeTabDestination) {
            guard !parent.contentActivationState.isHydrated(destination) else { return }
            contentActivationGeneration &+= 1
            let generation = contentActivationGeneration
            contentActivationTask?.cancel()
            contentActivationTask = Task { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      generation == contentActivationGeneration,
                      parent.selection == destination,
                      controller?.selectedTab === tab(for: destination)
                else { return }

                // Let UIKit commit the tab selection before the destination's
                // SwiftUI hierarchy is mounted. This is a scheduler boundary,
                // not a timed delay: tab navigation remains the control plane,
                // while timeline hydration follows on the next available turn.
                await Task.yield()
                guard !Task.isCancelled,
                      generation == contentActivationGeneration,
                      parent.selection == destination,
                      controller?.selectedTab === tab(for: destination)
                else { return }

                parent.contentActivationState.activate(destination)
                contentActivationTask = nil
                Self.logger.info(
                    "Native tab content activated destination=\(String(describing: destination), privacy: .public)"
                )
            }
        }

        func setTabBarTop(_ top: CGFloat) {
            if pendingTabBarTop != nil {
                pendingTabBarTop = top
                return
            }
            guard abs(parent.tabBarTop - top) > 0.5 else { return }
            pendingTabBarTop = top
            Task { @MainActor [weak self] in
                guard let self, let top = pendingTabBarTop else { return }
                pendingTabBarTop = nil
                // A second layout can restore the published value before this task runs.
                if abs(parent.tabBarTop - top) > 0.5 {
                    parent.tabBarTop = top
                }
            }
        }

        /// next为最新页面快照；animated只控制标签换组。语言变更更新文案环境，不重置页面身份或备份协调器。
        func update(_ next: NativeAppTabShell, animated: Bool) {
            let previous = parent
            parent = next

            let mediaLayoutChanged = previous.tabBarTop != next.tabBarTop
            let rangeRequestChanged = previous.timelineRangeRequestGeneration != next.timelineRangeRequestGeneration
            if previous.photosScrollRequest != next.photosScrollRequest || rangeRequestChanged {
                photosController.rootView = hostedRoot(next.photos)
            }
            if previous.videosScrollRequest != next.videosScrollRequest || rangeRequestChanged {
                videosController.rootView = hostedRoot(next.videos)
            }
            if didResolveLibrary,
               previous.libraryContentRevision != next.libraryContentRevision || previous.librarySection != next.librarySection
               || previous.libraryAtRoot != next.libraryAtRoot || previous.albumsScrollRequest != next.albumsScrollRequest || mediaLayoutChanged
            {
                libraryController.rootView = hostedRoot(libraryRoot)
            }
            if mediaLayoutChanged
                || previous.groupedScrollRequests != next.groupedScrollRequests
                || previous.groupedMediaOwner != next.groupedMediaOwner
            {
                yearsController.rootView = hostedRoot(next.years)
                monthsController.rootView = hostedRoot(next.months)
                weeksController.rootView = hostedRoot(next.weeks)
            }

            accountController.rootView = hostedRoot(next.account)
            if previous.languageCode != next.languageCode {
                photosController.rootView = hostedRoot(next.photos)
                videosController.rootView = hostedRoot(next.videos)
                libraryController.rootView = hostedRoot(libraryRoot)
                searchController.rootView = hostedRoot(next.search)
                yearsController.rootView = hostedRoot(next.years)
                monthsController.rootView = hostedRoot(next.months)
                weeksController.rootView = hostedRoot(next.weeks)
                for (tab, title) in [(photosTab, "Photos"), (videosTab, "Videos"), (libraryTab, "Library"), (searchTab, "Search"), (accountTab, "Me"), (yearsTab, "Years"), (monthsTab, "Months"), (weeksTab, "Weeks")] {
                    tab.title = L10n.string(title, language: AppLanguage(rawValue: next.languageCode))
                }
                if let controller {
                    // UITab的模型标题改变后，iPhone仍可能保留已创建的UITabBarItem文案；同步实际项目而不重建导航宿主。
                    if let items = controller.tabBar.items, items.count == controller.tabs.count {
                        for (item, tab) in zip(items, controller.tabs) {
                            item.title = tab.title
                        }
                    }
                    controller.setTabs(controller.tabs, animated: false)
                    controller.tabBar.setNeedsLayout()
                }
            }
            guard let controller else { return }
            if tabBarInteractionBlockedByViewer != next.isViewerPresented {
                tabBarInteractionBlockedByViewer = next.isViewerPresented
                setTabBarInteractionBlocked(next.isViewerPresented, in: controller)
            }
            isUpdatingTabs = true
            defer { isUpdatingTabs = false }
            let destinations = NativeTabLayout.destinations(compactOwner: next.compactOwner)
            if installedTabs != destinations {
                installedTabs = destinations
                controller.setTabs(
                    destinations.map(tab(for:)),
                    animated: animated
                )
            }
            let intendedTab = tab(for: next.selection)
            if pageInteractionController == nil,
               controller.selectedTab !== intendedTab
            {
                controller.selectedTab = intendedTab
            }
            resolveVideoTab(in: controller)
            layoutPreparedTabs(in: controller)
        }

        private func layoutPreparedTabs(in controller: UITabBarController) {
            let bounds = controller.view.bounds
            guard bounds.width > 0, bounds.height > 0, controller.transitionCoordinator == nil else { return }
            let tabs: [(NativeTabDestination, AnyView)] = [
                (.videos, parent.videos), (.library, libraryRoot), (.search, parent.search), (.account, parent.account),
            ]
            for (destination, root) in tabs
                where parent.preparedDestinations.contains(destination)
                && !laidOutPreparedDestinations.contains(destination)
                && installedTabs?.contains(destination) == true
            {
                let destinationTab = tab(for: destination)
                guard controller.selectedTab !== destinationTab,
                      let hosting = destinationTab.viewController as? TabContentHostingController else { continue }
                hosting.rootView = hostedRoot(root)
                hosting.loadViewIfNeeded()
                hosting.view.frame = bounds
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                laidOutPreparedDestinations.insert(destination)
            }
        }

        private func resolveVideoTab(in controller: UITabBarController) {
            guard !didResolveVideos,
                  parent.selection != .videos,
                  installedTabs?.contains(.videos) == true
            else { return }

            let bounds = controller.view.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let controllerToWarm = videosTab.viewController
            else { return }

            // Resolve through UITab before the tab bar becomes interactive. Accessing the lazy
            // controller directly does not populate UITab's provider cache, so UIKit would still
            // perform first-time controller resolution on the user's first Videos tap.
            let startedAt = ContinuousClock.now
            controllerToWarm.loadViewIfNeeded()
            controllerToWarm.view.frame = bounds
            controllerToWarm.view.setNeedsLayout()
            controllerToWarm.view.layoutIfNeeded()
            didResolveVideos = true
            let components = startedAt.duration(to: .now).components
            let elapsedMilliseconds = Int(components.seconds) * 1000
                + Int(components.attoseconds / 1_000_000_000_000_000)
            Self.logger.info(
                "Videos tab controller resolved size=\(Int(bounds.width))x\(Int(bounds.height)) elapsedMs=\(elapsedMilliseconds)"
            )
        }

        private func setTabBarInteractionBlocked(
            _ blocked: Bool,
            in controller: UITabBarController
        ) {
            let tabBar = controller.tabBar
            // The full-screen viewer covers the timeline and its tab bar. Keep both
            // drawn underneath so dismissal does not reveal a newly fading-in bar.
            tabBar.isHidden = false
            tabBar.alpha = 1
            tabBar.isUserInteractionEnabled = !blocked
            tabBar.accessibilityElementsHidden = blocked
        }

        func tabBarController(_: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard !isUpdatingTabs, let destination = destination(for: selectedTab) else { return }
            defer {
                if pageInteractionController == nil {
                    pendingPageDirection = nil
                }
            }
            publishSelection(
                destination: destination,
                selectedTab: selectedTab,
                previousTab: previousTab
            )
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            shouldSelectTab tab: UITab
        ) -> Bool {
            if !isUpdatingTabs, tab !== libraryTab, tabBarController.selectedTab === libraryTab,
               parent.albumSearchExpanded(), let outgoingView = libraryTab.viewController?.viewIfLoaded
            {
                outgoingView.endEditing(true)
            }
            // These stacks handle a retap one page at a time.
            if !isUpdatingTabs, pageInteractionController == nil,
               !parent.isViewerPresented, tabBarController.selectedTab === tab,
               let destination = destination(for: tab), destination == .albums || destination == .library
            {
                publishSelection(destination: destination, selectedTab: tab, previousTab: tab, explicitRetap: true)
                return false
            }
            guard !isUpdatingTabs,
                  pageInteractionController == nil,
                  NativeTabPageAnimationPolicy.allowsTap(viewerPresented: parent.isViewerPresented,
                                                         reduceMotion: UIAccessibility.isReduceMotionEnabled),
                  let selectedTab = tabBarController.selectedTab,
                  selectedTab !== tab,
                  let source = destination(for: selectedTab),
                  let destination = destination(for: tab)
            else { return true }

            pendingPageDirection = NativeTabLayout.pageDirection(
                from: source,
                to: destination,
                compactOwner: parent.compactOwner
            )
            return true
        }

        @objc private func primaryPagePanned(_ recognizer: UIPanGestureRecognizer) {
            guard let controller else { return }

            switch recognizer.state {
            case .began:
                beginPageInteraction(using: recognizer, in: controller)
            case .changed:
                updatePageInteraction(using: recognizer, in: controller)
            case .ended:
                completePageInteraction(using: recognizer, in: controller)
            case .cancelled, .failed:
                cancelPageInteraction(in: controller)
            default:
                break
            }
        }

        /// recognizer提供当前窗口方向，controller拥有交互转场；图库别名映射到当前子页，取消仍恢复原标签。
        private func beginPageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard pageInteractionController == nil,
                  let previousTab = controller.selectedTab
            else { return }

            let velocity = recognizer.velocity(in: controller.view)
            let direction: NativeTabPageDirection = velocity.x < 0 ? .next : .previous
            guard let adjacent = NativeTabLayout.adjacentDestination(
                from: parent.selection,
                direction: direction,
                compactOwner: parent.compactOwner
            ) else { return }
            // 图库标签的相簿/分类共用物理位置，滑入时恢复当前子页而不是发布错误的活动身份。
            let destination = adjacent == .library ? parent.librarySection : adjacent

            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            interaction.completionSpeed = 1
            pageInteractionController = interaction
            pageInteractionDirection = direction
            pageInteractionDestination = destination
            pageInteractionPreviousTab = previousTab
            parent.pageInteractionChanged(true)
            pendingPageDirection = direction
            isUpdatingTabs = true
            controller.selectedTab = tab(for: destination)
            isUpdatingTabs = false

            guard controller.transitionCoordinator != nil else {
                clearPageInteraction()
                return
            }
        }

        private func updatePageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard let interaction = pageInteractionController else { return }
            interaction.update(pageInteractionProgress(using: recognizer, in: controller))
        }

        private func completePageInteraction(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) {
            guard let interaction = pageInteractionController else { return }
            let progress = pageInteractionProgress(using: recognizer, in: controller)
            let velocity = recognizer.velocity(in: controller.view).x
            let forwardVelocity: CGFloat = switch pageInteractionDirection {
            case .next:
                -velocity
            case .previous:
                velocity
            case nil:
                0
            }

            if HorizontalPageSwipePolicy.shouldFinish(progress: progress, forwardVelocity: forwardVelocity) {
                finishPageInteraction(interaction, in: controller)
            } else {
                cancelPageInteraction(in: controller)
            }
        }

        private func finishPageInteraction(
            _ interaction: UIPercentDrivenInteractiveTransition,
            in controller: UITabBarController
        ) {
            guard let destination = pageInteractionDestination,
                  let previousTab = pageInteractionPreviousTab
            else {
                interaction.cancel()
                clearPageInteraction()
                return
            }

            let selectedTab = tab(for: destination)
            interaction.finish()
            completePageInteractionTransition(in: controller) { [weak self] cancelled in
                guard let self else { return }
                if cancelled {
                    restorePageInteractionPreviousTab(previousTab, in: controller)
                    if let previousDestination = self.destination(for: previousTab) {
                        parent.selection = previousDestination
                    }
                } else {
                    publishSelection(
                        destination: destination,
                        selectedTab: selectedTab,
                        previousTab: previousTab
                    )
                    scheduleContentActivation(destination)
                }
                clearPageInteraction()
            }
        }

        private func cancelPageInteraction(in controller: UITabBarController) {
            guard let interaction = pageInteractionController else { return }
            let previousTab = pageInteractionPreviousTab
            interaction.cancel()
            completePageInteractionTransition(in: controller) { [weak self] _ in
                guard let self else { return }
                if let previousTab {
                    restorePageInteractionPreviousTab(previousTab, in: controller)
                }
                clearPageInteraction()
            }
        }

        private func completePageInteractionTransition(
            in controller: UITabBarController,
            completion: @escaping (Bool) -> Void
        ) {
            guard let coordinator = controller.transitionCoordinator else {
                completion(false)
                return
            }
            coordinator.animate(alongsideTransition: nil) { context in
                let wasCancelled = context.isCancelled
                Task { @MainActor in
                    completion(wasCancelled)
                }
            }
        }

        private func restorePageInteractionPreviousTab(
            _ previousTab: UITab,
            in controller: UITabBarController
        ) {
            guard controller.selectedTab !== previousTab else { return }
            isUpdatingTabs = true
            controller.selectedTab = previousTab
            isUpdatingTabs = false
        }

        private func clearPageInteraction() {
            pendingPageDirection = nil
            pageInteractionDirection = nil
            pageInteractionController = nil
            pageInteractionDestination = nil
            pageInteractionPreviousTab = nil
            parent.pageInteractionChanged(false)
        }

        private func pageInteractionProgress(
            using recognizer: UIPanGestureRecognizer,
            in controller: UITabBarController
        ) -> CGFloat {
            HorizontalPageSwipePolicy.progress(distance: abs(recognizer.translation(in: controller.view).x), width: controller.view.bounds.width)
        }

        private func publishSelection(
            destination: NativeTabDestination,
            selectedTab: UITab,
            previousTab: UITab?,
            explicitRetap: Bool = false
        ) {
            controller?.discardRotationVisualHandoff(reason: "tab-selection")
            let isReselection = selectedTab === previousTab
            if isReselection, !explicitRetap,
               let lastDestinationChange,
               lastDestinationChange.destination == destination,
               lastDestinationChange.instant.duration(to: .now) < .milliseconds(320)
            {
                Self.logger.info(
                    "Native tab duplicate selection suppressed destination=\(String(describing: destination), privacy: .public)"
                )
                return
            }
            if !isReselection {
                lastDestinationChange = (destination, .now)
            }
            NativeTabTransitionTrace.begin(destination: destination)
            let selectedController = selectedTab.viewController
            Self.logger.info(
                "Native tab selected destination=\(String(describing: destination), privacy: .public) resolved=\(selectedController != nil) loaded=\(selectedController?.isViewLoaded == true) attached=\(selectedController?.viewIfLoaded?.window != nil)"
            )
            if selectedTab === photosTab, previousTab === photosTab {
                parent.photosRetapped()
            } else if selectedTab === videosTab, previousTab === videosTab {
                parent.videosRetapped()
            } else if selectedTab === libraryTab, previousTab === libraryTab {
                if parent.librarySection == .albums {
                    parent.albumsRetapped()
                } else {
                    parent.libraryRetapped()
                }
            } else if selectedTab === previousTab,
                      destination == .weeks || destination == .months || destination == .years
            {
                parent.groupedTabRetapped(destination)
            } else {
                parent.selection = destination
            }

            let transitionDuration = controller?.transitionCoordinator?.transitionDuration ?? 0
            Self.logger.info(
                "Native tab visual selection published destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1) transitionDurationMs=\(Int(transitionDuration * 1000))"
            )
            if let transitionCoordinator = controller?.transitionCoordinator {
                transitionCoordinator.animate(alongsideTransition: nil) { _ in
                    Task { @MainActor in
                        NativeTabTransitionTrace.end(destination: destination)
                        Self.logger.info(
                            "Native tab transition completed destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1)"
                        )
                    }
                }
            } else {
                Task { @MainActor in
                    await Task.yield()
                    NativeTabTransitionTrace.end(destination: destination)
                    Self.logger.info(
                        "Native tab next run loop destination=\(String(describing: destination), privacy: .public) elapsedMs=\(NativeTabTransitionTrace.elapsedMilliseconds(for: destination) ?? -1)"
                    )
                }
            }
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard canSwipePages else { return false }

            return !NativeTabPageGesturePolicy.blocksRootPaging(startingAt: touch.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pagePanRecognizer,
                  canSwipePages,
                  !UIAccessibility.isReduceMotionEnabled,
                  pageInteractionController == nil,
                  let controller
            else { return false }

            let velocity = pagePanRecognizer.velocity(in: controller.view)
            guard HorizontalPageSwipePolicy.canBegin(velocityX: velocity.x, velocityY: velocity.y)
            else { return false }

            let direction: NativeTabPageDirection = velocity.x < 0 ? .next : .previous
            if direction == .previous,
               pagePanRecognizer.location(in: controller.view).x < 32
            {
                return false
            }
            return NativeTabLayout.adjacentDestination(
                from: parent.selection,
                direction: direction,
                compactOwner: parent.compactOwner
            ) != nil
        }

        private var canSwipePages: Bool {
            parent.pageSwipeEnabled && !parent.isViewerPresented
                && !(parent.selection == .albums && parent.albumSearchExpanded())
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func tabBarController(
            _: UITabBarController,
            animationControllerForTransitionFrom _: UIViewController,
            to _: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            guard let direction = pendingPageDirection else { return nil }
            pendingPageDirection = nil
            return NativeTabPageAnimator(direction: direction)
        }

        func tabBarController(
            _: UITabBarController,
            interactionControllerFor _: any UIViewControllerAnimatedTransitioning
        ) -> (any UIViewControllerInteractiveTransitioning)? {
            pageInteractionController
        }

        /// destination是逻辑页面；albums/library返回同一个图库标签，其他页面各自保持稳定UIKit身份。
        private func tab(for destination: NativeTabDestination) -> UITab {
            switch destination {
            case .photos: photosTab
            case .videos: videosTab
            case .albums: libraryTab
            case .library: libraryTab
            case .account: accountTab
            case .years: yearsTab
            case .months: monthsTab
            case .weeks: weeksTab
            case .search: searchTab
            }
        }

        /// tab必须属于本宿主；图库返回当前子页身份，外部或未知标签返回nil。
        private func destination(for tab: UITab) -> NativeTabDestination? {
            if tab === photosTab {
                return .photos
            }
            if tab === videosTab {
                return .videos
            }
            if tab === libraryTab {
                return parent.librarySection
            }
            if tab === accountTab {
                return .account
            }
            if tab === yearsTab {
                return .years
            }
            if tab === monthsTab {
                return .months
            }
            if tab === weeksTab {
                return .weeks
            }
            if tab === searchTab {
                return .search
            }
            return nil
        }
    }
}

private final class NativeTabPageAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let direction: NativeTabPageDirection
    private var propertyAnimator: UIViewPropertyAnimator?

    init(direction: NativeTabPageDirection) {
        self.direction = direction
    }

    func transitionDuration(using _: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        NativePageSlideAnimation.duration
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        if let propertyAnimator {
            return propertyAnimator
        }

        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to),
              let toController = transitionContext.viewController(forKey: .to)
        else {
            transitionContext.completeTransition(false)
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }

        let container = transitionContext.containerView
        let width = container.bounds.width
        toView.frame = transitionContext.finalFrame(for: toController)
        container.addSubview(toView)

        let animator = NativePageSlideAnimation.makeAnimator(from: fromView, to: toView,
                                                             direction: direction, width: width)
        animator.addCompletion { [weak self] _ in
            fromView.transform = .identity
            toView.transform = .identity
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            self?.propertyAnimator = nil
        }
        propertyAnimator = animator
        return animator
    }
}

@MainActor
private final class TabContentHostingController: UIHostingController<AnyView> {
    var didAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear?()
    }
}

@MainActor
private final class MeasuringTabBarController: UITabBarController {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineRotation"
    )

    var tabBarTopChanged: ((CGFloat) -> Void)?
    private weak var rotationState: TimelineRotationState?
    private var rotationGeneration = 0
    private var rotationStartedAt: ContinuousClock.Instant?
    private var rotationTargetSize: CGSize?
    private var lastLoggedLayoutSize: CGSize?
    private var rotationVisualSnapshot: UIView?
    private var rotationVisualGeneration: Int?
    private var rotationVisualResolvedGeneration: Int?
    private var rotationVisualCompletedGeneration: Int?
    private var rotationVisualResolutionReason: String?

    func bindRotationState(_ state: TimelineRotationState) {
        guard rotationState !== state else { return }
        rotationState = state
        state.visualHandoffResolved = { [weak self] generation, verified, reason in
            self?.resolveRotationVisualHandoff(
                generation: generation,
                verified: verified,
                reason: reason
            )
        }
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        rotationGeneration += 1
        let generation = rotationGeneration
        let visualSnapshot = captureRotationVisualSnapshotIfEligible()
        rotationStartedAt = .now
        rotationTargetSize = size
        lastLoggedLayoutSize = nil
        rotationState?.begin(to: size)
        installRotationVisualSnapshot(
            visualSnapshot,
            generation: generation
        )
        let currentSize = view.bounds.size
        Self.logger.info(
            "Host rotation began generation=\(generation) current=\(Self.describe(currentSize), privacy: .public) target=\(Self.describe(size), privacy: .public) durationMs=\(Int(coordinator.transitionDuration * 1000))"
        )
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.completeRotation(generation: generation, cancelled: context.isCancelled)
        }
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBar.layoutIfNeeded()
        tabBarTopChanged?(visibleTop(of: tabBar) ?? tabBar.frame.minY)
        updateRotationVisualSnapshotFrame()
        guard let target = rotationTargetSize,
              lastLoggedLayoutSize != view.bounds.size
        else { return }
        lastLoggedLayoutSize = view.bounds.size
        let elapsed = rotationStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        let generation = rotationGeneration
        let bounds = view.bounds.size
        let tabBarFrame = tabBar.frame
        Self.logger.info(
            "Host rotation layout generation=\(generation) bounds=\(Self.describe(bounds), privacy: .public) target=\(Self.describe(target), privacy: .public) tabBar=\(Self.describe(tabBarFrame), privacy: .public) elapsedMs=\(elapsed)"
        )
    }

    private func completeRotation(generation: Int, cancelled: Bool) {
        let elapsed = rotationStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        let bounds = view.bounds.size
        Self.logger.info(
            "Host rotation completed generation=\(generation) cancelled=\(cancelled) bounds=\(Self.describe(bounds), privacy: .public) elapsedMs=\(elapsed)"
        )
        guard generation == rotationGeneration else { return }
        rotationState?.complete()
        rotationVisualCompletedGeneration = generation
        if cancelled {
            rotationVisualResolvedGeneration = generation
            rotationVisualResolutionReason = "host-cancelled"
        }
        releaseRotationVisualHandoffIfReady(generation: generation)
        rotationStartedAt = nil
        rotationTargetSize = nil
        lastLoggedLayoutSize = nil
    }

    func discardRotationVisualHandoff(reason: String) {
        guard let snapshot = rotationVisualSnapshot else { return }
        let generation = rotationVisualGeneration ?? -1
        snapshot.layer.removeAllAnimations()
        snapshot.removeFromSuperview()
        resetRotationVisualHandoff()
        Self.logger.info(
            "Rotation visual snapshot released generation=\(generation) reason=\(reason, privacy: .public) immediate=true"
        )
    }

    private func captureRotationVisualSnapshotIfEligible() -> UIView? {
        guard let rotationState,
              let destination = selectedTimelineDestination,
              rotationState.isVisualHandoffEligible(for: destination),
              let contentView = selectedViewController?.viewIfLoaded,
              contentView.window != nil,
              !contentView.bounds.isEmpty
        else { return nil }

        return contentView.snapshotView(afterScreenUpdates: false)
    }

    private func installRotationVisualSnapshot(
        _ candidate: UIView?,
        generation: Int
    ) {
        rotationVisualResolvedGeneration = nil
        rotationVisualCompletedGeneration = nil
        rotationVisualResolutionReason = nil

        if let snapshot = rotationVisualSnapshot {
            snapshot.layer.removeAllAnimations()
            snapshot.alpha = 1
            rotationVisualGeneration = generation
            Self.logger.info(
                "Rotation visual snapshot captured generation=\(generation) inherited=true frame=\(Self.describe(snapshot.frame), privacy: .public)"
            )
            return
        }
        guard let candidate,
              let contentView = selectedViewController?.viewIfLoaded
        else {
            rotationVisualGeneration = nil
            return
        }

        candidate.isUserInteractionEnabled = false
        candidate.accessibilityElementsHidden = true
        candidate.frame = contentView.convert(contentView.bounds, to: view)
        candidate.clipsToBounds = true
        view.insertSubview(candidate, belowSubview: tabBar)
        rotationVisualSnapshot = candidate
        rotationVisualGeneration = generation
        Self.logger.info(
            "Rotation visual snapshot captured generation=\(generation) inherited=false frame=\(Self.describe(candidate.frame), privacy: .public)"
        )
    }

    private func updateRotationVisualSnapshotFrame() {
        guard let snapshot = rotationVisualSnapshot,
              let contentView = selectedViewController?.viewIfLoaded,
              contentView.window != nil
        else { return }
        snapshot.frame = contentView.convert(contentView.bounds, to: view)
    }

    private func resolveRotationVisualHandoff(
        generation: Int,
        verified: Bool,
        reason: String
    ) {
        guard rotationVisualGeneration == generation else { return }
        rotationVisualResolvedGeneration = generation
        rotationVisualResolutionReason = reason
        let hostCompleted = rotationVisualCompletedGeneration == generation
        Self.logger.info(
            "Rotation visual destination ready generation=\(generation) verified=\(verified) reason=\(reason, privacy: .public) hostCompleted=\(hostCompleted)"
        )
        releaseRotationVisualHandoffIfReady(generation: generation)
    }

    private func releaseRotationVisualHandoffIfReady(generation: Int) {
        guard rotationVisualGeneration == generation,
              rotationVisualResolvedGeneration == generation,
              rotationVisualCompletedGeneration == generation,
              let snapshot = rotationVisualSnapshot
        else { return }

        let reason = rotationVisualResolutionReason ?? "resolved"
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.12
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
        } completion: { [weak self, weak snapshot] _ in
            guard self?.rotationVisualGeneration == generation else { return }
            snapshot?.removeFromSuperview()
            self?.resetRotationVisualHandoff()
        }
        Self.logger.info(
            "Rotation visual snapshot released generation=\(generation) reason=\(reason, privacy: .public) immediate=false"
        )
    }

    private func resetRotationVisualHandoff() {
        rotationVisualSnapshot = nil
        rotationVisualGeneration = nil
        rotationVisualResolvedGeneration = nil
        rotationVisualCompletedGeneration = nil
        rotationVisualResolutionReason = nil
    }

    private var selectedTimelineDestination: NativeTabDestination? {
        switch selectedTab?.identifier {
        case "photos": .photos
        case "videos": .videos
        default: nil
        }
    }

    private nonisolated static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private nonisolated static func describe(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    private nonisolated static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func visibleTop(of root: UIView) -> CGFloat? {
        guard !root.isHidden, root.alpha > 0.01, !root.bounds.isEmpty else { return nil }

        var top = root.convert(root.bounds, to: view).minY
        for subview in root.subviews {
            if let subviewTop = visibleTop(of: subview) {
                top = min(top, subviewTop)
            }
        }
        return top
    }
}
