import Foundation
import HTTPTypes
import OpenAPIRuntime

struct AuthenticationMiddleware: ClientMiddleware {
    let credential: ImmichCredential?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try ReadOnlyOperationPolicy.validate(request: request, operationID: operationID)

        var request = request
        switch credential {
        case let .bearer(token):
            request.headerFields[.authorization] = "Bearer \(token)"
        case let .apiKey(key):
            request.headerFields[HTTPField.Name("x-api-key")!] = key
        case nil:
            break
        }
        return try await next(request, body, baseURL)
    }
}

/// SDK读取边界；会话操作沿用原许可，随机与Fork只读POST额外绑定精确路径/方法。
enum ReadOnlyOperationPolicy {
    /// 元数据/智能搜索因JSON条件使用POST，但只读取服务器资源；真正写入仍拒绝。
    private static let allowedNonReadOperations: Set<String> = ["login", "logout", "searchAssets", "searchSmart"]

    /// request为待发送请求，operationID为固定操作身份；不匹配读取契约时抛策略错误。
    static func validate(request: HTTPRequest, operationID: String) throws {
        // 随机抽样是独立只读POST，不能仅以操作名放行其他路径或方法。
        if operationID == "searchRandom" {
            guard request.method == .post, request.path == "/search/random" else {
                throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
            }
            return
        }
        // 手写Fork请求不能仅凭操作ID放行：必须同时固定方法与精确只读路径。
        if operationID == "forkSearchSmart" {
            guard request.method == .post, request.path == "/fork/search/smart" else {
                throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
            }
            return
        }
        let readMethods: Set<HTTPRequest.Method> = [.get, .head, .options]
        guard readMethods.contains(request.method) || allowedNonReadOperations.contains(operationID) else {
            throw ImmichAPIError.readOnlyPolicyViolation(operationID: operationID)
        }
    }
}
