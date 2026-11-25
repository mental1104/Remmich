import Foundation
import ImmichAPI
import OSLog
#if DEBUG
    import OpenAPIURLSession
#endif

/// 真实Immich读取适配器；持有当前账号/端点代际，拒绝把旧上下文响应发布给Feature。
actor ImmichTimelineRepository: TimelineReading, VideoReading, AssetDetailReading, AlbumReading, PartnerTimelinePolicyReading {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineRepository"
    )

    private struct AccountIdentity: Equatable {
        let server: URL
        let userID: String
    }

    private var session: AccountSession?
    private var identity: AccountIdentity?
    private var activeEndpoint: URL?
    private var client: ImmichClient?
    private var generation: UInt64 = 0
    private let transfers: LibraryTransferQueue?
    private let readLoader: ImmichQueuedReadTransport.Loader?
    private let peopleConfigurationFactory: (@Sendable () -> URLSessionConfiguration)?
    private var peopleMutations: PeopleMutationClient?
    private var collectionStore: SQLiteLibraryIndexStore?
    private var collectionReads: [TimelineQuery: LibraryOpeningBuckets] = [:]
    private var collectionRequests: [String: Task<any Sendable, Error>] = [:]

    /// transfers为原持久读取队列；readLoader仅替换HTTP字节来源，仍经过SDK只读策略、认证和本层代际检查。
    /// peopleConfigurationFactory仅为人物专用前台会话提供隔离配置；生产nil沿用标准禁缓存/重定向规则。
    /// 不在生产构造点注入替身，也不改变搜索POST的受限前台传输。
    init(transfers: LibraryTransferQueue? = nil, readLoader: ImmichQueuedReadTransport.Loader? = nil,
         peopleConfigurationFactory: (@Sendable () -> URLSessionConfiguration)? = nil)
    {
        self.transfers = transfers
        self.readLoader = readLoader
        self.peopleConfigurationFactory = peopleConfigurationFactory
    }

    @discardableResult
    func configure(session: AccountSession, activeEndpoint: URL?, collectionStore: SQLiteLibraryIndexStore? = nil) -> Bool {
        if let collectionStore {
            self.collectionStore = collectionStore
        }
        let nextIdentity = AccountIdentity(server: session.apiURL, userID: session.userID)
        let credentialChanged = self.session?.accessToken != session.accessToken
        if identity != nextIdentity || credentialChanged {
            peopleMutations?.cancel()
            peopleMutations = nil
            generation &+= 1
            cancelCollectionRequests()
            identity = nextIdentity
            client = nil
            self.activeEndpoint = nil
        }
        self.session = session
        return updateRoute(activeEndpoint)
    }

    #if DEBUG
        /// 仅隔离UI宿主使用；session为合成账号、networkSession必须全拦截请求，装配过程不发网络请求。
        /// 原repo身份/代际与SDK鉴权、编码、只读策略保持生效，发布构建不包含此方法。
        func configureSearchUITest(session: AccountSession, networkSession: URLSession) {
            configure(session: session, activeEndpoint: session.apiURL)
            client = ImmichClient(apiURL: session.apiURL, credential: .bearer(session.accessToken),
                                  transport: URLSessionTransport(configuration: .init(session: networkSession)))
        }
    #endif

    @discardableResult
    func updateRoute(_ endpoint: URL?) -> Bool {
        guard activeEndpoint != endpoint else { return false }
        peopleMutations?.cancel()
        peopleMutations = nil
        generation &+= 1
        cancelCollectionRequests()
        activeEndpoint = endpoint
        guard let endpoint, let session else {
            client = nil
            return true
        }
        if let readLoader {
            client = ImmichClient(apiURL: endpoint, credential: .bearer(session.accessToken),
                                  transport: ImmichQueuedReadTransport(loader: readLoader))
        } else if let transfers {
            let owner = LibraryTransferOwner(session: session, endpoint: endpoint)
            client = ImmichClient(apiURL: endpoint, credential: .bearer(session.accessToken),
                                  transport: ImmichQueuedReadTransport { request, operation in
                                      let isAlbum = operation == "getAllAlbums" || operation == "getAlbumInfo"
                                          || request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.contains(where: { $0.name == "albumId" }) == true
                                      let kind: LibraryTransferKind = isAlbum ? .albumIndex : operation == "getAssetInfo" ? .metadata : .index
                                      let value = try await transfers.data(for: request, kind: kind, owner: owner)
                                      return (value.data, value.response)
                                  })
        } else {
            client = ImmichClient(apiURL: endpoint, credential: .bearer(session.accessToken))
        }
        return true
    }

    func clear() {
        peopleMutations?.cancel()
        peopleMutations = nil
        generation &+= 1
        cancelCollectionRequests()
        collectionReads.removeAll()
        session = nil
        identity = nil
        activeEndpoint = nil
        client = nil
    }

    private func cancelCollectionRequests() {
        for task in collectionRequests.values {
            task.cancel()
        }
        collectionRequests.removeAll()
    }

    func collectionNetworkReader(for query: TimelineQuery) -> LibraryOpeningBuckets {
        if let reader = collectionReads[query] {
            return reader
        }
        let reader = LibraryOpeningBuckets(source: self, query: query, readsCatalog: false)
        collectionReads[query] = reader
        return reader
    }

    func libraryPlaceCovers(offset: Int, limit: Int) async throws -> LibraryIndexedPlaces? {
        guard let collectionStore, let session else { return nil }
        let owner = generation
        let saved = try await collectionStore.collectionPlaceCovers(scope: .init(session: session), offset: offset, limit: limit)
        try requireCurrent(owner)
        return saved
    }

    func requireCollectionAccount(_ scope: MediaAccountScope) throws {
        guard let session, MediaAccountScope(session: session) == scope else { throw TimelineReadError.staleGeneration }
        _ = try requestContext()
    }

    func collectionSummaries(query: TimelineQuery, refresh: Bool) async throws -> [TimelineBucketSummary] {
        let indexedKey = LibraryIndexCard.timelineKey(for: query)
        guard let key = indexedKey ?? LibraryIndexCard.drillDownKey(for: query) else {
            return try await bucketSummaries(query: query)
        }
        let owner = generation
        let scope = session.map { MediaAccountScope(session: $0) }
        let saved: LibraryTimelineCatalog? = if let collectionStore, let scope {
            try? await collectionStore.collectionTimeline(key, scope: scope)
        } else {
            nil
        }
        try requireCurrent(owner)
        if let saved, (indexedKey != nil && !refresh) || activeEndpoint == nil {
            return saved.summaries
        }
        if indexedKey != nil {
            return try await collectionNetworkReader(for: query).bucketSummaries(query: query)
        }
        let fresh = try await collectionNetworkValue("summary:\(key)") { try await self.bucketSummaries(query: query) }
        if let collectionStore, let scope {
            let removed = Set(saved?.summaries.map(\.id) ?? []).subtracting(fresh.map(\.id))
            try? await collectionStore.saveCollectionTimeline(.init(summaries: fresh, olderCursor: 0), key: key,
                                                              scope: scope, replacing: [:], removing: removed)
            try requireCurrent(owner)
        }
        return fresh
    }

    func collectionBucket(_ bucket: TimelineBucketID, query: TimelineQuery, refresh: Bool) async throws -> [TimelineAssetSummary] {
        let indexedKey = LibraryIndexCard.timelineKey(for: query)
        guard let key = indexedKey ?? LibraryIndexCard.drillDownKey(for: query) else {
            return try await assets(in: bucket, query: query)
        }
        let owner = generation
        let scope = session.map { MediaAccountScope(session: $0) }
        if let collectionStore, let scope, (indexedKey != nil && !refresh) || activeEndpoint == nil,
           let saved = try? await collectionStore.collectionAssets(key, bucket: bucket, scope: scope)
        {
            try requireCurrent(owner)
            return saved
        }
        try requireCurrent(owner)
        if indexedKey != nil {
            return try await collectionNetworkReader(for: query).assets(in: bucket, query: query)
        }
        let fresh = try await collectionNetworkValue("bucket:\(key):\(bucket.rawValue)") {
            try await self.assets(in: bucket, query: query)
        }
        if let collectionStore, let scope {
            try? await collectionStore.saveCollectionMonth(fresh, key: key, bucket: bucket, scope: scope)
            try requireCurrent(owner)
        }
        return fresh
    }

    private func collectionValue<Value: Codable & Sendable>(_ key: String, refresh: Bool,
                                                            fetch: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        let owner = generation
        if !refresh || activeEndpoint == nil, let saved = try await indexedLibraryValue(Value.self, key: key) {
            return saved
        }
        try requireCurrent(owner)
        return try await collectionNetworkValue(key, fetch: fetch)
    }

    func indexedLibraryValue<Value: Decodable & Sendable>(_ type: Value.Type, key: String) async throws -> Value? {
        guard let collectionStore, let session else { return nil }
        let owner = generation
        let saved = try? await collectionStore.collectionPayload(type, key: key, scope: .init(session: session))
        try Task.checkCancellation()
        try requireCurrent(owner)
        return saved
    }

    private func collectionNetworkValue<Value: Sendable>(_ key: String,
                                                         fetch: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        let owner = generation
        let task: Task<any Sendable, Error>
        if let running = collectionRequests[key] {
            task = running
        } else {
            task = Task { try await fetch() }
            collectionRequests[key] = task
        }
        defer {
            if collectionRequests[key] == task {
                collectionRequests[key] = nil
            }
        }
        let result = try await task.value
        try Task.checkCancellation()
        try requireCurrent(owner)
        guard let value = result as? Value else { throw TimelineReadError.invalidResponse }
        return value
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        do {
            let buckets = try await client.timelineBuckets(query: Self.map(query))
            try requireCurrent(requestGeneration)
            return buckets.map {
                TimelineBucketSummary(
                    id: .init(rawValue: $0.id),
                    assetCount: $0.assetCount
                )
            }
        } catch {
            Self.logger.error(
                "Bucket summaries failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func assets(
        in bucketID: TimelineBucketID,
        query: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        do {
            let assets = try await client.timelineAssets(
                in: bucketID.rawValue,
                query: Self.map(query)
            )
            try requireCurrent(requestGeneration)
            return assets.map(Self.map)
        } catch {
            Self.logger.error(
                "Bucket assets failed generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        try await loadMemories(matching: nil)
    }

    func memories(matching kind: TimelineMediaKind) async throws -> [TimelineMemorySummary] {
        try await loadMemories(matching: kind)
    }

    func libraryPeople(refresh: Bool = false) async throws -> [LibraryPerson] {
        try await collectionValue(LibraryIndexCard.people.rawValue, refresh: refresh) { try await self.fetchLibraryPeople() }
    }

    private func fetchLibraryPeople() async throws -> [LibraryPerson] {
        let (client, requestGeneration) = try requestContext()
        var people: [String: LibraryPerson] = [:]
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await client.people(page: page, size: 250)
            try requireCurrent(requestGeneration)
            let before = people.count
            for person in result.people {
                people[person.id] = LibraryPerson(id: person.id, name: person.name, updatedAt: person.updatedAt ?? .distantPast)
            }
            guard result.hasNextPage else { break }
            guard people.count > before else { throw TimelineReadError.invalidResponse }
            page += 1
        }
        return people.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    /// 管理页按官方分页全量读取含隐藏人物；绕过已完成GET/collection缓存，成功后更新同账号浏览摘要。
    func managementPeople() async throws -> [ManagedPerson] {
        let (_, owner) = try requestContext()
        let client = try managementClient(owner: owner)
        do {
            var people: [String: ManagedPerson] = [:]
            var page = 1
            while true {
                let result = try await client.managementPeople(page: page, size: 250)
                try requirePeopleOwner(owner)
                let before = people.count
                for person in result.people {
                    guard let id = UUID(uuidString: person.id) else { throw TimelineReadError.invalidResponse }
                    people[id.uuidString.lowercased()] = .init(id: id.uuidString.lowercased(), name: person.name,
                                                               isHidden: person.isHidden, updatedAt: person.updatedAt)
                }
                guard result.hasNextPage else { break }
                guard people.count > before, page < Int.max else { throw TimelineReadError.invalidResponse }
                page += 1
            }
            let fresh = people.values.sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            if let collectionStore, let session {
                let visible = fresh.filter { !$0.isHidden }.map { LibraryPerson(id: $0.id, name: $0.name, updatedAt: $0.updatedAt ?? .distantPast) }
                try await collectionStore.saveCollectionPayload(visible, key: LibraryIndexCard.people.rawValue, scope: .init(session: session))
                try requirePeopleOwner(owner)
            }
            return fresh
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    /// expected来自用户确认的fresh记录；预检成功后只改本人姓名，任何await后都重新核对原代际。
    func renamePerson(_ expected: ManagedPerson, name: String) async throws {
        let (client, owner) = try peopleMutationContext()
        do {
            let fresh = try await client.person(expected.id)
            try requirePeopleOwner(owner)
            guard expected.matchesEditableFields(fresh) else { throw PeopleManagementError.changedPerson }
            try await client.rename(expected.id, name: name)
            try requirePeopleOwner(owner)
        } catch { try requireCurrent(owner); throw Self.map(error) }
    }

    /// 隐藏仅更新本人显示设置；预检发现卡片过时就停止，不盲目覆盖另一操作的结果。
    func setPersonHidden(_ expected: ManagedPerson, hidden: Bool) async throws {
        let (client, owner) = try peopleMutationContext()
        do {
            let fresh = try await client.person(expected.id)
            try requirePeopleOwner(owner)
            guard expected.matchesEditableFields(fresh) else { throw PeopleManagementError.changedPerson }
            try await client.setHidden(expected.id, hidden: hidden)
            try requirePeopleOwner(owner)
        } catch { try requireCurrent(owner); throw Self.map(error) }
    }

    /// target/source均重新读取确认后才发送一次有向合并；部分或未知响应保留失败，不自动重放POST。
    func mergePeople(target: ManagedPerson, source: ManagedPerson) async throws {
        guard target.id.lowercased() != source.id.lowercased() else { throw LibraryWriteError.invalidID }
        let (client, owner) = try peopleMutationContext()
        do {
            async let freshTarget = client.person(target.id)
            async let freshSource = client.person(source.id)
            let (first, second) = try await (freshTarget, freshSource)
            try requirePeopleOwner(owner)
            guard target.matchesEditableFields(first), source.matchesEditableFields(second) else { throw PeopleManagementError.changedPerson }
            try await client.merge(targetID: target.id, sourceID: source.id)
            try requirePeopleOwner(owner)
        } catch { try requireCurrent(owner); throw Self.map(error) }
    }

    /// 专用人物会话复用当前已认证身份；只由原仓库持有，并在configure/route/clear中撤销。
    private func peopleMutationContext() throws -> (PeopleMutationClient, UInt64) {
        let (_, owner) = try requestContext()
        try requirePeopleOwner(owner)
        if let peopleMutations {
            return (peopleMutations, owner)
        }
        guard let activeEndpoint, let session else { throw TimelineReadError.routeUnavailable }
        let client = PeopleMutationClient(apiURL: activeEndpoint, token: session.accessToken, userID: session.userID,
                                          configuration: peopleConfigurationFactory?() ?? .ephemeral)
        peopleMutations = client
        return (client, owner)
    }

    /// 前后台读取与人物写入都使用同一原repo代际；取消不能因为已解码回执而变成成功。
    private func requirePeopleOwner(_ owner: UInt64) throws {
        try Task.checkCancellation()
        try requireCurrent(owner)
    }

    func libraryMemories(page: Int, size: Int, includeTimelineAssets: Bool = true, refresh: Bool = false) async throws -> [TimelineMemorySummary] {
        let owner = generation
        let key = includeTimelineAssets ? LibraryIndexCard.memories.rawValue : "memoryCovers"
        if let collectionStore, let session, !refresh || activeEndpoint == nil,
           let saved = try? await collectionStore.collectionPayload([TimelineMemorySummary].self, key: key, scope: .init(session: session))
        {
            try requireCurrent(owner)
            return Array(saved.dropFirst((page - 1) * size).prefix(size))
        }
        try requireCurrent(owner)
        return try await collectionNetworkValue("memories-\(page)-\(size)-\(includeTimelineAssets)") {
            try await self.fetchLibraryMemories(page: page, size: size, includeTimelineAssets: includeTimelineAssets)
        }
    }

    private func fetchLibraryMemories(page: Int, size: Int, includeTimelineAssets: Bool) async throws -> [TimelineMemorySummary] {
        let (client, requestGeneration) = try requestContext()
        let values = try await client.memories(query: .init(page: page, size: size), includeTimelineAssets: includeTimelineAssets)
        try requireCurrent(requestGeneration)
        return values.map { memory in
            TimelineMemorySummary(id: memory.id, memoryAt: memory.memoryAt, sourceYear: memory.year,
                                  assets: memory.assets.map { .init(id: $0.id, revision: $0.updatedAt, mediaKind: Self.map($0.mediaKind)) },
                                  availableOn: memory.showAt, timelineAssets: memory.timelineAssets?.map(Self.map))
        }
    }

    func librarySharedLinks(refresh: Bool = false) async throws -> [LibrarySharedLink] {
        try await collectionValue(LibraryIndexCard.sharedLinks.rawValue, refresh: refresh) { try await self.fetchLibrarySharedLinks() }
    }

    private func fetchLibrarySharedLinks() async throws -> [LibrarySharedLink] {
        let (client, requestGeneration) = try requestContext()
        guard let serverURL = session?.apiURL else { throw TimelineReadError.routeUnavailable }
        let links = try await client.sharedLinks(serverURL: serverURL)
        try requireCurrent(requestGeneration)
        return links.map {
            LibrarySharedLink(id: $0.id, name: $0.description, createdAt: $0.createdAt, expiresAt: $0.expiresAt,
                              isPasswordProtected: $0.isPasswordProtected, publicURL: $0.publicURL,
                              album: $0.album.map(Self.map), assets: $0.assets.map(Self.map))
        }
        .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }

    func libraryPartners(refresh: Bool = false) async throws -> [LibraryPartner] {
        try await collectionValue(LibraryIndexCard.partners.rawValue, refresh: refresh) { try await self.fetchLibraryPartners() }
    }

    private func fetchLibraryPartners() async throws -> [LibraryPartner] {
        let (client, requestGeneration) = try requestContext()
        let partners = try await client.incomingPartners()
        try requireCurrent(requestGeneration)
        return partners.map {
            LibraryPartner(id: $0.id, name: $0.name, hasProfileImage: $0.hasProfileImage, profileChangedAt: $0.profileChangedAt)
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func libraryPreferences(refresh: Bool = false) async throws -> LibraryFeaturePreferences {
        try await collectionValue("preferences", refresh: refresh) { try await self.fetchLibraryPreferences() }
    }

    private func fetchLibraryPreferences() async throws -> LibraryFeaturePreferences {
        let (client, requestGeneration) = try requestContext()
        let preferences = try await client.libraryPreferences()
        try requireCurrent(requestGeneration)
        return LibraryFeaturePreferences(foldersEnabled: preferences.foldersEnabled,
                                         sharedLinksEnabled: preferences.sharedLinksEnabled,
                                         memoriesEnabled: preferences.memoriesEnabled,
                                         peopleEnabled: preferences.peopleEnabled)
    }

    func libraryFolderTree(refresh: Bool = false) async throws -> LibraryFolderTree {
        try await collectionValue(LibraryIndexCard.folders.rawValue, refresh: refresh) { try await self.fetchLibraryFolderTree() }
    }

    private func fetchLibraryFolderTree() async throws -> LibraryFolderTree {
        let (client, requestGeneration) = try requestContext()
        let paths = try await client.folderPaths()
        try requireCurrent(requestGeneration)
        return LibraryFolderTree(paths: paths)
    }

    func libraryFolderAssets(path: String, refresh: Bool = false) async throws -> [TimelineAssetSummary] {
        let key = "folder:\(path)"
        let owner = generation
        let bucket = TimelineBucketID(rawValue: "")
        let scope = session.map { MediaAccountScope(session: $0) }
        if let collectionStore, let scope, !refresh || activeEndpoint == nil,
           let saved = try? await collectionStore.collectionAssets(key, bucket: bucket, scope: scope)
        {
            try requireCurrent(owner)
            return saved
        }
        try requireCurrent(owner)
        let value = try await collectionNetworkValue(key) { try await self.fetchLibraryFolderAssets(path: path) }
        if let collectionStore, let scope {
            try? await collectionStore.saveCollectionMonth(value, key: key, bucket: bucket, scope: scope)
            try requireCurrent(owner)
        }
        return value
    }

    private func fetchLibraryFolderAssets(path: String) async throws -> [TimelineAssetSummary] {
        let (client, requestGeneration) = try requestContext()
        let assets = try await client.folderAssets(path: path)
        try requireCurrent(requestGeneration)
        return assets.map(Self.map)
    }

    private func loadMemories(matching kind: TimelineMediaKind?) async throws -> [TimelineMemorySummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        do {
            let memories = try await MemoryDaySearch.load(relativeTo: startedAt, calendar: calendar) { day in
                try self.requireCurrent(requestGeneration)
                let queryDate = MemoryQueryDate.string(for: day, timeZone: calendar.timeZone)
                // Keep only the first twenty records for each candidate day.
                let loaded = try await client.memories(query: .init(date: queryDate))
                try self.requireCurrent(requestGeneration)
                let mapped = loaded.compactMap { memory -> TimelineMemorySummary? in
                    guard memory.kind == .onThisDay else { return nil }
                    return TimelineMemorySummary(
                        id: memory.id,
                        memoryAt: memory.memoryAt,
                        sourceYear: memory.year,
                        assets: memory.assets.map {
                            TimelineMemoryAssetSummary(id: $0.id, revision: $0.updatedAt, mediaKind: Self.map($0.mediaKind))
                        }
                    )
                }
                return kind.map { kind in mapped.compactMap { $0.filteringAssets(of: kind) } } ?? mapped
            }
            try requireCurrent(requestGeneration)
            return memories
        } catch {
            Self.logger.error(
                "Memories failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    /// query 为本次条件，continuation 为原始服务端令牌；返回当前代际的媒体结果，迟到响应拒绝发布。
    func search(_ query: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        let (client, owner) = try requestContext()
        // SDK类型仅存在于基础设施层；界面和领域不导入ImmichAPI。
        var dto = ImmichMetadataSearch()
        dto.text = query.text
        dto.queryAssetID = query.queryAssetID
        dto.mode = switch query.mode {
        case .fileName: .fileName
        case .description: .description
        case .fullPath: .fullPath
        case .ocr: .ocr
        case .smart: .smart
        }
        dto.media = switch query.media { case .all: .all; case .image: .image; case .video: .video }
        dto.city = query.city
        dto.country = query.country
        dto.state = query.state
        dto.favoritesOnly = query.favoritesOnly
        dto.archivedOnly = query.archivedOnly
        dto.rating = switch query.rating { case .any: .any; case .unrated: .unrated; case let .stars(value): .stars(value) }
        dto.cameraMake = query.cameraMake
        dto.cameraModel = query.cameraModel
        dto.deviceModels = query.deviceModels
        dto.lensModel = query.lensModel
        dto.tags = switch query.tags { case .any: .any; case .untagged: .untagged; case let .anyOf(ids): .anyOf(ids) }
        dto.orientation = query.orientation.map { $0 == .landscape ? .landscape : .portrait }
        dto.mediaCategory = try query.mediaCategory.map { category in
            guard let mapped = ImmichSearchMediaCategory(rawValue: category.rawValue) else { throw NativeSearchError.invalidQuery }
            return mapped
        }
        dto.resolution = try query.resolution.map { resolution in
            guard let mapped = ImmichSearchResolution(rawValue: resolution.rawValue) else { throw NativeSearchError.invalidQuery }
            return mapped
        }
        dto.panoramasOnly = query.panoramasOnly
        dto.hasAlbums = query.hasAlbums
        dto.exifConditions = try query.exifConditions.map { condition in
            guard let field = ImmichSearchNumericCondition.Field(rawValue: condition.field.rawValue),
                  let comparison = ImmichSearchNumericCondition.Comparison(rawValue: condition.comparison.rawValue)
            else { throw NativeSearchError.invalidQuery }
            return .init(field: field, comparison: comparison, value: condition.value)
        }
        dto.personIDs = query.personIDs
        dto.takenAfter = query.takenAfter
        dto.takenBefore = query.takenBefore
        dto.timeZone = query.timeZone
        let token: ImmichSearchContinuation? = switch continuation {
        case let .cursor(value)?: .cursor(value)
        case let .page(value)?: .page(value)
        case let .forkCursor(value)?: .forkCursor(value)
        case nil: nil
        }
        do {
            let page = try await client.search(dto, continuation: token)
            try Task.checkCancellation()
            try requireCurrent(owner)
            let next: NativeSearchContinuation? = switch page.continuation {
            case let .cursor(value)?: .cursor(value)
            case let .page(value)?: .page(value)
            case let .forkCursor(value)?: .forkCursor(value)
            case nil: nil
            }
            return NativeSearchPage(assets: page.assets.map(Self.map), continuation: next)
        } catch {
            try requireCurrent(owner)
            if Task.isCancelled || error is CancellationError || (error as? ImmichAPIError) == .cancelled {
                throw CancellationError()
            }
            if let api = error as? ImmichAPIError {
                if query.requiresForkSmartSearch, api == .notFound || api == .httpStatus(405) || api == .serverError(501) {
                    throw NativeSearchError.unsupportedExtension
                }
                switch api {
                case .unauthorized: throw NativeSearchError.unauthorized
                case .forbidden: throw NativeSearchError.forbidden
                case .httpStatus(400): throw NativeSearchError.invalidQuery
                case .invalidResponse: throw NativeSearchError.invalidResponse
                case .rateLimited: throw NativeSearchError.rateLimited
                default: throw NativeSearchError.unavailable
                }
            }
            throw NativeSearchError.unavailable
        }
    }

    /// 当前账号标签候选不写入持久索引；身份/端点变化后的迟到响应必须丢弃。
    func searchTags() async throws -> [NativeSearchTag] {
        let (client, owner) = try requestContext()
        let values = try await client.searchTags()
        try Task.checkCancellation()
        try requireCurrent(owner)
        return values.map { NativeSearchTag(id: $0.id, value: $0.value) }
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    /// kind指定候选字段，query提供厂商/型号约束；拒绝账号/路由变化后的迟到响应。
    func searchSuggestions(_ kind: NativeSearchSuggestionKind, query: NativeSearchQuery) async throws -> [String] {
        let (client, owner) = try requestContext()
        guard let field = ImmichSearchSuggestionKind(rawValue: kind.rawValue) else { throw NativeSearchError.invalidQuery }
        let values = try await client.searchSuggestions(kind: field, make: query.cameraMake.isEmpty ? nil : query.cameraMake,
                                                        model: query.cameraModel.isEmpty ? nil : query.cameraModel)
        try Task.checkCancellation()
        try requireCurrent(owner)
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func videos(cursor: String?) async throws -> VideoPage {
        let (client, requestGeneration) = try requestContext()
        do {
            let page = try await client.videoAssets(cursor: cursor)
            try requireCurrent(requestGeneration)
            return VideoPage(
                assets: page.assets.map {
                    TimelineAssetSummary(
                        id: $0.id,
                        ownerID: $0.ownerID,
                        capturedAt: $0.capturedAt,
                        uploadedAt: $0.uploadedAt,
                        localOffsetHours: $0.localOffsetHours,
                        mediaKind: .video,
                        durationMilliseconds: $0.durationMilliseconds,
                        aspectRatio: $0.aspectRatio,
                        isFavorite: $0.isFavorite,
                        visibility: .timeline,
                        livePhotoVideoID: nil,
                        stack: nil,
                        projectionType: nil,
                        thumbhash: $0.thumbhash,
                        thumbnailRevision: $0.thumbnailRevision
                    )
                },
                nextCursor: page.nextCursor
            )
        } catch {
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        let (client, requestGeneration) = try requestContext()
        do {
            let detail = try await client.assetInfo(id: id)
            try requireCurrent(requestGeneration)
            return AssetDetail(
                id: detail.id,
                capturedAt: detail.capturedAt,
                originalFileName: detail.originalFileName,
                originalMimeType: detail.originalMimeType,
                width: detail.width,
                height: detail.height,
                description: detail.description,
                cameraMake: detail.cameraMake,
                cameraModel: detail.cameraModel,
                lensModel: detail.lensModel,
                fileSizeBytes: detail.fileSizeBytes,
                iso: detail.iso,
                focalLength: detail.focalLength,
                aperture: detail.aperture,
                exposureTime: detail.exposureTime,
                latitude: detail.latitude,
                longitude: detail.longitude,
                city: detail.city,
                state: detail.state,
                country: detail.country
            )
        } catch {
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    /// 当前账号读取一批服务器随机照片；无分页位置，迟到响应在账号/端点变更后拒绝发布。
    func randomPhotos() async throws -> [TimelineAssetSummary] {
        let (client, owner) = try requestContext()
        do {
            let values = try await client.randomPhotos(size: 60)
            try Task.checkCancellation()
            try requireCurrent(owner)
            return values.map(Self.map)
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    /// 本人待整理使用真实前台相簿列表与Fork目录，不复用索引已完成GET；ownerID来自当前界面会话。
    /// 缺扩展返回nil，错误原样抛出，两条读取都必须仍属于同一原repo代际。
    func pendingAlbums(ownerID: String) async throws -> [AlbumSummary]? {
        let (_, owner) = try requestContext()
        let client = try managementClient(owner: owner)
        do {
            async let values = client.albums()
            async let directory = forkAlbumDirectory()
            let (albums, groups) = try await (values, directory)
            try Task.checkCancellation()
            try requireCurrent(owner)
            guard let groups else { return nil }
            return PendingAlbumSelection.select(albums.map(Self.map), directory: groups, ownerID: ownerID)
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    /// 为当前管理动作创建绑定原仓库代际的前台读取器；它不复制会话生命周期，也不走索引GET缓存。
    func managementTimelineReader() async throws -> any TimelineReading {
        let (_, owner) = try requestContext()
        try Task.checkCancellation()
        return ManagementTimelineReader(repository: self, owner: owner)
    }

    /// 同步前后直接读取当前incoming伙伴策略，绕过索引GET；后台同样依赖原repo会话而不是尚未配置的Media管理器。
    /// scope限定原账号；readLoader沿用既有隔离HTTP字节边界，真实生产使用禁止重定向/缓存的受限客户端。
    func partnerTimelinePolicy(scope: MediaAccountScope) async throws -> PartnerTimelinePolicy {
        let (_, owner) = try requestContext()
        guard let session, let activeEndpoint, MediaAccountScope(session: session) == scope else { throw CancellationError() }
        let incoming: [ManagedPartner]
        do {
            if let readLoader {
                var components = URLComponents(url: activeEndpoint.appending(path: "partners"), resolvingAgainstBaseURL: false)
                components?.queryItems = [.init(name: "direction", value: "shared-with")]
                guard let url = components?.url else { throw TimelineReadError.invalidResponse }
                var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData; request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await readLoader(request, "getPartners")
                guard response.statusCode == 200, response.url == url else { throw TimelineReadError.invalidResponse }
                incoming = try JSONDecoder().decode([ManagedPartner].self, from: data)
            } else {
                let client = LibraryMutationClient(apiURL: activeEndpoint, token: session.accessToken, userID: session.userID)
                defer { client.cancel() }
                incoming = try await client.partnerSharing(.incoming)
            }
            try Task.checkCancellation(); try requireCurrent(owner)
            return try .init(scope: scope, incoming: incoming)
        } catch { try requireCurrent(owner); throw error }
    }

    /// 旧policy的持久GET不能在新证书accept后的冷恢复中复活；仅复用原index lane退役，媒体/导出和相簿不动。
    func retirePartnerTimelineIndexReads(scope: MediaAccountScope) async throws {
        let (_, owner) = try requestContext()
        guard let session, MediaAccountScope(session: session) == scope else { throw CancellationError() }
        try Task.checkCancellation()
        try await transfers?.retirePartnerTimelineIndexPass(namespace: scope.cacheNamespace)
        try Task.checkCancellation(); try requireCurrent(owner)
    }

    /// 每次读取先验证原代际，随后使用同一真实凭据的前台通道；测试loader也不经过持久队列。
    private func managementClient(owner: UInt64) throws -> ImmichClient {
        try Task.checkCancellation()
        try requireCurrent(owner)
        guard let activeEndpoint, let session else { throw TimelineReadError.routeUnavailable }
        if let readLoader {
            return ImmichClient(apiURL: activeEndpoint, credential: .bearer(session.accessToken),
                                transport: ImmichQueuedReadTransport(loader: readLoader))
        }
        return ImmichClient.foregroundReadClient(apiURL: activeEndpoint, credential: .bearer(session.accessToken))
    }

    /// query为管理需要的准确相簿范围；owner固定创建时原repo代际，返回本次实际HTTP桶列表。
    private func managementBuckets(query: TimelineQuery, owner: UInt64) async throws -> [TimelineBucketSummary] {
        let client = try managementClient(owner: owner)
        do {
            let values = try await client.timelineBuckets(query: Self.map(query))
            try Task.checkCancellation()
            try requireCurrent(owner)
            return values.map { .init(id: .init(rawValue: $0.id), assetCount: $0.assetCount) }
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    /// bucket/query决定本次真实前台GET；owner使旧读取器在换账号或端点后失效，响应也必须再次检查。
    private func managementAssets(bucket: TimelineBucketID, query: TimelineQuery, owner: UInt64) async throws -> [TimelineAssetSummary] {
        let client = try managementClient(owner: owner)
        do {
            let values = try await client.timelineAssets(in: bucket.rawValue, query: Self.map(query))
            try Task.checkCancellation()
            try requireCurrent(owner)
            return values.map(Self.map)
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    /// 管理相簿不产生全局回忆，沿用AlbumTimelineReader的空回忆语义；空结果同样受原代际和取消保护。
    private func managementMemories(owner: UInt64) throws -> [TimelineMemorySummary] {
        try Task.checkCancellation()
        try requireCurrent(owner)
        return []
    }

    /// 只保留原repo与固定发布代际；所有网络读取回到原actor验证，不能脱离原生命周期继续读取旧账户。
    private nonisolated struct ManagementTimelineReader: TimelineReading {
        let repository: ImmichTimelineRepository
        let owner: UInt64

        /// query原样交给原仓库前台读取，返回当前响应而非共享collection缓存。
        func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
            try await repository.managementBuckets(query: query, owner: owner)
        }

        /// bucketID/query定义管理成员读取范围，owner检查覆盖请求前后。
        func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
            try await repository.managementAssets(bucket: bucketID, query: query, owner: owner)
        }

        /// 管理相簿不返回回忆；仍通过原repo拒绝失效代际与取消任务。
        func memories() async throws -> [TimelineMemorySummary] {
            try await repository.managementMemories(owner: owner)
        }
    }

    /// 写入后的相簿列表必须绕过已完成索引GET；每次响应前后仍核对原仓库账号/端点代际。
    func foregroundAlbums() async throws -> [AlbumSummary] {
        let (_, owner) = try requestContext()
        let client = try managementClient(owner: owner)
        do {
            let values = try await client.albums()
            try Task.checkCancellation()
            try requireCurrent(owner)
            return values.map(Self.map)
        } catch {
            try requireCurrent(owner)
            throw Self.map(error)
        }
    }

    func albums() async throws -> [AlbumSummary] {
        let (client, requestGeneration) = try requestContext()
        let albums = try await client.albums()
        try requireCurrent(requestGeneration)
        Self.logger.info("Albums loaded generation=\(requestGeneration) count=\(albums.count)")
        return albums.map(Self.map)
    }

    func forkAlbumDirectory() async throws -> ForkAlbumDirectory? {
        let (_, requestGeneration) = try requestContext()
        guard let session, let activeEndpoint else { throw TimelineReadError.routeUnavailable }
        let result = try await ForkServerReader(apiURL: activeEndpoint, token: session.accessToken).albumDirectory()
        try requireCurrent(requestGeneration)
        return result
    }

    func album(id: String) async throws -> AlbumSummary {
        let (client, requestGeneration) = try requestContext()
        let album = try await client.album(id: id)
        try requireCurrent(requestGeneration)
        Self.logger.info("Album detail loaded generation=\(requestGeneration) items=\(album.assetCount)")
        return Self.map(album)
    }

    private static func map(_ album: ImmichAlbum) -> AlbumSummary {
        .init(id: album.id, name: album.name, description: album.description,
              thumbnailAssetID: album.thumbnailAssetID, assetCount: album.assetCount,
              updatedAt: album.updatedAt, createdAt: album.createdAt,
              startDate: album.startDate, endDate: album.endDate, isShared: album.isShared,
              lastModifiedAssetTimestamp: album.lastModifiedAssetTimestamp,
              ownerName: album.ownerName, ownerID: album.ownerID)
    }

    private func requestContext() throws -> (ImmichClient, UInt64) {
        guard let client, activeEndpoint != nil else {
            throw TimelineReadError.routeUnavailable
        }
        return (client, generation)
    }

    func timelineReadGeneration() throws -> UInt64 {
        try requestContext().1
    }

    private func requireCurrent(_ requestGeneration: UInt64) throws {
        guard requestGeneration == generation else {
            throw TimelineReadError.staleGeneration
        }
    }

    private static func map(_ query: TimelineQuery) -> ImmichTimelineQuery {
        ImmichTimelineQuery(
            order: query.order == .ascending ? .ascending : .descending,
            orderBy: query.orderBy == .takenAt ? .takenAt : .createdAt,
            visibility: query.visibility.map(map),
            includesTrashed: query.includesTrashed,
            includesStacks: query.includesStacks,
            includesPartners: query.includesPartners,
            albumID: query.albumID,
            isFavorite: query.isFavorite,
            personID: query.personID,
            userID: query.userID
        )
    }

    private static func map(_ visibility: TimelineVisibility) -> ImmichAssetVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case let .unknown(value): .unknown(value)
        }
    }

    private static func map(_ visibility: ImmichAssetVisibility) -> TimelineVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case let .unknown(value): .unknown(value)
        }
    }

    private static func map(_ mediaKind: ImmichTimelineMediaKind) -> TimelineMediaKind {
        switch mediaKind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .other: .other
        }
    }

    private static func map(_ asset: ImmichTimelineAsset) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: asset.id,
            ownerID: asset.ownerID,
            capturedAt: asset.fileCreatedAt,
            uploadedAt: asset.createdAt,
            localOffsetHours: asset.localOffsetHours,
            mediaKind: map(asset.mediaKind),
            durationMilliseconds: asset.durationMilliseconds,
            aspectRatio: asset.aspectRatio,
            isFavorite: asset.isFavorite,
            visibility: map(asset.visibility),
            livePhotoVideoID: asset.livePhotoVideoID,
            stack: asset.stack.map { .init(id: $0.id, assetCount: $0.assetCount) },
            projectionType: asset.projectionType,
            thumbhash: asset.thumbhash,
            thumbnailRevision: asset.thumbnailRevision,
            place: TimelinePlace(city: asset.city, country: asset.country)
        )
    }

    private static func map(_ error: Error) -> Error {
        if let error = error as? ImmichAPIError, error == .cancelled {
            return CancellationError()
        }
        if let error = error as? TimelineReadError {
            return error
        }
        if let error = error as? ImmichAPIError, error == .invalidResponse {
            return TimelineReadError.invalidResponse
        }
        return error
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private nonisolated static func elapsedMilliseconds(since start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }

    private nonisolated static func errorSummary(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return "\(String(reflecting: type(of: error))): \(description)"
        }
        return String(reflecting: type(of: error))
    }
}
