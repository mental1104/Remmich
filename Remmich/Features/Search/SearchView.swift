import SwiftUI

/// 真实搜索页，复用原生缩略图与查看器，不显示演示资源。
struct SearchView: View {
    let source: ImmichTimelineRepository?
    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let showAccount: () -> Void
    @State private var query = NativeSearchQuery()
    @State private var store = NativeSearchStore()
    @State private var selection: Selection?
    @State private var people: [LibraryPerson] = []
    @State private var peopleError: String?
    @State private var tagChoices: [NativeSearchTag] = []
    @State private var tagChoicesError: String?
    @State private var loadingTags = false
    @State private var suggestions: [NativeSearchSuggestionKind: [String]] = [:]
    @State private var suggestionError: String?
    @State private var loadingSuggestions = false
    @Namespace private var viewerNamespace

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
                SearchPresetsPanel(query: $query, manager: media.management).padding(.horizontal)
                DisclosureGroup("Filters") {
                    VStack {
                        Picker("Search mode", selection: $query.mode) {
                            ForEach(NativeSearchQuery.Mode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        SearchChoiceField(title: "Country", text: $query.country, values: suggestions[.country])
                        SearchChoiceField(title: "State or province", text: $query.state, values: suggestions[.state])
                        SearchChoiceField(title: "City", text: $query.city, values: suggestions[.city])
                        SearchChoiceField(title: "Camera make", text: $query.cameraMake, values: suggestions[.cameraMake])
                        SearchChoiceField(title: "Camera model", text: $query.cameraModel, values: suggestions[.cameraModel])
                        SearchChoiceField(title: "Lens model", text: $query.lensModel, values: suggestions[.cameraLensModel])
                        Toggle("Favorites only", isOn: $query.favoritesOnly)
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
                            Picker("Media category", selection: $query.mediaCategory) {
                                Text("Any").tag(nil as NativeSearchMediaCategory?)
                                ForEach(NativeSearchMediaCategory.allCases, id: \.self) { category in
                                    Text(category.title).tag(Optional(category))
                                }
                            }
                            Picker("Resolution", selection: $query.resolution) {
                                Text("Any").tag(nil as NativeSearchResolution?)
                                ForEach(NativeSearchResolution.allCases, id: \.self) { resolution in
                                    Text(resolution.rawValue.uppercased()).tag(Optional(resolution))
                                }
                            }
                            Toggle("Panoramas only", isOn: $query.panoramasOnly)
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
                        DisclosureGroup("Tags") {
                            Toggle("Without tags", isOn: Binding(get: { query.tags == .untagged }, set: { enabled in
                                if enabled {
                                    query.tags = .untagged
                                } else if query.tags == .untagged {
                                    query.tags = .any
                                }
                            }))
                            Text("Multiple selections match any selected tag or its children.").font(.caption)
                            if !query.tags.selectedIDs.isEmpty {
                                Text("Selected tags: \(query.tags.selectedIDs.count)").font(.caption)
                            }
                            Button("Clear tag filter") { query.tags = .any }
                                .disabled(query.tags == .any)
                            if let tagChoicesError {
                                Text(tagChoicesError).font(.caption)
                            }
                            if !tagChoices.isEmpty {
                                ScrollView {
                                    LazyVStack(alignment: .leading) {
                                        ForEach(tagChoices) { tag in
                                            Toggle(tag.value, isOn: Binding(get: { query.tags.contains(tag.id) }, set: { selected in
                                                query.tags.setSelected(tag.id, selected: selected)
                                            }))
                                            .disabled(!query.tags.contains(tag.id) && query.tags.selectedIDs.count >= 100)
                                        }
                                    }
                                }.frame(maxHeight: 240)
                            }
                            Button(loadingTags ? "Loading tags" : "Load tags") { Task { await loadTags() } }
                                .disabled(loadingTags)
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
                if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task {
                        if let source {
                            if store.hasSearched, store.continuation == nil {
                                await store.search(query, source: source)
                            } else {
                                await store.loadMore(source: source)
                            }
                        }
                    } }
                }
                if invalidDateRange {
                    Text("End date must not be earlier than start date.").foregroundStyle(.secondary)
                }
                if store.assets.isEmpty, !store.isLoading {
                    ContentUnavailableView(store.hasSearched ? "No results" : "Search your library",
                                           systemImage: "magnifyingglass",
                                           description: Text("Choose a search mode or metadata filters."))
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100, maximum: 180), spacing: 2)], spacing: 2) {
                    ForEach(store.assets) { asset in
                        Button { open(asset) } label: {
                            LibraryAssetCover(assetID: asset.id, revision: asset.thumbnailRevision, media: media)
                                .aspectRatio(1, contentMode: .fit).clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.mediaKind == .video ? "Open video" : "Open photo")
                    }
                }
                if store.isLoading {
                    ProgressView("Searching")
                }
                if store.continuation != nil, !store.isLoading {
                    Button("Load more") { Task {
                        if let source {
                            await store.loadMore(source: source)
                        }
                    } }
                }
                if !store.assets.isEmpty {
                    Text("Loaded \(store.assets.count) items").font(.caption)
                }
            }.padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.text, prompt: Text(query.mode.title))
        .toolbar { AccountToolbarButton(action: showAccount) }
        .task(id: query) { await search() }
        .onChange(of: media.management.generation) { _, _ in
            store.invalidate()
            selection = nil
            query = .init()
            people = []
            peopleError = nil
            tagChoices = []
            tagChoicesError = nil
            loadingTags = false
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
              || query.favoritesOnly || query.archivedOnly || query.rating != .any || query.tags != .any || query.orientation != nil || query.hasAlbums != nil || !query.exifConditions.isEmpty
              || query.mediaCategory != nil || query.resolution != nil || query.panoramasOnly else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard let source else { return }
            await store.search(query, source: source)
        } catch { /* 取消防抖无需显示错误。 */ }
    }

    /// 仅比较用户选择的日历日，不因DatePicker保留小时而误判同一天。
    private var invalidDateRange: Bool {
        guard let start = query.takenAfter, let end = query.takenBefore else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = query.timeZone
        return calendar.startOfDay(for: start) > calendar.startOfDay(for: end)
    }

    /// 加载当前账号官方标签，不清除所选条件；候选失败或跨账号迟到均不能变成另一账号的列表。
    private func loadTags() async {
        guard let source, !loadingTags else { return }
        let owner = media.management.generation
        loadingTags = true
        tagChoicesError = nil
        defer {
            if owner == media.management.generation {
                loadingTags = false
            }
        }
        do {
            let values = try await source.searchTags()
            try Task.checkCancellation()
            guard owner == media.management.generation else { return }
            tagChoices = values
        } catch {
            guard owner == media.management.generation, !Task.isCancelled else { return }
            tagChoicesError = "Tags could not be loaded. Check permissions and connection. Your filter has been kept."
        }
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
