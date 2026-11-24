import Foundation

/// 界面允许加载的账号内候选，不暴露SDK枚举。
nonisolated enum NativeSearchSuggestionKind: String, Sendable {
    case city
    case cameraMake = "camera-make"
    case cameraModel = "camera-model"
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
    var mode: Mode = .fileName
    var media: Media = .all
    var city = ""
    var cameraMake = ""
    var cameraModel = ""
    var personIDs: [String] = []
    var takenAfter: Date?
    var takenBefore: Date?
    var timeZone = TimeZone.current
}

/// 领域层区分不透明令牌与页码，避免Feature依赖SDK分页类型。
nonisolated enum NativeSearchContinuation: Hashable, Sendable {
    case cursor(String)
    case page(Int)
}

/// 可安全展示的搜索错误，不携带URL、token或服务器原始响应体。
nonisolated enum NativeSearchError: Error, LocalizedError, Sendable {
    case unauthorized, forbidden, invalidQuery, invalidResponse, rateLimited, unavailable

    /// 按可恢复动作区分鉴权、权限、条件、格式及网络失败。
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session is no longer authorized. Sign in again."
        case .forbidden: "This account does not have permission to search these resources."
        case .invalidQuery: "The server rejected these search conditions. Check filters and server version."
        case .invalidResponse: "The search response could not be understood."
        case .rateLimited: "Too many requests. Try again shortly."
        case .unavailable: "Search could not be loaded. Check connection and server version."
        }
    }
}
