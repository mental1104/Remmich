import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import OSLog

/// 账号API封装，保留可更新凭据与固定传输边界；随机与Fork高级搜索使用受限可取消前台读取。
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
    private let forkSmartTransport: any ClientTransport
    private let routeCheckSession: URLSession?

    /// apiURL为已验证API根，credential为可选会话/API key，transport注入读取边界或测试替身。
    /// 未注入时Fork使用不缓存/禁重定向前台会话，既有SDK调用保留原传输。
    public init(
        apiURL: URL,
        credential: ImmichCredential? = nil,
        transport: (any ClientTransport)? = nil
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport ?? ImmichNetworkSession.transport
        forkSmartTransport = transport ?? ImmichSearchNetwork.transport
        routeCheckSession = nil
    }

    /// apiURL/credential为路由检查身份，transport和routeCheckSession属于原健康检查会话。
    /// Fork交互搜索不复用该检查会话，仍使用独立受限传输。
    private init(
        apiURL: URL,
        credential: ImmichCredential?,
        transport: any ClientTransport,
        routeCheckSession: URLSession
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport
        forkSmartTransport = ImmichSearchNetwork.transport
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

    /// 为交互管理读取创建不缓存、禁cookie/重定向的前台SDK客户端；apiURL/credential须来自已验证会话。
    /// 仍使用相同只读策略、鉴权和日期编码；不配置持久GET传输或后台索引缓存。
    public static func foregroundReadClient(apiURL: URL, credential: ImmichCredential) -> ImmichClient {
        ImmichClient(apiURL: apiURL, credential: credential, transport: ImmichSearchNetwork.transport)
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

    /// 从官方随机入口读取一批可见照片；size为1–1000，默认60，不返回或伪造分页游标。
    /// 每次调用重新由服务器随机抽样；排除视频、归档、锁定和回收站，取消与HTTP错误不转为空批次。
    public func randomPhotos(size: Int = 60) async throws -> [ImmichTimelineAsset] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard (1 ... 1000).contains(size) else { throw ImmichAPIError.invalidResponse }
        do {
            try Task.checkCancellation()
            // 交互随机抽样复用受限前台传输，不将POST条件放入只记录URL的持久GET日志。
            let client = Client(serverURL: apiURL, configuration: .init(dateTranscoder: Self.dateTranscoder),
                                transport: forkSmartTransport, middlewares: [AuthenticationMiddleware(credential: credential)])
            let output = try await client.searchRandom(.init(body: .json(.init(
                filter: .init(trashedAt: .init(eq: .null), _type: .init(eq: .IMAGE), visibility: .init(eq: .timeline)),
                size: size, withExif: true
            ))))
            try Task.checkCancellation()
            switch output {
            case let .ok(response):
                let values = try response.body.json
                guard values.count <= size,
                      values.allSatisfy({ $0._type == .IMAGE && $0.visibility == .timeline && !$0.isTrashed })
                else { throw ImmichAPIError.invalidResponse }
                return values.map(Self.timelineAsset)
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
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
    /// 返回可见时间线资源及下一游标；参考图须调用search，鉴权、条件、网络或响应错误沿用ImmichAPIError。
    public func metadataSearch(_ query: ImmichMetadataSearch, cursor: String? = nil, size: Int = 60) async throws -> ImmichMetadataSearchPage {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard (1 ... 1000).contains(size) else { throw ImmichAPIError.invalidResponse }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.queryAssetID == nil, query.mode != .smart || text.isEmpty else { throw ImmichAPIError.invalidResponse }
        let output = try await makeClient().searchAssets(.init(body: .json(.init(
            cursor: cursor,
            filter: structuredSearchFilter(query),
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

    /// query为完整原生条件；metadata/Fork智能共用同一映射，非法日期、设备型号组或原子条件在网络前拒绝。
    private func structuredSearchFilter(_ query: ImmichMetadataSearch) throws -> Components.Schemas.SearchFilter {
        guard query.personIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ImmichAPIError.invalidResponse }
        let tagIDs = try selectedSearchTagIDs(query.tags)
        let after = try query.takenAfter.map { try query.captureBoundary($0, endOfDay: false) }
        let before = try query.takenBefore.map { try query.captureBoundary($0, endOfDay: true) }
        if let after, let before, after > before {
            throw ImmichAPIError.invalidResponse
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try .init(
            city: query.city.isEmpty ? nil : .init(eq: query.city),
            country: query.country.isEmpty ? nil : .init(eq: query.country),
            description: query.mode == .description && !text.isEmpty ? .init(like: text) : nil,
            hasAlbums: query.hasAlbums.map { .init(eq: $0) },
            hasTags: query.tags == .untagged ? .init(eq: false) : nil,
            isFavorite: query.favoritesOnly ? .init(eq: true) : nil,
            lensModel: query.lensModel.isEmpty ? nil : .init(eq: query.lensModel),
            make: query.cameraMake.isEmpty ? nil : .init(eq: query.cameraMake),
            model: deviceModelFilter(query),
            ocr: query.mode == .ocr && !text.isEmpty ? .init(matches: text) : nil,
            originalFileName: query.mode == .fileName && !text.isEmpty ? .init(like: text) : nil,
            originalPath: query.mode == .fullPath && !text.isEmpty ? .init(like: text) : nil,
            personIds: query.personIDs.isEmpty ? nil : .init(any: query.personIDs),
            rating: ratingFilter(query.rating),
            state: query.state.isEmpty ? nil : .init(eq: query.state),
            tagIds: tagIDs.map { .init(any: $0) },
            takenAt: after == nil && before == nil ? nil : .init(gte: after, lte: before),
            trashedAt: .init(eq: .null),
            _type: query.media == .all ? nil : .init(eq: query.media == .image ? .IMAGE : .VIDEO),
            visibility: .init(eq: query.archivedOnly ? .archive : .timeline),
            iso: numericFilter(.iso, conditions: query.exifConditions),
            fNumber: numericFilter(.fNumber, conditions: query.exifConditions),
            focalLength: numericFilter(.focalLength, conditions: query.exifConditions),
            exposureTime: numericFilter(.exposureTime, conditions: query.exifConditions),
            orientation: query.orientation.map { .init(eq: $0 == .landscape ? .landscape : .portrait) },
            isPanorama: query.panoramasOnly ? .init(eq: true) : nil,
            isPhoneVideo: query.mediaCategory == .phoneVideo ? .init(eq: true) : nil,
            isScreenshot: query.mediaCategory == .screenshot ? .init(eq: true) : nil,
            isNintendo3dsScreenshot: query.mediaCategory == .nintendo3dsScreenshot ? .init(eq: true) : nil,
            isSwitchScreenshot: query.mediaCategory == .switchScreenshot ? .init(eq: true) : nil,
            isSteamScreenshot: query.mediaCategory == .steamScreenshot ? .init(eq: true) : nil,
            isDeltaScreenshot: query.mediaCategory == .deltaScreenshot ? .init(eq: true) : nil,
            resolution: resolutionFilter(query.resolution)
        )
    }

    /// resolution为可选服务端档位；返回生成Schema条件，未知映射明确拒绝而不丢弃筛选。
    private func resolutionFilter(_ resolution: ImmichSearchResolution?) throws -> Components.Schemas.MediaResolutionFilter? {
        guard let resolution else { return nil }
        guard let value = Components.Schemas.MediaResolution(rawValue: resolution.rawValue) else { throw ImmichAPIError.invalidResponse }
        return .init(eq: value)
    }

    /// tags为三态过滤；返回任一匹配的ID数组或nil，空/重复/非UUID v4在请求前拒绝。
    private func selectedSearchTagIDs(_ tags: ImmichSearchTagFilter) throws -> [String]? {
        guard case let .anyOf(ids) = tags else { return nil }
        guard (1 ... 100).contains(ids.count), ids.allSatisfy(ImmichSearchTagFilter.isValidID),
              Set(ids.map { $0.lowercased() }).count == ids.count else { throw ImmichAPIError.invalidResponse }
        return ids
    }

    /// 读取当前凭据可见的官方标签候选；返回完整层级名称，拒绝重复/非UUID v4身份，不写入标签或资产。
    public func searchTags() async throws -> [ImmichSearchTag] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            let output = try await makeClient().getAllTags(.init())
            try Task.checkCancellation()
            switch output {
            case let .ok(response):
                let tags = try response.body.json
                guard Set(tags.map { $0.id.lowercased() }).count == tags.count else { throw ImmichAPIError.invalidResponse }
                return try tags.map { tag in
                    guard ImmichSearchTagFilter.isValidID(tag.id), !tag.value.isEmpty else { throw ImmichAPIError.invalidResponse }
                    return ImmichSearchTag(id: tag.id.lowercased(), value: tag.value)
                }
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    /// query包含独立单型号与设备OR组；返回合并的官方model过滤，空条件省略，非法别名集合在网络前拒绝。
    private func deviceModelFilter(_ query: ImmichMetadataSearch) throws -> Components.Schemas.StringFilterNullable? {
        guard query.deviceModels.count <= 50,
              query.deviceModels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256 })
        else { throw ImmichAPIError.invalidResponse }
        guard !query.cameraModel.isEmpty || !query.deviceModels.isEmpty else { return nil }
        // 不将产品名称写入请求，也不以设备组覆盖用户额外选择的单型号。
        return .init(eq: query.cameraModel.isEmpty ? nil : query.cameraModel,
                     _in: query.deviceModels.isEmpty ? nil : query.deviceModels)
    }

    /// 按query模式读取一页；continuation须来自相同条件的上页，禁止混用页码和游标。
    /// 普通智能模式保留官方页码，参考图和高级组合只走独立Fork绑定游标，不删减条件降级。
    public func search(_ query: ImmichMetadataSearch, continuation: ImmichSearchContinuation? = nil, size: Int = 60) async throws -> ImmichSearchPage {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 参考图不能被metadata分支忽略；错误模式或混合文字必须在发送前完整拒绝。
        if query.queryAssetID != nil {
            guard query.mode == .smart, text.isEmpty else { throw ImmichAPIError.invalidResponse }
        }
        if query.mode != .smart || (text.isEmpty && query.queryAssetID == nil) {
            var cursor: String?
            if let continuation {
                guard case let .cursor(value) = continuation else { throw ImmichAPIError.invalidResponse }
                cursor = value
            }
            let page = try await metadataSearch(query, cursor: cursor, size: size)
            return ImmichSearchPage(assets: page.assets, continuation: page.nextCursor.map(ImmichSearchContinuation.cursor))
        }
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        if query.requiresForkSmartSearch {
            return try await forkSmartSearch(query, continuation: continuation, size: size)
        }
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
            lensModel: query.lensModel.isEmpty ? nil : query.lensModel,
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

    /// 独立Fork只读请求体；query/queryAssetId必须二选一，缺省Optional由合成编码器省略。
    /// 不向生成的官方SmartSearchDto加入自定义字段或路径。
    private struct ForkSmartSearchBody: Encodable {
        let query: String?
        let queryAssetId: String?
        let filter: Components.Schemas.SearchFilter
        let size: Int
        let cursor: String?
        let withExif = true
    }

    /// query完整保留筛选并验证文字/UUID v4参考图互斥；continuation仅接受Fork令牌，size为1–1000。
    /// 返回本次结果页；非法来源/令牌发送前失败，缺路由和其他HTTP错误保留给账号范围界面提示。
    private func forkSmartSearch(_ query: ImmichMetadataSearch, continuation: ImmichSearchContinuation?, size: Int) async throws -> ImmichSearchPage {
        guard (1 ... 1000).contains(size) else { throw ImmichAPIError.invalidResponse }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = query.queryAssetID {
            guard text.isEmpty, let uuid = UUID(uuidString: reference),
                  uuid.uuid.6 & 0xF0 == 0x40, uuid.uuid.8 & 0xC0 == 0x80 else { throw ImmichAPIError.invalidResponse }
        } else {
            guard !text.isEmpty, text.utf16.count <= 2000 else { throw ImmichAPIError.invalidResponse }
        }
        var cursor: String?
        if let continuation {
            guard case let .forkCursor(value) = continuation, !value.isEmpty, value.utf16.count <= 4096 else { throw ImmichAPIError.invalidResponse }
            cursor = value
        }
        let transcoder = Self.dateTranscoder
        let encoder = JSONEncoder()
        // 与生成SDK的应用日期配置一致，保留本地日界线的毫秒格式及null三态。
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(transcoder.encode(date))
        }
        let data = try encoder.encode(ForkSmartSearchBody(query: query.queryAssetID == nil ? text : nil,
                                                          queryAssetId: query.queryAssetID, filter: structuredSearchFilter(query), size: size, cursor: cursor))
        let operationID = "forkSearchSmart"
        let request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/fork/search/smart",
                                  headerFields: [.contentType: "application/json", .accept: "application/json", .cacheControl: "no-store"])
        let network = forkSmartTransport
        do {
            try Task.checkCancellation()
            let (response, body) = try await AuthenticationMiddleware(credential: credential).intercept(
                request, body: HTTPBody(data, length: .known(Int64(data.count)), iterationBehavior: .multiple), baseURL: apiURL,
                operationID: operationID
            ) { request, body, baseURL in
                try await network.send(request, body: body, baseURL: baseURL, operationID: operationID)
            }
            try Task.checkCancellation()
            guard response.status.code == 200 else { throw Self.map(status: response.status.code) }
            guard let body else { throw ImmichAPIError.invalidResponse }
            let bytes = try await Data(collecting: body, upTo: 32 * 1024 * 1024)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                try transcoder.decode(decoder.singleValueContainer().decode(String.self))
            }
            let page = try decoder.decode(Components.Schemas.SearchResponseDto.self, from: bytes).assets
            try Task.checkCancellation()
            guard page.nextPage == nil else { throw ImmichAPIError.invalidResponse }
            if let next = page.nextCursor, next.isEmpty || next == cursor {
                throw ImmichAPIError.invalidResponse
            }
            return ImmichSearchPage(assets: page.items.map(Self.timelineAsset), continuation: page.nextCursor.map(ImmichSearchContinuation.forkCursor))
        } catch {
            throw Self.map(error)
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

    /// kind选择账号内候选；make约束型号/镜头，model只约束镜头，返回非null字符串。
    public func searchSuggestions(kind: ImmichSearchSuggestionKind, make: String? = nil, model: String? = nil) async throws -> [String] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard let field = Components.Schemas.SearchSuggestionType(rawValue: kind.rawValue) else { throw ImmichAPIError.invalidResponse }
        let output = try await makeClient().getSearchSuggestions(.init(query: .init(
            includeNull: false,
            make: kind == .cameraModel || kind == .cameraLensModel ? make : nil,
            model: kind == .cameraLensModel ? model : nil,
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

    /// 管理页显式包含隐藏人物；page/size沿用官方分页，默认浏览people方法保持不变。
    /// 调用方使用前台client避免已完成GET缓存；取消/HTTP/非法分页错误继续抛出。
    public func managementPeople(page: Int, size: Int) async throws -> ImmichManagementPeoplePage {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard page >= 1, (1 ... 1000).contains(size) else { throw ImmichAPIError.invalidResponse }
        do {
            try Task.checkCancellation()
            let output = try await makeClient().getAllPeople(.init(query: .init(page: page, size: size, withHidden: true)))
            try Task.checkCancellation()
            switch output {
            case let .ok(response):
                let result = try response.body.json
                guard result.total >= 0, result.people.count <= size else { throw ImmichAPIError.invalidResponse }
                return ImmichManagementPeoplePage(people: result.people.map {
                    .init(id: $0.id, name: $0.name, isHidden: $0.isHidden, updatedAt: $0.updatedAt)
                }, hasNextPage: result.hasNextPage ?? (page <= result.total / size && page * size < result.total))
            case let .undocumented(statusCode, _): throw Self.map(status: statusCode)
            }
        } catch { throw Self.map(error) }
    }

    /// 官方stack列表是无分页数组；调用方使用前台读取client，不复用持久索引GET。
    public func managementStacks() async throws -> [ImmichNativeStack] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            try Task.checkCancellation()
            let output = try await makeClient().searchStacks(.init())
            try Task.checkCancellation()
            switch output {
            case let .ok(response): return try response.body.json.map(Self.nativeStack)
            case let .undocumented(code, _): throw Self.map(status: code)
            }
        } catch { throw Self.map(error) }
    }

    /// id为官方stack UUID；返回真实当前成员，未知ID的权限失败保持原样，不能等同于已删除证明。
    public func managementStack(_ id: String) async throws -> ImmichNativeStack {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard UUID(uuidString: id) != nil else { throw ImmichAPIError.invalidResponse }
        do {
            try Task.checkCancellation()
            let output = try await makeClient().getStack(.init(path: .init(id: id)))
            try Task.checkCancellation()
            switch output {
            case let .ok(response): return try Self.nativeStack(response.body.json)
            case let .undocumented(code, _): throw Self.map(status: code)
            }
        } catch { throw Self.map(error) }
    }

    /// response由官方生成DTO解码；成员映射复用原始图片/视频显示元数据，不伪造完整隐藏成员数。
    private static func nativeStack(_ response: Components.Schemas.StackResponseDto) -> ImmichNativeStack {
        .init(id: response.id, primaryAssetID: response.primaryAssetId, assets: response.assets.map(timelineAsset))
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
