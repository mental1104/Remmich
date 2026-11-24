import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import OSLog

public actor ImmichClient {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "ImmichAPI"
    )
    private nonisolated static let dateTranscoder = ImmichDateTranscoder()

    private struct RouteIdentity: Decodable {
        let id: String
    }

    public let apiURL: URL
    private var credential: ImmichCredential?
    private let transport: any ClientTransport
    private let routeCheckSession: URLSession?

    public init(
        apiURL: URL,
        credential: ImmichCredential? = nil,
        transport: (any ClientTransport)? = nil
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport ?? ImmichNetworkSession.transport
        routeCheckSession = nil
    }

    private init(
        apiURL: URL,
        credential: ImmichCredential?,
        transport: any ClientTransport,
        routeCheckSession: URLSession
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport
        self.routeCheckSession = routeCheckSession
    }

    /// A client for background route-health checks. Uses a short (~5s) request timeout so a
    /// stuck candidate fails fast instead of riding the longer timeout used for interactive
    /// login/browsing traffic on `shared`.
    public static func routeCheckClient(apiURL: URL, credential: ImmichCredential?) -> ImmichClient {
        ImmichClient(
            apiURL: apiURL,
            credential: credential,
            transport: ImmichNetworkSession.routeCheckTransport,
            routeCheckSession: ImmichNetworkSession.routeCheck
        )
    }

    public func setCredential(_ credential: ImmichCredential?) {
        self.credential = credential
    }

    public func mapStyles() async throws -> ImmichMapStyles {
        do {
            let config = try await readUserConfig()
            guard let light = URL(string: config.map.lightStyle),
                  let dark = URL(string: config.map.darkStyle),
                  [light, dark].allSatisfy({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil })
            else { throw ImmichAPIError.invalidResponse }
            return .init(light: light, dark: dark, enabled: config.map.enabled)
        } catch { throw Self.map(error) }
    }

    private func readUserConfig() async throws -> Components.Schemas.UserConfigDto {
        switch try await makeClient().getUserConfig(.init()) {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
        }
    }

    public func validateServer() async throws -> ImmichServerInfo {
        let client = makeClient()
        do {
            async let pingOutput = client.pingServer(.init())
            async let versionOutput = client.getServerVersion(.init())
            async let configOutput = client.getServerConfig(.init())
            async let featuresOutput = client.getServerFeatures(.init())

            let ping = try await Self.ping(from: pingOutput)
            guard ping.lowercased() == "pong" else {
                throw ImmichAPIError.invalidResponse
            }
            let version = try await Self.version(from: versionOutput)
            let config = try await Self.config(from: configOutput)
            let features = try await Self.features(from: featuresOutput)

            return ImmichServerInfo(
                apiURL: apiURL,
                version: .init(
                    major: version.major,
                    minor: version.minor,
                    patch: version.patch,
                    prerelease: version.prerelease
                ),
                capabilities: .init(
                    passwordLogin: features.passwordLogin,
                    oauth: features.oauth,
                    search: features.search,
                    smartSearch: features.smartSearch,
                    facialRecognition: features.facialRecognition,
                    map: features.map
                ),
                isInitialized: config.isInitialized,
                isOnboarded: config.isOnboarded,
                maintenanceMode: config.maintenanceMode,
                loginPageMessage: config.loginPageMessage
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func login(email: String, password: String) async throws -> ImmichAuthenticatedSession {
        do {
            let output = try await makeClient().login(
                .init(body: .json(.init(email: email, password: password)))
            )
            let response: Components.Schemas.LoginResponseDto
            switch output {
            case let .created(created):
                response = try created.body.json
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
            credential = .bearer(response.accessToken)
            return ImmichAuthenticatedSession(
                apiURL: apiURL,
                accessToken: response.accessToken,
                userID: response.userId,
                userEmail: response.userEmail,
                name: response.name,
                isAdmin: response.isAdmin,
                isOnboarded: response.isOnboarded,
                shouldChangePassword: response.shouldChangePassword
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func logout() async throws {
        guard credential != nil else { return }
        do {
            let output = try await makeClient().logout(.init())
            if case let .undocumented(statusCode, _) = output {
                throw Self.map(status: statusCode)
            }
            credential = nil
        } catch {
            throw Self.map(error)
        }
    }

    private nonisolated static func logTimelineFailure(operation: String, error: Error) {
        let mapped = map(error)
        let detail = diagnosticSummary(error)
        logger.error(
            "Timeline API \(operation, privacy: .public) failed: mapped=\(String(describing: mapped), privacy: .public), detail=\(detail, privacy: .public)"
        )
    }

    private nonisolated static func diagnosticSummary(_ error: Error) -> String {
        if let clientError = error as? ClientError {
            return "ClientError -> \(diagnosticSummary(clientError.underlyingError))"
        }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .dataCorrupted(context):
                return "DecodingError.dataCorrupted at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .keyNotFound(key, context):
                return "DecodingError.keyNotFound(\(key.stringValue)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .typeMismatch(type, context):
                return "DecodingError.typeMismatch(\(type)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .valueNotFound(type, context):
                return "DecodingError.valueNotFound(\(type)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            @unknown default:
                return "DecodingError"
            }
        }
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue): \(urlError.code))"
        }
        return String(reflecting: type(of: error))
    }

    private nonisolated static func codingPath(_ path: [any CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }

    public func authenticatedUserID() async throws -> String {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        if let routeCheckSession {
            return try await Self.routeAuthenticatedUserID(
                apiURL: apiURL,
                credential: credential,
                session: routeCheckSession
            )
        }
        do {
            switch try await makeClient().getMyUser(.init()) {
            case let .ok(response):
                return try response.body.json.id
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func albums() async throws -> [ImmichAlbum] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            switch try await makeClient().getAllAlbums(.init()) {
            case let .ok(response): return try response.body.json.map(Self.album(from:))
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func album(id: String) async throws -> ImmichAlbum {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard !id.isEmpty else { throw ImmichAPIError.invalidResponse }
        do {
            switch try await makeClient().getAlbumInfo(.init(path: .init(id: id))) {
            case let .ok(response): return try Self.album(from: response.body.json)
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    private static func album(from response: Components.Schemas.AlbumResponseDto) throws -> ImmichAlbum {
        guard !response.id.isEmpty, response.assetCount >= 0 else { throw ImmichAPIError.invalidResponse }
        let owner = response.albumUsers.first { $0.role == .owner }?.user
        return ImmichAlbum(id: response.id, name: response.albumName, description: response.description,
                           thumbnailAssetID: response.albumThumbnailAssetId, assetCount: response.assetCount,
                           updatedAt: response.updatedAt, createdAt: response.createdAt,
                           startDate: response.startDate, endDate: response.endDate,
                           lastModifiedAssetTimestamp: response.lastModifiedAssetTimestamp,
                           isShared: response.shared || response.hasSharedLink,
                           ownerName: owner?.name, ownerID: owner?.id)
    }

    public func timelineBuckets(
        query: ImmichTimelineQuery = .init()
    ) async throws -> [ImmichTimelineBucket] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            let output = try await makeClient().getTimeBuckets(
                .init(query: Self.timelineBucketsQuery(from: query))
            )
            switch output {
            case let .ok(response):
                return try response.body.json.map {
                    guard $0.count >= 0, !$0.timeBucket.isEmpty else {
                        throw ImmichAPIError.invalidResponse
                    }
                    return ImmichTimelineBucket(id: $0.timeBucket, assetCount: $0.count)
                }
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "bucket summaries", error: error)
            throw Self.map(error)
        }
    }

    public func timelineAssets(
        in bucketID: String,
        query: ImmichTimelineQuery = .init()
    ) async throws -> [ImmichTimelineAsset] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard !bucketID.isEmpty else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().getTimeBucket(
                .init(query: Self.timelineBucketQuery(bucketID: bucketID, from: query))
            )
            switch output {
            case let .ok(response):
                return try Self.timelineAssets(from: response.body.json)
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "bucket assets", error: error)
            throw Self.map(error)
        }
    }

    /// 按文件名和已选字段读取非回收站资源；query不变，cursor为上页原始令牌，size为1–1000。
    /// 返回可见时间线资源及下一游标；鉴权、网络或响应异常沿用 ImmichAPIError。
    public func metadataSearch(_ query: ImmichMetadataSearch, cursor: String? = nil, size: Int = 60) async throws -> ImmichMetadataSearchPage {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard (1 ... 1000).contains(size), query.personIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ImmichAPIError.invalidResponse }
        let after = try query.takenAfter.map { try query.captureBoundary($0, endOfDay: false) }
        let before = try query.takenBefore.map { try query.captureBoundary($0, endOfDay: true) }
        if let after, let before, after > before {
            throw ImmichAPIError.invalidResponse
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.mode != .smart || text.isEmpty else { throw ImmichAPIError.invalidResponse }
        let output = try await makeClient().searchAssets(.init(body: .json(.init(
            cursor: cursor,
            filter: .init(
                city: query.city.isEmpty ? nil : .init(eq: query.city),
                country: query.country.isEmpty ? nil : .init(eq: query.country),
                description: query.mode == .description && !text.isEmpty ? .init(like: text) : nil,
                hasAlbums: query.hasAlbums.map { .init(eq: $0) },
                isFavorite: query.favoritesOnly ? .init(eq: true) : nil,
                make: query.cameraMake.isEmpty ? nil : .init(eq: query.cameraMake),
                model: query.cameraModel.isEmpty ? nil : .init(eq: query.cameraModel),
                ocr: query.mode == .ocr && !text.isEmpty ? .init(matches: text) : nil,
                originalFileName: query.mode == .fileName && !text.isEmpty ? .init(like: text) : nil,
                originalPath: query.mode == .fullPath && !text.isEmpty ? .init(like: text) : nil,
                personIds: query.personIDs.isEmpty ? nil : .init(any: query.personIDs),
                rating: ratingFilter(query.rating),
                state: query.state.isEmpty ? nil : .init(eq: query.state),
                takenAt: after == nil && before == nil ? nil : .init(gte: after, lte: before),
                trashedAt: .init(eq: .null),
                _type: query.media == .all ? nil : .init(eq: query.media == .image ? .IMAGE : .VIDEO),
                visibility: .init(eq: query.archivedOnly ? .archive : .timeline),
                iso: numericFilter(.iso, conditions: query.exifConditions),
                fNumber: numericFilter(.fNumber, conditions: query.exifConditions),
                focalLength: numericFilter(.focalLength, conditions: query.exifConditions),
                exposureTime: numericFilter(.exposureTime, conditions: query.exifConditions),
                orientation: query.orientation.map { .init(eq: $0 == .landscape ? .landscape : .portrait) }
            ),
            orderBy: .init(direction: .desc, field: .fileCreatedAt),
            size: size,
            withExif: true
        ))))
        switch output {
        case let .ok(response):
            let page = try response.body.json.assets
            return ImmichMetadataSearchPage(assets: page.items.map(Self.timelineAsset), nextCursor: page.nextCursor)
        case let .undocumented(statusCode, _):
            throw Self.map(status: statusCode)
        }
    }

    /// 按query模式读取一页；continuation须来自相同条件的上页，禁止混用页码和游标。
    /// 智能模式使用官方旧式数字分页，避免把无分页的smart V3冒充完整结果。
    public func search(_ query: ImmichMetadataSearch, continuation: ImmichSearchContinuation? = nil, size: Int = 60) async throws -> ImmichSearchPage {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.mode != .smart || text.isEmpty {
            var cursor: String?
            if let continuation {
                guard case let .cursor(value) = continuation else { throw ImmichAPIError.invalidResponse }
                cursor = value
            }
            let page = try await metadataSearch(query, cursor: cursor, size: size)
            return ImmichSearchPage(assets: page.assets, continuation: page.nextCursor.map(ImmichSearchContinuation.cursor))
        }
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        // 旧式smart没有这些组合的可靠分页契约，不得丢弃高级条件冒充成功。
        guard query.exifConditions.isEmpty, query.orientation == nil, query.hasAlbums == nil, (1 ... 1000).contains(size), query.personIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ImmichAPIError.invalidResponse }
        var pageNumber = 1
        if let continuation {
            guard case let .page(value) = continuation, value > 0 else { throw ImmichAPIError.invalidResponse }
            pageNumber = value
        }
        let after = try query.takenAfter.map { try query.captureBoundary($0, endOfDay: false) }
        let before = try query.takenBefore.map { try query.captureBoundary($0, endOfDay: true) }
        if let after, let before, after > before {
            throw ImmichAPIError.invalidResponse
        }
        let output = try await makeClient().searchSmart(.init(body: .json(.init(
            city: query.city.isEmpty ? nil : query.city,
            country: query.country.isEmpty ? nil : query.country,
            isFavorite: query.favoritesOnly ? true : nil,
            make: query.cameraMake.isEmpty ? nil : query.cameraMake,
            model: query.cameraModel.isEmpty ? nil : query.cameraModel,
            page: pageNumber,
            personIds: query.personIDs.isEmpty ? nil : query.personIDs,
            query: text,
            rating: legacyRating(query.rating),
            size: size,
            state: query.state.isEmpty ? nil : query.state,
            takenAfter: after,
            takenBefore: before,
            _type: query.media == .all ? nil : query.media == .image ? .IMAGE : .VIDEO,
            visibility: query.archivedOnly ? .archive : .timeline,
            withExif: true
        ))))
        switch output {
        case let .ok(response):
            let page = try response.body.json.assets
            // 不把未知形状或倒退/重复页码当成正常终页。
            guard page.nextCursor == nil else { throw ImmichAPIError.invalidResponse }
            var next: ImmichSearchContinuation?
            if let raw = page.nextPage {
                guard let value = Int(raw), value > pageNumber else { throw ImmichAPIError.invalidResponse }
                next = .page(value)
            }
            return ImmichSearchPage(assets: page.items.map(Self.timelineAsset), continuation: next)
        case let .undocumented(statusCode, _):
            throw Self.map(status: statusCode)
        }
    }

    /// rating来自界面；nil表示不限制，显式null筛选未评分，0–5按具体数值比较。
    private func ratingFilter(_ rating: ImmichSearchRating) throws -> ImmichNullableNumberFilter? {
        switch rating {
        case .any: return nil
        case .unrated: return .init(eq: .null)
        case let .stars(value):
            guard (0 ... 5).contains(value) else { throw ImmichAPIError.invalidResponse }
            return .init(eq: .number(Double(value)))
        }
    }

    /// rating为旧式smart评分；null保留未评分，1–5为具体值，拒绝0及越界而非悄悄省略。
    private func legacyRating(_ rating: ImmichSearchRating) throws -> ImmichNullableRatingValue? {
        switch rating {
        case .any: return nil
        case .unrated: return .null
        case let .stars(value):
            guard (1 ... 5).contains(value) else { throw ImmichAPIError.invalidResponse }
            return .stars(value)
        }
    }

    /// field为EXIF字段，conditions为本次原子条件；返回非空数值过滤或nil，非法/重复槽位拒绝。
    private func numericFilter(_ field: ImmichSearchNumericCondition.Field, conditions: [ImmichSearchNumericCondition]) throws -> Components.Schemas.NumberFilter? {
        let matching = conditions.filter { $0.field == field }
        guard !matching.isEmpty else { return nil }
        var result = Components.Schemas.NumberFilter()
        var seen: Set<ImmichSearchNumericCondition.Comparison> = []
        for condition in matching {
            guard condition.value.isFinite, condition.value >= 0, seen.insert(condition.comparison).inserted else { throw ImmichAPIError.invalidResponse }
            switch condition.comparison {
            case .equal: result.eq = condition.value
            case .greaterThan: result.gt = condition.value
            case .atLeast: result.gte = condition.value
            case .lessThan: result.lt = condition.value
            case .atMost: result.lte = condition.value
            }
        }
        return result
    }

    /// kind为账号内候选字段，make仅约束型号；返回可读字符串，不请求null候选。
    public func searchSuggestions(kind: ImmichSearchSuggestionKind, make: String? = nil) async throws -> [String] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard let field = Components.Schemas.SearchSuggestionType(rawValue: kind.rawValue) else { throw ImmichAPIError.invalidResponse }
        let output = try await makeClient().getSearchSuggestions(.init(query: .init(
            includeNull: false,
            make: kind == .cameraModel ? make : nil,
            _type: field
        )))
        switch output {
        case let .ok(response): return try response.body.json
        case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
        }
    }

    /// 读取时间线中的非回收站视频；cursor为服务端令牌、size为1–1000，返回可继续分页的实际视频。
    public func videoAssets(cursor: String? = nil, size: Int = 100) async throws -> ImmichVideoPage {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard (1 ... 1000).contains(size) else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().searchAssets(.init(body: .json(.init(
                cursor: cursor,
                filter: .init(
                    trashedAt: .init(eq: .null),
                    _type: .init(eq: .VIDEO),
                    visibility: .init(eq: .timeline)
                ),
                orderBy: .init(direction: .desc, field: .fileCreatedAt),
                size: size
            ))))
            switch output {
            case let .ok(response):
                let page = try response.body.json.assets
                return ImmichVideoPage(
                    assets: page.items.filter { $0._type == .VIDEO }.map { asset in
                        let aspectRatio: Double = if let width = asset.width,
                                                     let height = asset.height,
                                                     height > 0
                        {
                            Double(width) / Double(height)
                        } else {
                            1
                        }
                        return ImmichVideoAsset(
                            id: asset.id,
                            ownerID: asset.ownerId,
                            capturedAt: asset.fileCreatedAt,
                            localOffsetHours: asset.localDateTime.timeIntervalSince(asset.fileCreatedAt) / 3600,
                            uploadedAt: asset.createdAt,
                            thumbnailRevision: Self.thumbnailRevision(
                                createdAt: asset.createdAt,
                                fileCreatedAt: asset.fileCreatedAt
                            ),
                            durationMilliseconds: asset.duration,
                            aspectRatio: aspectRatio,
                            isFavorite: asset.isFavorite,
                            thumbhash: asset.thumbhash
                        )
                    },
                    nextCursor: page.nextCursor
                )
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func assetInfo(id: String) async throws -> ImmichAssetDetail {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard !id.isEmpty else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().getAssetInfo(.init(path: .init(id: id)))
            let response: Components.Schemas.AssetResponseDto
            switch output {
            case let .ok(ok):
                response = try ok.body.json
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
            let exif = response.exifInfo
            return ImmichAssetDetail(
                id: response.id,
                capturedAt: response.localDateTime,
                originalFileName: response.originalFileName,
                originalMimeType: response.originalMimeType,
                width: response.width,
                height: response.height,
                description: exif?.description,
                cameraMake: exif?.make,
                cameraModel: exif?.model,
                lensModel: exif?.lensModel,
                fileSizeBytes: exif?.fileSizeInByte,
                iso: exif?.iso,
                focalLength: exif?.focalLength,
                aperture: exif?.fNumber,
                exposureTime: exif?.exposureTime,
                latitude: exif?.latitude,
                longitude: exif?.longitude,
                city: exif?.city,
                state: exif?.state,
                country: exif?.country
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func people(page: Int, size: Int) async throws -> ImmichPeoplePage {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            switch try await makeClient().getAllPeople(.init(query: .init(page: page, size: size, withHidden: false))) {
            case let .ok(response):
                let result = try response.body.json
                return ImmichPeoplePage(people: result.people.filter { !$0.isHidden }.map {
                    ImmichPerson(id: $0.id, name: $0.name, updatedAt: $0.updatedAt)
                }, hasNextPage: result.hasNextPage ?? (page * size < result.total))
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func sharedLinks(serverURL: URL) async throws -> [ImmichSharedLink] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            async let config = try? readUserConfig()
            switch try await makeClient().getAllSharedLinks(.init()) {
            case let .ok(response):
                let links = try response.body.json
                guard !links.isEmpty else { return [] }
                let webBase = await Self.shareWebBase(externalDomain: config?.server?.externalDomain, serverURL: serverURL)
                return try links.map { link in
                    let album = try link.album.map(Self.album(from:))
                    return ImmichSharedLink(id: link.id, description: link.description, createdAt: link.createdAt,
                                            expiresAt: link.expiresAt, isPasswordProtected: link.password?.isEmpty == false,
                                            publicURL: Self.sharedLinkURL(webBase: webBase, slug: link.slug, key: link.key),
                                            album: album, assets: album == nil ? Self.browsableAssets(link.assets) : [])
                }
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func incomingPartners() async throws -> [ImmichPartner] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            switch try await makeClient().getPartners(.init(query: .init(direction: .shared_hyphen_with))) {
            case let .ok(response):
                return try response.body.json.map {
                    ImmichPartner(id: $0.id, name: $0.name, hasProfileImage: !$0.profileImagePath.isEmpty,
                                  profileChangedAt: $0.profileChangedAt)
                }
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func foldersEnabled() async throws -> Bool {
        try await libraryPreferences().foldersEnabled
    }

    public func libraryPreferences() async throws -> ImmichLibraryPreferences {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            switch try await makeClient().getMyPreferences(.init()) {
            case let .ok(response):
                let preferences = try response.body.json
                return ImmichLibraryPreferences(foldersEnabled: preferences.folders.enabled,
                                                sharedLinksEnabled: preferences.sharedLinks.enabled,
                                                memoriesEnabled: preferences.memories.enabled,
                                                peopleEnabled: preferences.people.enabled)
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func folderPaths() async throws -> [String] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            switch try await makeClient().getUniqueOriginalPaths(.init()) {
            case let .ok(response): return try response.body.json
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    public func folderAssets(path: String) async throws -> [ImmichTimelineAsset] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard !path.isEmpty else { throw ImmichAPIError.invalidResponse }
        do {
            switch try await makeClient().getAssetsByOriginalPath(.init(query: .init(path: path))) {
            case let .ok(response):
                return try Self.browsableAssets(response.body.json.filter {
                    ($0.originalPath as NSString).deletingLastPathComponent == path
                })
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    private static func shareWebBase(externalDomain: String?, serverURL: URL) -> URL? {
        if let externalDomain, var components = URLComponents(string: externalDomain),
           let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
           components.host?.isEmpty == false, components.user == nil, components.password == nil
        {
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.url
        }
        return serverURL.lastPathComponent == "api" ? serverURL.deletingLastPathComponent() : nil
    }

    private static func sharedLinkURL(webBase: URL?, slug: String?, key: String) -> URL? {
        if let slug, !slug.isEmpty, slug != ".", slug != ".." {
            return webBase?.appending(path: "s").appending(component: slug)
        }
        guard !key.isEmpty, key != ".", key != "..", !key.contains("/") else { return nil }
        return webBase?.appending(path: "share").appending(component: key)
    }

    private static func browsableAssets(_ assets: [Components.Schemas.AssetResponseDto]) -> [ImmichTimelineAsset] {
        assets.filter { !$0.isTrashed && $0.visibility != .locked && ($0._type == .IMAGE || $0._type == .VIDEO) }
            .map(timelineAsset)
    }

    public func memories(query: ImmichMemoryQuery = .init(), includeTimelineAssets: Bool = false) async throws -> [ImmichMemory] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard query.page > 0, query.size > 0 else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().searchMemories(
                .init(query: .init(
                    _for: query.date,
                    isTrashed: false,
                    order: .desc,
                    page: query.page,
                    size: query.size
                ))
            )
            switch output {
            case let .ok(response):
                return try response.body.json.map { try Self.memory(from: $0, includeTimelineAssets: includeTimelineAssets) }
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "memories", error: error)
            throw Self.map(error)
        }
    }

    /// Route validation intentionally decodes only the stable identity field it needs. Decoding
    /// the complete generated `UserAdminResponseDto` makes a healthy endpoint look unreachable
    /// whenever an Immich server version adds, removes, or omits an unrelated user property.
    static func routeAuthenticatedUserID(
        apiURL: URL,
        credential: ImmichCredential?,
        session: URLSession
    ) async throws -> String {
        guard let credential else { throw ImmichAPIError.unauthorized }

        let endpoint = apiURL
            .appendingPathComponent("users")
            .appendingPathComponent("me")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        switch credential {
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ImmichAPIError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw Self.map(status: response.statusCode)
            }
            return try Self.routeUserID(from: data)
        } catch {
            throw Self.map(error)
        }
    }

    static func routeUserID(from data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(RouteIdentity.self, from: data).id
        } catch {
            throw ImmichAPIError.invalidResponse
        }
    }

    static func timelineAssets(
        from response: Components.Schemas.TimeBucketAssetResponseDto
    ) throws -> [ImmichTimelineAsset] {
        let count = response.id.count
        let requiredCounts = [
            response.createdAt.count,
            response.duration.count,
            response.fileCreatedAt.count,
            response.isFavorite.count,
            response.isImage.count,
            response.isTrashed.count,
            response.livePhotoVideoId.count,
            response.localOffsetHours.count,
            response.ownerId.count,
            response.projectionType.count,
            response.ratio.count,
            response.thumbhash.count,
            response.visibility.count,
        ]
        guard requiredCounts.allSatisfy({ $0 == count }) else {
            throw ImmichAPIError.invalidResponse
        }

        return try response.id.indices.map { index in
            guard let createdAt = parseTimelineDate(response.createdAt[index]),
                  let fileCreatedAt = parseTimelineDate(response.fileCreatedAt[index]),
                  response.ratio[index].isFinite,
                  response.ratio[index] > 0,
                  response.localOffsetHours[index].isFinite
            else {
                throw ImmichAPIError.invalidResponse
            }

            return ImmichTimelineAsset(
                id: response.id[index],
                ownerID: response.ownerId[index],
                createdAt: createdAt,
                fileCreatedAt: fileCreatedAt,
                localOffsetHours: response.localOffsetHours[index],
                mediaKind: response.isImage[index] ? .image : .video,
                durationMilliseconds: response.duration[index],
                aspectRatio: response.ratio[index],
                isFavorite: response.isFavorite[index],
                isTrashed: response.isTrashed[index],
                visibility: .init(serverValue: response.visibility[index].rawValue),
                livePhotoVideoID: response.livePhotoVideoId[index],
                stack: stack(at: index, in: response.stack),
                projectionType: response.projectionType[index],
                thumbhash: response.thumbhash[index],
                city: optionalValue(at: index, in: response.city),
                country: optionalValue(at: index, in: response.country),
                latitude: optionalValue(at: index, in: response.latitude),
                longitude: optionalValue(at: index, in: response.longitude),
                thumbnailRevision: thumbnailRevision(
                    createdAt: createdAt,
                    fileCreatedAt: fileCreatedAt
                )
            )
        }
    }

    static func thumbnailRevision(createdAt: Date, fileCreatedAt: Date) -> Date {
        max(createdAt, fileCreatedAt)
    }

    private static func timelineBucketsQuery(
        from query: ImmichTimelineQuery
    ) throws -> Operations.getTimeBuckets.Input.Query {
        try .init(
            albumId: query.albumID,
            isFavorite: query.isFavorite,
            isTrashed: query.includesTrashed,
            order: timelineOrder(from: query.order),
            orderBy: timelineOrderBy(from: query.orderBy),
            personId: query.personID,
            userId: query.userID,
            visibility: query.albumID == nil ? query.visibility.map { try timelineVisibility(from: $0) } : nil,
            withCoordinates: true,
            withPartners: query.includesPartners,
            withStacked: query.includesStacks
        )
    }

    private static func timelineBucketQuery(
        bucketID: String,
        from query: ImmichTimelineQuery
    ) throws -> Operations.getTimeBucket.Input.Query {
        try .init(
            albumId: query.albumID,
            isFavorite: query.isFavorite,
            isTrashed: query.includesTrashed,
            order: timelineOrder(from: query.order),
            orderBy: timelineOrderBy(from: query.orderBy),
            personId: query.personID,
            timeBucket: bucketID,
            userId: query.userID,
            visibility: query.albumID == nil ? query.visibility.map { try timelineVisibility(from: $0) } : nil,
            withCoordinates: true,
            withPartners: query.includesPartners,
            withStacked: query.includesStacks
        )
    }

    private static func timelineOrder(
        from order: ImmichTimelineOrder
    ) -> Components.Schemas.AssetOrder {
        switch order {
        case .ascending: .asc
        case .descending: .desc
        }
    }

    private static func timelineOrderBy(
        from orderBy: ImmichTimelineOrderBy
    ) -> Components.Schemas.AssetOrderBy {
        switch orderBy {
        case .takenAt: .takenAt
        case .createdAt: .createdAt
        }
    }

    private static func timelineVisibility(
        from visibility: ImmichAssetVisibility
    ) throws -> Components.Schemas.AssetVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case .unknown: throw ImmichAPIError.invalidResponse
        }
    }

    private static func memory(from response: Components.Schemas.MemoryResponseDto, includeTimelineAssets: Bool) throws -> ImmichMemory {
        guard !response.id.isEmpty, !response.ownerId.isEmpty else {
            throw ImmichAPIError.invalidResponse
        }
        let kind: ImmichMemoryKind = switch response._type {
        case .on_this_day: .onThisDay
        case .birthday: .birthday
        }
        return ImmichMemory(
            id: response.id,
            ownerID: response.ownerId,
            memoryAt: response.memoryAt,
            year: response.data.year,
            kind: kind,
            showAt: response.showAt,
            assets: response.assets.map { asset in
                let mediaKind: ImmichTimelineMediaKind = switch asset._type {
                case .IMAGE: .image
                case .VIDEO: .video
                case .AUDIO: .audio
                case .OTHER: .other
                }
                return ImmichMemoryAsset(
                    id: asset.id,
                    updatedAt: asset.updatedAt,
                    mediaKind: mediaKind
                )
            },
            timelineAssets: includeTimelineAssets ? response.assets.map(Self.timelineAsset) : nil
        )
    }

    private static func timelineAsset(_ asset: Components.Schemas.AssetResponseDto) -> ImmichTimelineAsset {
        let kind: ImmichTimelineMediaKind = switch asset._type {
        case .IMAGE: .image
        case .VIDEO: .video
        case .AUDIO: .audio
        case .OTHER: .other
        }
        return ImmichTimelineAsset(id: asset.id, ownerID: asset.ownerId, createdAt: asset.createdAt,
                                   fileCreatedAt: asset.fileCreatedAt,
                                   localOffsetHours: asset.localDateTime.timeIntervalSince(asset.fileCreatedAt) / 3600,
                                   mediaKind: kind, durationMilliseconds: asset.duration,
                                   aspectRatio: Double(max(1, asset.width ?? 1)) / Double(max(1, asset.height ?? 1)),
                                   isFavorite: asset.isFavorite, isTrashed: asset.isTrashed,
                                   visibility: .init(serverValue: asset.visibility.rawValue), livePhotoVideoID: asset.livePhotoVideoId,
                                   stack: nil, projectionType: nil, thumbhash: asset.thumbhash,
                                   city: asset.exifInfo?.city, country: asset.exifInfo?.country,
                                   latitude: asset.exifInfo?.latitude, longitude: asset.exifInfo?.longitude,
                                   thumbnailRevision: thumbnailRevision(createdAt: asset.createdAt, fileCreatedAt: asset.fileCreatedAt))
    }

    private static func parseTimelineDate(_ value: String) -> Date? {
        try? dateTranscoder.decode(value)
    }

    private static func optionalValue<Value>(at index: Int, in values: [Value?]?) -> Value? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func stack(at index: Int, in stacks: [[String]?]?) -> ImmichTimelineStack? {
        guard let values = optionalValue(at: index, in: stacks),
              values.count == 2,
              !values[0].isEmpty,
              let count = Int(values[1]),
              count > 0
        else {
            return nil
        }
        return ImmichTimelineStack(id: values[0], assetCount: count)
    }

    private func makeClient() -> Client {
        Client(
            serverURL: apiURL,
            configuration: .init(dateTranscoder: Self.dateTranscoder),
            transport: transport,
            middlewares: [AuthenticationMiddleware(credential: credential)]
        )
    }

    static func map(_ error: Error) -> ImmichAPIError {
        if let error = error as? ImmichAPIError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let clientError = error as? ClientError {
            return map(clientError.underlyingError)
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .clientCertificateRejected:
                return .certificateUntrusted
            case .secureConnectionFailed:
                return .secureConnectionFailed
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .networkConnectionLost:
                return .offline
            default: return .offline
            }
        }
        return .invalidResponse
    }

    static func map(status: Int) -> ImmichAPIError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        case 500 ... 599: .serverError(status)
        default: .httpStatus(status)
        }
    }

    private static func ping(from output: Operations.pingServer.Output) throws -> String {
        switch output {
        case let .ok(response): try response.body.json.res
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func version(
        from output: Operations.getServerVersion.Output
    ) throws -> Components.Schemas.ServerVersionResponseDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func config(
        from output: Operations.getServerConfig.Output
    ) throws -> Components.Schemas.ServerConfigDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func features(
        from output: Operations.getServerFeatures.Output
    ) throws -> Components.Schemas.ServerFeaturesDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }
}
