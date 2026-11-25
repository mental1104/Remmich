import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// 保留SDK请求构造：索引GET交持久队列，明确允许的只读搜索/场景POST交可取消的前台网络层。
public struct ImmichQueuedReadTransport: ClientTransport {
    public typealias Loader = @Sendable (URLRequest, String) async throws -> (Data, HTTPURLResponse)
    private let loader: Loader
    private let searchTransport: any ClientTransport
    private let sceneStackLoader: Loader?

    /// loader提供GET响应；searchTransport可注入测试，默认禁止重定向、不缓存搜索响应。
    /// sceneStackLoader仅替换精确scene POST的HTTP字节来源，nil不改变生产前台网络，不能处理其他POST或写路径。
    public init(searchTransport: (any ClientTransport)? = nil, sceneStackLoader: Loader? = nil, loader: @escaping Loader) {
        self.loader = loader
        self.searchTransport = searchTransport ?? ImmichSearchNetwork.transport
        self.sceneStackLoader = sceneStackLoader
    }

    /// request/body来自生成SDK，baseURL为验证过的API根，operationID必须匹配只读路由。
    /// 返回HTTP状态/字节；取消原样传播，非法方法或路由在调用loader前拒绝。
    public func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        try Task.checkCancellation()
        // 不放行任意POST：操作ID、方法、相对路径和请求体必须同时满足只读搜索契约。
        let isMetadata = operationID == "searchAssets" && request.path == "/search/metadata"
        let isSmart = operationID == "searchSmart" && request.path == "/search/smart"
        let isForkSmart = operationID == "forkSearchSmart" && request.path == "/fork/search/smart"
        let isRandom = operationID == "searchRandom" && request.path == "/search/random"
        let isScene = operationID == "forkSceneStacksQuery" && request.path == "/fork/scene-stacks/query"
        if request.method == .post, isScene, let body, let sceneStackLoader {
            // 仅隔离测试的scene字节来源走此窄口；生产仍用已有不缓存/禁重定向的前台会话。
            let data = try await Data(collecting: body, upTo: 256 * 1024)
            return try await load(request, body: data, baseURL: baseURL, operationID: operationID, using: sceneStackLoader)
        }
        if request.method == .post, isMetadata || isSmart || isForkSmart || isRandom || isScene, body != nil {
            return try await searchTransport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        guard request.method == .get, body == nil else { throw ImmichAPIError.invalidResponse }
        return try await load(request, body: nil, baseURL: baseURL, operationID: operationID, using: loader)
    }

    /// request/baseURL为认证中间件输出；body只来自上述scene专用POST或GET nil，using不替换业务验证。
    /// 保留原API前缀、全部头与真实JSON，返回原始状态/字节给SDK，不进入持久队列或自动重放。
    private func load(_ request: HTTPRequest, body: Data?, baseURL: URL, operationID: String, using loader: Loader) async throws -> (HTTPResponse, HTTPBody?) {
        try Task.checkCancellation()
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let path = URLComponents(string: request.path ?? "") else { throw ImmichAPIError.invalidResponse }
        components.percentEncodedPath += path.percentEncodedPath
        components.percentEncodedQuery = path.percentEncodedQuery
        guard let url = components.url else { throw ImmichAPIError.invalidResponse }
        var nativeRequest = URLRequest(url: url)
        nativeRequest.httpMethod = request.method.rawValue
        nativeRequest.httpBody = body
        for field in request.headerFields {
            nativeRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        let (data, response) = try await loader(nativeRequest, operationID)
        try Task.checkCancellation()
        guard (100 ... 599).contains(response.statusCode) else { throw ImmichAPIError.invalidResponse }
        var result = HTTPResponse(status: .init(code: response.statusCode))
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            result.headerFields[.contentType] = contentType
        }
        return (result, HTTPBody(data, length: .known(Int64(data.count)), iterationBehavior: .multiple))
    }
}

/// 保持已有调用方源码兼容；新调用方使用能准确表达只读POST的名称。
public typealias ImmichQueuedGETTransport = ImmichQueuedReadTransport

/// 交互搜索不进入仅保存URL的持久日志，取消会终止前台数据任务。
enum ImmichSearchNetwork {
    static let transport: any ClientTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        return URLSessionTransport(configuration: .init(session: session))
    }()

    /// 不允许搜索请求携带凭据或条件跟随重定向。
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        /// response和request表示重定向目标；completionHandler固定nil以保留原服务端边界。
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }
}
