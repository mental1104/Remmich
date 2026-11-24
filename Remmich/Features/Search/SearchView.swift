import SwiftUI

/// 真实搜索页，复用原生缩略图与查看器，不显示演示资源。
struct SearchView: View {
    let source: ImmichTimelineRepository?
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let showAccount: () -> Void
    private let searchReader: (any NativeSearchReading)?
    #if DEBUG
        private var searchCompletion: ((NativeSearchQuery) -> Void)?
    #endif
    @State private var query = NativeSearchQuery()
    @State private var store = NativeSearchStore()
    @State private var selection: Selection?
    @State private var people: [LibraryPerson] = []
    @State private var peopleError: String?
    @State private var suggestions: [NativeSearchSuggestionKind: [String]] = [:]
    @State private var suggestionError: String?
    @State private var loadingSuggestions = false
    @Namespace private var viewerNamespace

    /// source保留账号候选读取，media/assetDetails复用原生显示，showAccount打开账号入口。
    /// searchReader仅供显式依赖注入；正常调用省略它，仍使用真实账号仓库，不产生演示结果。
    init(source: ImmichTimelineRepository?, media: MediaLibraryController, assetDetails: any AssetDetailReading,
         showAccount: @escaping () -> Void, searchReader: (any NativeSearchReading)? = nil)
    {
        self.source = source
        self.media = media
        self.assetDetails = assetDetails
        self.showAccount = showAccount
        self.searchReader = searchReader
    }

    #if DEBUG
        /// 仅DEBUG的观察重载；source/media/details/account/reader语义同正常初始化。
        /// searchCompletion接收已结束store发布检查的条件，不改结果；Release没有此回调接口。
        init(source: ImmichTimelineRepository?, media: MediaLibraryController, assetDetails: any AssetDetailReading,
             showAccount: @escaping () -> Void, searchReader: (any NativeSearchReading)?,
             searchCompletion: @escaping (NativeSearchQuery) -> Void)
        {
            self.init(source: source, media: media, assetDetails: assetDetails, showAccount: showAccount, searchReader: searchReader)
            self.searchCompletion = searchCompletion
        }
    #endif

    /// 返回当前注入读取器或正常账号仓库；nil保留未连接状态，不创建网络替身。
    private var activeSearchReader: (any NativeSearchReading)? {
        if let searchReader {
            return searchReader
        }
        return source
    }

