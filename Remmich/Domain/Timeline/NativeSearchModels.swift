import Foundation

/// 界面允许加载的账号内候选，不暴露SDK枚举。
nonisolated enum NativeSearchSuggestionKind: String, Sendable {
    case country, state
    case city
    case cameraMake = "camera-make"
    case cameraModel = "camera-model"
    case cameraLensModel = "camera-lens-model"
}

/// 界面自己的搜索状态；只有Infrastructure负责转换为网络SDK请求。
nonisolated struct NativeSearchQuery: Hashable, Sendable {
    /// 界面支持的文本语义，不将SDK DTO泄露到Feature层。
    enum Mode: String, CaseIterable, Sendable {
        case fileName, description, fullPath, ocr, smart

        /// 可见模式名称，不含服务端实现细节。
        var title: String {
            switch self {
            case .fileName: "File name"
            case .description: "Description"
            case .fullPath: "Path"
            case .ocr: "OCR"
            case .smart: "Smart search"
            }
        }
    }

    /// 未选类型时保留所有可见媒体。
    enum Media: String, CaseIterable, Sendable { case all, image, video }

    var text = ""
    /// 参考图使用服务端UUID v4；与文字互斥，只在smart模式使用，不包含本地文件或图片字节。
    var queryAssetID: String?
    var mode: Mode = .fileName
    var media: Media = .all
    var mediaCategory: NativeSearchMediaCategory?
    var resolution: NativeSearchResolution?
    var panoramasOnly = false
    var country = ""
    var state = ""
    /// false表示不限制收藏/保留时间线，true才增加收藏或归档条件。
    var favoritesOnly = false
    var archivedOnly = false
    var rating: NativeSearchRating = .any
    var city = ""
    var cameraMake = ""
    var cameraModel = ""
    var lensModel = ""
    var tags: NativeSearchTagFilter = .any
    enum Orientation: String, Codable, CaseIterable, Sendable { case landscape, portrait }
    var orientation: Orientation?
    var hasAlbums: Bool?
    var exifConditions: [NativeSearchNumericCondition] = []
    var personIDs: [String] = []
    var takenAfter: Date?
    var takenBefore: Date?
    var timeZone = TimeZone.current

    /// 参考图及高级智能条件需要独立Fork分页；不能将参考图静默降级成无文字的metadata。
    var requiresForkSmartSearch: Bool {
        guard mode == .smart else { return false }
        if queryAssetID != nil {
            return true
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return orientation != nil || hasAlbums != nil || !exifConditions.isEmpty || rating.requiresStructuredSearch
            || mediaCategory != nil || resolution != nil || panoramasOnly || tags != .any
    }

    /// assetID为已加载结果中的服务端身份；切换为参考图时只替换查询来源，完整保留筛选。
    mutating func useReferenceAsset(_ assetID: String) {
        queryAssetID = assetID
        text = ""
        mode = .smart
    }

    /// value为用户输入的文字；输入立即退出参考图模式，其他条件和当前文本模式保持不变。
    mutating func useSearchText(_ value: String) {
        queryAssetID = nil
        text = value
    }
}

/// 原生搜索与保存条件共用的来源类别；不等同于照片/视频资源类型。
nonisolated enum NativeSearchMediaCategory: String, Codable, CaseIterable, Sendable {
    case phoneVideo = "phone-video", screenshot, deltaScreenshot = "delta-screenshot"
    case steamScreenshot = "steam-screenshot", switchScreenshot = "switch-screenshot", nintendo3dsScreenshot = "3ds-screenshot"

    /// 返回可见类别名称；识别逻辑由服务端维护。
    var title: String {
        switch self {
        case .phoneVideo: "Phone videos"
        case .screenshot: "Screenshots"
        case .deltaScreenshot: "Delta screenshots"
        case .steamScreenshot: "Steam screenshots"
        case .switchScreenshot: "Nintendo Switch screenshots"
        case .nintendo3dsScreenshot: "Nintendo 3DS screenshots"
        }
    }
}

/// 可保存和恢复的分辨率档位，原始值保持Web登记协议。
nonisolated enum NativeSearchResolution: String, Codable, CaseIterable, Sendable {
    case hd = "720p", fullHD = "1080p", twoK = "2k", fourK = "4k"
}

/// 标签筛选三态；所选多个ID采用任一匹配（含后代），与Web保存条件的结构化语义一致。
nonisolated enum NativeSearchTagFilter: Hashable, Sendable {
    case any, untagged, anyOf([String])

    /// 返回当前选中ID，其他两态返回空数组；仅供界面选择，不将空数组编码为查询。
    var selectedIDs: [String] {
        if case let .anyOf(ids) = self {
            return ids
        }
        return []
    }

    /// id是候选UUID；按UUID大小写不敏感比较，以正确呈现既有保存条件。
    func contains(_ id: String) -> Bool {
        selectedIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// id是当前账号候选、selected决定加入/移除；选最后一项取消后恢复不限制，不保留空ID数组。
    mutating func setSelected(_ id: String, selected: Bool) {
        guard contains(id) != selected else { return }
        var ids = selectedIDs.filter { $0.caseInsensitiveCompare(id) != .orderedSame }
        if selected {
            ids.append(id)
        }
        self = ids.isEmpty ? .any : .anyOf(ids)
    }
}

/// Domain标签候选只包含搜索所需字段，Feature不接触SDK类型。
nonisolated struct NativeSearchTag: Identifiable, Hashable, Sendable {
    let id: String
    let value: String
}

/// 界面评分筛选的三种语义；具体0分不能在保存/复用时变为未指定。
nonisolated enum NativeSearchRating: Hashable, Sendable {
    case any, unrated, stars(Int)

    /// 0分不在旧式smart的1–5/null契约内，需要独立Fork结构化分页，不能静默丢弃。
    var requiresStructuredSearch: Bool {
        switch self { case .any, .unrated: false; case let .stars(value): value == 0 }
    }
}

/// 可独立编辑的EXIF条件；相同字段/运算符只有一个稳定槽位。
nonisolated struct NativeSearchNumericCondition: Codable, Hashable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case iso, fNumber, focalLength, exposureTime

        /// 可见名称包含单位，快门按秒、焦距按毫米输入。
        var title: String {
            switch self {
            case .iso: "ISO"
            case .fNumber: "Aperture"
            case .focalLength: "Focal length (mm)"
            case .exposureTime: "Exposure (seconds)"
            }
        }
    }

    enum Comparison: String, Codable, CaseIterable, Sendable {
        case equal = "eq", greaterThan = "gt", atLeast = "gte", lessThan = "lt", atMost = "lte"

        /// 返回可见比较符号。
        var title: String {
            switch self {
            case .equal: "="
            case .greaterThan: ">"
            case .atLeast: ">="
            case .lessThan: "<"
            case .atMost: "<="
            }
        }
    }

    let field: Field
    let comparison: Comparison
    let value: Double
    enum CodingKeys: String, CodingKey { case field, comparison = "operator", value }

    /// 槽位标识不包含查询值，便于原子更新与移除。
    var id: String {
        "\(field.rawValue):\(comparison.rawValue)"
    }
}

/// 领域层区分不透明令牌与页码，避免Feature依赖SDK分页类型。
nonisolated enum NativeSearchContinuation: Hashable, Sendable {
    case cursor(String)
    case page(Int)
    case forkCursor(String)
}

/// 可安全展示的搜索错误，不携带URL、token或服务器原始响应体。
nonisolated enum NativeSearchError: Error, LocalizedError, Sendable {
    case unauthorized, forbidden, invalidQuery, invalidResponse, rateLimited, unavailable, unsupportedExtension

    /// 按可恢复动作区分鉴权、权限、条件、格式及网络失败。
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session is no longer authorized. Sign in again."
        case .forbidden: "This account does not have permission to search these resources."
        case .invalidQuery: "The server rejected these search conditions. Check filters and server version."
        case .invalidResponse: "The search response could not be understood."
        case .rateLimited: "Too many requests. Try again shortly."
        case .unavailable: "Search could not be loaded. Check connection and server version."
        case .unsupportedExtension: "This server does not support advanced smart search. Your filters have been kept. Choose a metadata mode or retry after the server is updated."
        }
    }
}
