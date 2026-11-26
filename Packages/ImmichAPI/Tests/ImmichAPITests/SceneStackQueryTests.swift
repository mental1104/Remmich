import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ImmichAPI

/// 场景专用SDK/中间件/传输真实请求字节；本地HTTP响应来源不访问任何服务器。
struct SceneStackQueryTests {
    /// 精确POST201、前缀、Bearer、no-store与ids数组；不能将其当作smart200或索引GET。
    @Test func sendsTheExactReadOnlyPost() async throws {
        let captured = SceneSDKCapture(status: 201)
        let client = sceneSDKClient(captured)
        let result = try await client.sceneStackGroups(assetIDs: [sceneSDKA, sceneSDKB])
        #expect(result.available && result.groups.isEmpty)
        let requests = await captured.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://example.invalid/prefix/api/fork/scene-stacks/query")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? NSDictionary
        #expect(json?.isEqual(to: ["ids": [sceneSDKA, sceneSDKB]]) == true)
    }

    /// 成功只接受201；其他状态保持失败且无自动重放，不将401/403/坏2xx包为空可用组。
    @Test(arguments: [200, 204, 401, 403, 404, 405, 429, 500, 501])
    func rejectsOtherStatusesWithoutReplay(_ status: Int) async throws {
        let captured = SceneSDKCapture(status: status)
        do { _ = try await sceneSDKClient(captured).sceneStackGroups(assetIDs: [sceneSDKA]); Issue.record("Only HTTP201 may succeed") }
        catch {}
        #expect(await captured.requests.count == 1)
    }

    /// 空/重复/非法或超5000范围必须在传输前拒绝；空ids不是ready能力探针。
    @Test(arguments: ["empty", "duplicate", "invalid", "too-many"])
    func rejectsInvalidRequestsBeforeNetwork(_ mode: String) async {
        let ids: [String] = switch mode {
        case "empty": []
        case "duplicate": [sceneSDKA, sceneSDKA.uppercased()]
        case "invalid": ["not-a-uuid"]
        default: (0 ..< 5001).map { index in
                let suffix = String(index + 1, radix: 16)
                return "77777777-7777-4777-8777-" + String(repeating: "0", count: 12 - suffix.count) + suffix
            }
        }
        let captured = SceneSDKCapture(status: 201)
        await #expect(throws: ImmichAPIError.invalidResponse) { _ = try await sceneSDKClient(captured).sceneStackGroups(assetIDs: ids) }
        #expect(await captured.requests.isEmpty)
    }

    /// 新operation仅准精确scene POST，不能借其身份读取其他地址或执行DELETE/PUT。
    @Test(arguments: ["GET", "PUT", "DELETE", "wrong-path"])
    func policyRejectsWrongMethodOrPath(_ mode: String) {
        let method: HTTPRequest.Method = switch mode { case "GET": .get; case "PUT": .put; case "DELETE": .delete; default: .post }
        let request = HTTPRequest(method: method, scheme: nil, authority: nil,
                                  path: mode == "wrong-path" ? "/assets" : "/fork/scene-stacks/query")
        #expect(throws: ImmichAPIError.readOnlyPolicyViolation(operationID: "forkSceneStacksQuery")) {
            try ReadOnlyOperationPolicy.validate(request: request, operationID: "forkSceneStacksQuery")
        }
    }

    /// available=false必须没有groups，损坏JSON或缺required字段也不能变成空成功。
    @Test(arguments: [#"{"available":false,"groups":[{"id":"x","coverId":"x","members":[]}] }"#, #"{"groups":[]}"#, "not-json"])
    func rejectsMalformedReplies(_ json: String) async throws {
        let captured = SceneSDKCapture(status: 201, json: json)
        do { _ = try await sceneSDKClient(captured).sceneStackGroups(assetIDs: [sceneSDKA]); Issue.record("Malformed reply must fail") }
        catch {}
        #expect(await captured.requests.count == 1)
    }
}

/// 合成UUID只用于协议字节，不对应真实照片。
private let sceneSDKA = "11111111-1111-4111-8111-111111111111"
private let sceneSDKB = "22222222-2222-4222-8222-222222222222"

/// capture提供唯一精确scene loader；GET或其他前台误路由直接失败，任何断言失败也不访问真实网络。
private func sceneSDKClient(_ capture: SceneSDKCapture) -> ImmichClient {
    ImmichClient(apiURL: URL(string: "https://example.invalid/prefix/api")!, credential: .bearer("synthetic"),
                 transport: ImmichQueuedReadTransport(searchTransport: SceneSDKNeverSendTransport(), sceneStackLoader: { request, operation in
                     #expect(operation == "forkSceneStacksQuery")
                     return try await capture.response(request)
                 }, loader: { _, _ in throw ImmichAPIError.invalidResponse }))
}

/// 精确scene loader以外的所有前台传输都失败，避免路由回归时悄悄发出外部请求。
private struct SceneSDKNeverSendTransport: ClientTransport {
    /// 所有输入仅供识别越界；记录实际误路由后抛错，不创建URLSession或网络任务。
    func send(_: HTTPRequest, body _: HTTPBody?, baseURL _: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("Scene fixture must use only its exact isolated loader")
        throw ImmichAPIError.invalidResponse
    }
}

/// 保存实际URLRequest并返回有限原始响应，不替代SDK正文/鉴权/状态验证逻辑。
private actor SceneSDKCapture {
    let status: Int
    let json: String
    private(set) var requests: [URLRequest] = []
    /// status/json是独立HTTP证据输入；缺省为合法无组响应。
    init(status: Int, json: String = #"{"available":true,"groups":[]}"#) {
        self.status = status; self.json = json
    }

    /// request为SDK中间件与transport输出的真实字节，返回相同URL对应HTTP响应。
    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(json.utf8), response)
    }
}