    /// 固定点击时的结果和查看器状态，不被后续分页改变。
    private struct Selection: Identifiable {
        let id = UUID()
        let route: AssetViewerRoute
        let timeline: PhotosTimelineStore
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Media", selection: $query.media) {
                    Text("All").tag(NativeSearchQuery.Media.all)
                    Text("Photos").tag(NativeSearchQuery.Media.image)
                    Text("Videos").tag(NativeSearchQuery.Media.video)
                }
                .pickerStyle(.segmented).padding(.horizontal)
                .accessibilityIdentifier("search-media")
                SearchPresetsPanel(query: $query, manager: media.management).padding(.horizontal)
                DisclosureGroup("Filters") {
                    VStack {
                        Picker("Search mode", selection: $query.mode) {
                            ForEach(NativeSearchQuery.Mode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("search-mode")
                        SearchChoiceField(title: "Country", text: $query.country, values: suggestions[.country])
                        SearchChoiceField(title: "State or province", text: $query.state, values: suggestions[.state])
                        SearchChoiceField(title: "City", text: $query.city, values: suggestions[.city])
                        SearchChoiceField(title: "Camera make", text: $query.cameraMake, values: suggestions[.cameraMake])
                        SearchChoiceField(title: "Camera model", text: $query.cameraModel, values: suggestions[.cameraModel])
                        SearchChoiceField(title: "Lens model", text: $query.lensModel, values: suggestions[.cameraLensModel])
                        Toggle("Favorites only", isOn: $query.favoritesOnly)
                            .accessibilityIdentifier("search-favorites")
                        Toggle("Archived only", isOn: $query.archivedOnly)
                        Picker("Rating", selection: $query.rating) {
                            Text("Any rating").tag(NativeSearchRating.any)
                            Text("Unrated").tag(NativeSearchRating.unrated)
                            ForEach(0 ... 5, id: \.self) { value in
                                Text("\(value) stars").tag(NativeSearchRating.stars(value))
                            }
                        }
                        if let suggestionError {
                            Text(suggestionError).font(.caption)
                        }
                        Button(loadingSuggestions ? "Loading choices" : "Load filter choices") { Task { await loadChoices() } }
                            .disabled(loadingSuggestions)
                        DateFilterRow(title: "Taken on or after", date: $query.takenAfter)
                        DateFilterRow(title: "Taken on or before", date: $query.takenBefore)
                        DisclosureGroup("Advanced filters") {
                            Picker("Orientation", selection: $query.orientation) {
                                Text("Any").tag(nil as NativeSearchQuery.Orientation?)
                                Text("Landscape").tag(Optional(NativeSearchQuery.Orientation.landscape))
                                Text("Portrait").tag(Optional(NativeSearchQuery.Orientation.portrait))
                            }
                            Picker("Albums", selection: $query.hasAlbums) {
                                Text("Any").tag(nil as Bool?)
                                Text("In an album").tag(Optional(true))
                                Text("Not in an album").tag(Optional(false))
                            }
                            SearchExifEditor(conditions: $query.exifConditions)
                        }
                        DisclosureGroup("People") {
                            if let peopleError {
                                Text(peopleError).font(.caption)
                            }
                            ForEach(people) { person in
                                Toggle(person.displayName, isOn: Binding(get: { query.personIDs.contains(person.id) }, set: { enabled in
                                    query.personIDs.removeAll { $0 == person.id }
                                    if enabled {
                                        query.personIDs.append(person.id)
                                    }
                                }))
                            }
                            Button("Load people") { Task { await loadPeople() } }
                        }
                    }.textFieldStyle(.roundedBorder)
                }.padding(.horizontal)
                    .accessibilityIdentifier("search-filters")
                if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                        .accessibilityIdentifier("search-error")
                    Button("Retry") { Task {
                        if let source = activeSearchReader {
                            if store.hasSearched, store.continuation == nil {
                                await store.search(query, source: source)
                            } else {
                                await store.loadMore(source: source)
                            }
                        }
                    } }
                    .accessibilityIdentifier("search-retry")
                }
                if invalidDateRange {
                    Text("End date must not be earlier than start date.").foregroundStyle(.secondary)
                }
                if store.assets.isEmpty, !store.isLoading {
                    ContentUnavailableView(store.hasSearched ? "No results" : "Search your library",
                                           systemImage: "magnifyingglass",
                                           description: Text("Choose a search mode or metadata filters."))
                        .accessibilityIdentifier("search-empty-state")
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100, maximum: 180), spacing: 2)], spacing: 2) {
                    ForEach(store.assets) { asset in
                        Button { open(asset) } label: {
                            LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
                                .aspectRatio(1, contentMode: .fit).clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.mediaKind == .video ? "Open video" : "Open photo")
                        .accessibilityIdentifier("search-result-\(asset.id)")
                    }
                }
                if store.isLoading {
                    ProgressView("Searching")
                }
                if store.continuation != nil, !store.isLoading {
                    Button("Load more") { Task {
                        if let source = activeSearchReader {
                            await store.loadMore(source: source)
                        }
                    } }
                    .accessibilityIdentifier("search-load-more")
                }
                if !store.assets.isEmpty {
                    Text("Loaded \(store.assets.count) items").font(.caption)
                        .accessibilityIdentifier("search-loaded-count")
                }
            }.padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query.text, prompt: Text(query.mode.title))
        .toolbar { AccountToolbarButton(action: showAccount) }
        .task(id: query) { await search() }
        .onChange(of: media.management.generation) { _, _ in
            store.invalidate()
            selection = nil
            query = .init()
            people = []
            peopleError = nil
            suggestions = [:]
            suggestionError = nil
            loadingSuggestions = false
        }
        .onChange(of: query.cameraMake) { _, _ in
            suggestions[.cameraModel] = nil
            suggestions[.cameraLensModel] = nil
        }
        .onChange(of: query.cameraModel) { _, _ in
            suggestions[.cameraLensModel] = nil
        }
        .fullScreenCover(item: $selection) { selected in
            AssetViewerView(route: selected.route, store: selected.timeline, media: media, assetDetails: assetDetails,
                            opensFromSource: false, namespace: viewerNamespace, close: { selection = nil },
                            visibilityChanged: { _ in })
        }
        .accessibilityIdentifier("search-root")
    }

    /// 防抖后按当前条件搜索；输入变化取消等待，不显示网络失败。
    private func search() async {
        store.invalidate()
        guard !invalidDateRange,
              !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.media != .all
              || !query.country.isEmpty || !query.state.isEmpty || !query.city.isEmpty || !query.cameraMake.isEmpty || !query.cameraModel.isEmpty || !query.lensModel.isEmpty
              || !query.personIDs.isEmpty || query.takenAfter != nil || query.takenBefore != nil
              || query.favoritesOnly || query.archivedOnly || query.rating != .any || query.orientation != nil || query.hasAlbums != nil || !query.exifConditions.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard let source = activeSearchReader else { return }
            let requested = query
            await store.search(requested, source: source)
            #if DEBUG
                searchCompletion?(requested)
            #endif
        } catch { /* 取消防抖无需显示错误。 */ }
    }

    /// 仅比较用户选择的日历日，不因DatePicker保留小时而误判同一天。
    private var invalidDateRange: Bool {
        guard let start = query.takenAfter, let end = query.takenBefore else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = query.timeZone
        return calendar.startOfDay(for: start) > calendar.startOfDay(for: end)
    }

    /// 按当前账号加载人物；跨账号/端点的迟到候选不可发布，不把权限失败当作空列表。
    private func loadPeople() async {
        let owner = media.management.generation
        guard let source else { return }
        peopleError = nil
        do {
            let values = try await source.libraryPeople()
            try Task.checkCancellation()
            guard owner == media.management.generation else { return }
            people = values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            guard owner == media.management.generation, !Task.isCancelled else { return }
            peopleError = "People could not be loaded. Check permissions and connection."
        }
    }

    /// 读取当前账号候选；仅在账号/厂商/型号未变化时发布，不清空已选条件或访问公共地名服务。
    private func loadChoices() async {
        guard let source, !loadingSuggestions else { return }
        let owner = media.management.generation
        let requested = query
        loadingSuggestions = true
        suggestionError = nil
        defer {
            if owner == media.management.generation {
                loadingSuggestions = false
            }
        }
        do {
            async let cities = source.searchSuggestions(.city, query: requested)
            async let countries = source.searchSuggestions(.country, query: requested)
            async let states = source.searchSuggestions(.state, query: requested)
            async let makes = source.searchSuggestions(.cameraMake, query: requested)
            async let models = source.searchSuggestions(.cameraModel, query: requested)
            async let lenses = source.searchSuggestions(.cameraLensModel, query: requested)
            let values = try await (cities, makes, models, countries, states, lenses)
            try Task.checkCancellation()
            guard owner == media.management.generation, requested.cameraMake == query.cameraMake, requested.cameraModel == query.cameraModel else { return }
            suggestions = [.city: values.0, .cameraMake: values.1, .cameraModel: values.2, .country: values.3, .state: values.4, .cameraLensModel: values.5]
        } catch {
            guard owner == media.management.generation, !Task.isCancelled else { return }
            suggestionError = "Filter choices could not be loaded. You can still enter values manually."
        }
    }

    /// asset为点击项；创建仅包含已加载结果的查看器快照，不修改主时间线。
    private func open(_ asset: TimelineAssetSummary) {
        let snapshot = NativeSearchSnapshot(assets: store.assets)
        let timeline = PhotosTimelineStore(reader: snapshot)
        timeline.bootstrap(.init(generation: 0, summaries: [.init(id: NativeSearchSnapshot.bucket, assetCount: store.assets.count)],
                                 assetsByBucket: [NativeSearchSnapshot.bucket: store.assets],
                                 groupedCatalogs: .init(), isComplete: true))
        selection = Selection(route: .init(selectedAsset: asset, initialAssets: store.assets,
                                           origin: .timeline(bucketID: NativeSearchSnapshot.bucket, contentName: "Search")), timeline: timeline)
    }
}

