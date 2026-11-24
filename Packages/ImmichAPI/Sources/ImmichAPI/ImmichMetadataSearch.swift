import Foundation

/// 当前账户可用的搜索候选字段；不是公共地理编码服务。
public enum ImmichSearchSuggestionKind: String, Sendable {
    case country, state
    case city
    case cameraMake = "camera-make"
    case cameraModel = "camera-model"
    case cameraLensModel = "camera-lens-model"
}

/// 原生元数据搜索条件；空值表示不限制，不包含账号范围或客户端计算的分页偏移。
public struct ImmichMetadataSearch: Hashable, Sendable {
    /// 搜索文本的语义；智能模式走smart，其他模式只走metadata。
    public enum Mode: String, CaseIterable, Sendable {
        case fileName, description, fullPath, ocr, smart

        /// 返回原生界面的模式名称，不包含请求参数。
        public var title: String {
            switch self {
            case .fileName: "File name"
            case .description: "Description"
            case .fullPath: "Path"
            case .ocr: "OCR"
            case .smart: "Smart search"
            }
        }
    }

    /// 资源类型；all 不向服务器发送类型限制。
    public enum Media: String, CaseIterable, Sendable { case all, image, video }

    public var text = ""
    /// 服务端参考图的UUID v4；必须在smart模式与非空text二选一，始终走完整Fork协议。
    public var queryAssetID: String?
    public var mode: Mode = .fileName
    public var media: Media = .all
    public var mediaCategory: ImmichSearchMediaCategory?
    public var resolution: ImmichSearchResolution?
    public var panoramasOnly = false
    public var country = ""
    public var state = ""
    /// 收藏关闭表示不限制；归档关闭保留既有timeline范围，不包含锁定内容。
    public var favoritesOnly = false
    public var archivedOnly = false
    public var rating: ImmichSearchRating = .any
    public var city = ""
    public var cameraMake = ""
    public var cameraModel = ""
    public var lensModel = ""
    public var tags: ImmichSearchTagFilter = .any
    /// 横竖构图来自Fork扩展；未选择则不限制。
    public enum Orientation: String, Sendable { case landscape, portrait }
    public var orientation: Orientation?
    public var hasAlbums: Bool?
    public var exifConditions: [ImmichSearchNumericCondition] = []
    public var personIDs: [String] = []
    /// 日期代表用户所选日历日；序列化时保留该日墙上时间，不能直接使用绝对UTC日界线。
    public var takenAfter: Date?
    public var takenBefore: Date?
    public var timeZone = TimeZone.current

    /// 创建空条件；调用方按用户选择修改值，不自动读取设备照片。
    public init() {}

    /// 参考图始终走完整Fork协议；其他旧式smart无法完整表达的组合也走独立Fork分页。
    public var requiresForkSmartSearch: Bool {
        guard mode == .smart else { return false }
        if queryAssetID != nil {
            return true
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !exifConditions.isEmpty || orientation != nil || hasAlbums != nil || rating == .stars(0)
            || mediaCategory != nil || resolution != nil || panoramasOnly || tags != .any
    }

    /// date为用户日历日，endOfDay选择当日末毫秒；返回用UTC编码的本地墙上时间。
    /// 与服务端/Web的asLocalTimeISO一致；无法表示的日期抛invalidResponse。
    func captureBoundary(_ date: Date, endOfDay: Bool) throws -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let components = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = utc.date(from: components), let next = utc.date(byAdding: .day, value: 1, to: start) else {
            throw ImmichAPIError.invalidResponse
        }
        return endOfDay ? next.addingTimeInterval(-0.001) : start
    }
}

/// Fork按元数据识别的媒体来源类别；与照片/视频类型条件独立，未选时不增加限制。
public enum ImmichSearchMediaCategory: String, CaseIterable, Sendable {
    case phoneVideo = "phone-video", screenshot, deltaScreenshot = "delta-screenshot"
    case steamScreenshot = "steam-screenshot", switchScreenshot = "switch-screenshot", nintendo3dsScreenshot = "3ds-screenshot"
}

/// Fork定义的分辨率档位；仅转发服务端档位，不在客户端按像素猜测归类。
public enum ImmichSearchResolution: String, CaseIterable, Sendable {
    case hd = "720p", fullHD = "1080p", twoK = "2k", fourK = "4k"
}

/// 标签条件区分不限制、无标签和任一所选标签（含后代）；ID数组须非空且最多100项。
public enum ImmichSearchTagFilter: Hashable, Sendable {
    case any, untagged, anyOf([String])
}

/// 官方账号标签候选，仅保留搜索选择需要的身份和完整层级名称，不提供写入能力。
public struct ImmichSearchTag: Hashable, Sendable {
    public let id: String
    public let value: String
}

/// 不限制、未评分和具体评分不能共用一个Optional；0保留为合法的结构化查询值。
public enum ImmichSearchRating: Hashable, Sendable {
    case any, unrated, stars(Int)
}

/// SDK边界的EXIF原子条件；相同字段/运算符不得重复，值必须有限且非负。
public struct ImmichSearchNumericCondition: Hashable, Sendable {
    public enum Field: String, Sendable { case iso, fNumber, focalLength, exposureTime }
    public enum Comparison: String, Sendable { case equal = "eq", greaterThan = "gt", atLeast = "gte", lessThan = "lt", atMost = "lte" }
    public let field: Field
    public let comparison: Comparison
    public let value: Double

    /// field/comparison指定一个原子槽位；value中快门使用秒，焦距使用毫米。
    public init(field: Field, comparison: Comparison, value: Double) {
        self.field = field
        self.comparison = comparison
        self.value = value
    }
}

/// metadata游标、旧smart页码和Fork绑定游标不可互换；调用方不解析或构造offset。
public enum ImmichSearchContinuation: Hashable, Sendable {
    case cursor(String)
    case page(Int)
    case forkCursor(String)
}

/// 任一搜索模式的实际结果页，不承诺全局总命中数。
public struct ImmichSearchPage: Sendable {
    public let assets: [ImmichTimelineAsset]
    public let continuation: ImmichSearchContinuation?
}

/// 一页实际搜索资源；nextCursor 必须原样传回，不是页码或总数量。
public struct ImmichMetadataSearchPage: Sendable {
    public let assets: [ImmichTimelineAsset]
    public let nextCursor: String?
}
