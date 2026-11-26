import SwiftUI

/// 图库分类保留集合与组织导航；账户和同步配置统一由底栏“我的”持有。
struct LibraryView: View {
    @Environment(\.displayScale) private var displayScale

    let collections: [FixtureCollection]
    var exports: MediaExportController?
    let savedPhotos: SavedPhotosLibrary
    var media: MediaLibraryController?
    var collectionSource: ImmichTimelineRepository?
    var assetDetails: (any AssetDetailReading)?
    let session: AccountSession
    let libraryIndex: LibraryIndexController
    @Binding var navigationPath: NavigationPath
    let navigationRoot: CardNavigationRoot
    let openLibraryCard: (LibraryHubDestination) -> Void
    var reconcileNavigationRoot: () -> Void = {}
    var sessionController: AppSessionController?
    var tabSelectionState: NativeTabSelectionState?
    var viewerPresentations: AssetViewerPresentationStore?
    var tabBarTop: Binding<CGFloat> = .constant(0)
    var viewerVisibilityChanged: (Bool) -> Void = { _ in }
    var opening = LibraryOpeningState()
    var hubReadyForRotation = true

    @Namespace private var libraryCardTransition

    private let avatarSize: CGFloat = 44
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8

    /// 集合卡沿用现有卡片转场；组织入口仅在真实仓库与媒体通道可用时出现，不填充演示结果。
    var body: some View {
        let preferences = opening.preferences
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                LibraryHubScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LibraryHubCardLayout {
                            if let exports, !exports.ready || !exports.jobs.isEmpty {
                                let newest = exports.latestCompletedDownload
                                LibraryHubLink {
                                    DownloadsView(exports: exports)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Save History"),
                                                          count: exports.ready ? exports.jobs.count : nil,
                                                          symbol: "clock.arrow.circlepath",
                                                          appearance: newest == nil || media == nil ? .glass : .photographic)
                                    {
                                        if let newest, let media {
                                            let saved = exports.journal.receipts.first { $0.key == newest.key }
                                                .flatMap { savedPhotos.item(photosID: $0.photosID) }
                                            LibraryAssetCover(assetID: newest.assetID, revision: newest.revision, media: media, savedPhoto: saved,
                                                              preparedImage: opening.historyImage(for: newest, photo: saved, scale: displayScale))
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-download-history")
                            }
                            if showsOnDeviceCard {
                                onDeviceLink
                            }
                            if let collectionSource, let media, let assetDetails {
                                collectionCard(.recentlyTaken, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.recentlyAdded, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.favorites, source: collectionSource, media: media, assetDetails: assetDetails)
                                LibraryHubLink {
                                    LibraryRandomPhotosView(source: collectionSource, media: media, assetDetails: assetDetails)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Random photos"), symbol: "shuffle", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-random-photos")
                                LibraryHubLink {
                                    LibraryPendingAlbumsView(source: collectionSource, ownerID: session.userID, media: media,
                                                             assetDetails: assetDetails, context: collectionNavigation)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Pending albums"), symbol: "tray", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-pending-albums")
                                LibraryHubLink {
                                    NativeStackManagementView(source: collectionSource, media: media)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Photo stacks"), symbol: "square.stack", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-native-stacks")
                                LibraryHubLink {
                                    LibrarySceneStacksView(source: collectionSource, media: media, assetDetails: assetDetails)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Scene groups"), symbol: "rectangle.on.rectangle.angled", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-scene-stacks")
                                LibraryHubLink {
                                    LibrarySteamScenesView(source: collectionSource, ownerID: session.userID, media: media, assetDetails: assetDetails)
                                } label: {
                                    LibraryCollectionCard(title: L10n.string("Steam screenshots"), symbol: "gamecontroller", appearance: .glass) { EmptyView() }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-steam-scenes")
                                if preferences?.memoriesEnabled == true, !opening.memories.isConfirmedEmpty {
                                    LibraryMemoriesCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                        context: collectionNavigation, catalog: opening.memories,
                                                        rotationEnabled: hubReadyForRotation && navigationPath.isEmpty
                                                            && (tabSelectionState?.canActivateContent(in: .library) ?? true))
                                }
                                if preferences?.peopleEnabled == true, !opening.people.isConfirmedEmpty {
                                    LibraryDirectoryCard(directory: .people, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.people)
                                }
                                if !opening.places.isConfirmedEmpty || opening.placesCover.hasGeotags != false {
                                    LibraryDirectoryCard(directory: .places, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.places,
                                                         heatmap: opening.placesCover.image, placesMapSource: sessionController.map {
                                                             LibraryPlacesMapSource(store: $0.libraryIndexStore,
                                                                                    scope: MediaAccountScope(session: session), index: libraryIndex)
                                                         })
                                }
                                if preferences?.sharedLinksEnabled == true, opening.links.links?.isEmpty != true {
                                    LibrarySharedLinksCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                           context: collectionNavigation, store: opening.links)
                                }
                                if !opening.partners.isConfirmedEmpty {
                                    LibraryDirectoryCard(directory: .partners, source: collectionSource, media: media,
                                                         assetDetails: assetDetails, context: collectionNavigation, store: opening.partners)
                                }
                                if preferences?.foldersEnabled == true, opening.folders.tree?.children(of: nil).isEmpty != true {
                                    LibraryFoldersCard(source: collectionSource, media: media, assetDetails: assetDetails,
                                                       context: collectionNavigation, store: opening.folders)
                                }
                                collectionCard(.archive, source: collectionSource, media: media, assetDetails: assetDetails)
                                collectionCard(.trash, source: collectionSource, media: media, assetDetails: assetDetails)
                            }
                            ForEach(visibleFixtureCollections) { collection in
                                LibraryHubLink {
                                    CollectionDetailView(collection: collection)
                                        .libraryPageHeader(collection.title)
                                } label: {
                                    LibraryCollectionCard(title: collection.title,
                                                          symbol: collection.kind.systemImage, appearance: .photographic)
                                    {
                                        FixtureArtwork(palette: collection.palette)
                                    }
                                    .accessibilityIdentifier("collection-\(collection.id)")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, geometry.safeAreaInsets.top + verticalPadding + avatarSize + 8)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 16)
                    .frame(width: geometry.size.width)
                    .environment(\.libraryHubNavigation, LibraryHubNavigation(namespace: libraryCardTransition, open: openLibraryCard))
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                HStack {
                    Text("Library").font(.largeTitle.bold())
                    Spacer(minLength: avatarSize + 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, verticalPadding)
                .padding(.bottom, 8)
                .background {
                    LibraryTitleBackdrop()
                        .ignoresSafeArea(.container, edges: [.top, .horizontal])
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("Library")
        .toolbar(.hidden, for: .navigationBar)
        .background {
            CardNavigationRootAnchor(root: navigationRoot, didAppear: reconcileNavigationRoot)
                .allowsHitTesting(false)
        }
        .navigationDestination(for: LibraryHubDestination.self) { card in
            card.makeView()
                .background {
                    LibraryCardNavigation(didDisappear: reconcileNavigationRoot)
                        .allowsHitTesting(false)
                }
                .nativeEdgeBack(canBegin: false, priority: 25) { _ in }
                .cardNavigationDestination(id: card.id, in: libraryCardTransition)
        }
        .navigationDestination(for: LibraryNestedCardDestination.self) { destination in
            destination.makeView()
                .nativeEdgeBack(canBegin: false, priority: 25) { _ in }
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
                .toolbar(.visible, for: .navigationBar)
        }
    }

    private var showsOnDeviceCard: Bool {
        switch savedPhotos.state {
        case .missing: false
        case .ready: savedPhotos.limited || !savedPhotos.items.isEmpty
        default: true
        }
    }

    private var onDeviceLink: some View {
        LibraryHubLink {
            SavedPhotosView(library: savedPhotos, tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
                            tabBarTop: tabBarTop,
                            preparedTimelines: opening.downloadTimelines(library: savedPhotos, scope: MediaAccountScope(session: session)))
        } label: {
            onDeviceCard
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-downloads")
    }

    private var onDeviceCard: some View {
        LibraryCollectionCard(title: L10n.string("On Device"), count: savedPhotos.state == .ready ? savedPhotos.items.count : nil,
                              symbol: "arrow.down.circle", appearance: savedPhotos.items.isEmpty ? .glass : .photographic)
        {
            if let photo = savedPhotos.items.first {
                SavedPhotoThumbnail(library: savedPhotos, item: photo)
            }
        }
    }

    private var visibleFixtureCollections: [FixtureCollection] {
        collectionSource == nil ? collections.filter { !$0.assets.isEmpty } : []
    }

    private var collectionNavigation: LibraryCollectionNavigation {
        .init(tabBarTop: tabBarTop, tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
              viewerVisibilityChanged: viewerVisibilityChanged)
    }

    @ViewBuilder private func collectionCard(_ collection: LibraryAssetCollection, source: ImmichTimelineRepository,
                                             media: MediaLibraryController, assetDetails: any AssetDetailReading) -> some View
    {
        if opening.previews[collection]?.isEmpty != true {
            LibraryHubLink {
                let camera = sessionController.map {
                    LibraryCameraMetadata(store: $0.libraryIndexStore, scope: MediaAccountScope(session: session), details: $0.persistentAssetDetails)
                }
                let prepared = opening.collection(collection, source: source, camera: camera)
                LibraryCollectionTimeline(title: L10n.string(collection.rawValue), source: source, query: collection.query,
                                          separatesMedia: collection.separatesMedia, media: media, assetDetails: assetDetails,
                                          tabSelectionState: tabSelectionState, viewerPresentations: viewerPresentations,
                                          tabBarTop: tabBarTop, opening: prepared, libraryIndex: collection == .recentlyTaken ? libraryIndex : nil)
            } label: {
                LibraryAssetCollectionCard(collection: collection, media: media, opening: opening)
            }
            .buttonStyle(.plain)
        }
    }
}

struct LibraryTitleBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CollectionDetailView: View {
    let collection: FixtureCollection

    var body: some View {
        ScrollView {
            AssetGrid(assets: collection.assets)
        }
    }
}

#Preview {
    @Previewable @State var savedPhotos = SavedPhotosLibrary()
    @Previewable @State var navigationPath = NavigationPath()
    @Previewable @State var navigationRoot = CardNavigationRoot()
    NavigationStack(path: $navigationPath) {
        LibraryView(
            collections: PreviewFixtures.collections,
            savedPhotos: savedPhotos,
            session: .fixture,
            libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
            navigationPath: $navigationPath,
            navigationRoot: navigationRoot,
            openLibraryCard: { card in
                guard navigationPath.isEmpty else { return }
                withAnimation { navigationPath.append(card) }
            }
        )
    }
    .task {
        savedPhotos.configure(.init(scope: MediaAccountScope(session: .fixture), journal: nil))
        savedPhotos.startObserving()
        await savedPhotos.loadIfNeeded()
    }
    .onDisappear { savedPhotos.stopObserving() }
}