/// 编辑EXIF原子槽位；更新同字段/运算符不会重复添加，其他条件保持。
private struct SearchExifEditor: View {
    @Binding var conditions: [NativeSearchNumericCondition]
    @State private var field = NativeSearchNumericCondition.Field.iso
    @State private var comparison = NativeSearchNumericCondition.Comparison.atLeast
    @State private var value = 400.0

    var body: some View {
        VStack {
            Picker("EXIF field", selection: $field) {
                ForEach(NativeSearchNumericCondition.Field.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Comparison", selection: $comparison) {
                ForEach(NativeSearchNumericCondition.Comparison.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Value", value: $value, format: .number)
            Button("Add or update condition") {
                let condition = NativeSearchNumericCondition(field: field, comparison: comparison, value: value)
                conditions.removeAll { $0.id == condition.id }
                conditions.append(condition)
            }
            .disabled(!value.isFinite || value < 0)
            ForEach(conditions) { condition in
                HStack {
                    Text("\(condition.field.title) \(condition.comparison.title) \(condition.value.formatted())")
                    Spacer()
                    Button("Remove") { conditions.removeAll { $0.id == condition.id } }
                }
            }
        }
    }
}

/// 文本输入始终可用；values存在时通过系统原生菜单选择候选。
private struct SearchChoiceField: View {
    let title: String
    @Binding var text: String
    let values: [String]?

    var body: some View {
        HStack {
            TextField(title, text: $text)
            if let values, !values.isEmpty {
                Menu {
                    ForEach(values, id: \.self) { value in Button(value) { text = value } }
                } label: {
                    Image(systemName: "list.bullet").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Choose \(title)")
            }
        }
    }
}

/// 可独立启停的日期边界；禁用时省略条件，启用时保留用户选定日历日。
private struct DateFilterRow: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        VStack {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil }))
            if date != nil {
                DatePicker(title, selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }
}
