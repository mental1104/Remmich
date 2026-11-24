import Foundation

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
    public var mode: Mode = .fileName
    public var media: Media = .all
    public var city = ""
    public var cameraMake = ""
    public var cameraModel = ""
    public var personIDs: [String] = []
    /// 日期代表用户所选日历日；序列化时保留该日墙上时间，不能直接使用绝对UTC日界线。
    public var takenAfter: Date?
    public var takenBefore: Date?
    public var timeZone = TimeZone.current

    /// 创建空条件；调用方按用户选择修改值，不自动读取设备照片。
    public init() {}

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

/// metadata不透明游标与smart数字页码不可互换；调用方不得自行构造offset。
public enum ImmichSearchContinuation: Hashable, Sendable {
    case cursor(String)
    case page(Int)
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
