import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 使用官方GET形状验证可写编辑文档的完整性；未知内容不能被读取后无声覆盖。
@Suite("Lossless asset edit documents")
struct AssetEditDocumentTests {
    /// 三种官方操作保持原顺序及参数；GET元数据不能进入PUT请求。
    @Test func roundTripRetainsOrderedOperationsWithoutResponseMetadata() throws {
        let data = Data(#"{"assetId":"ac34f7ab-2c20-4c6a-8774-cb6a18bb6d88","edits":[{"id":"d88e84f6-384f-40bc-89ae-848af26a174a","action":"rotate","parameters":{"angle":90}},{"id":"91569698-0d03-426e-9226-a3cc79bb0313","action":"mirror","parameters":{"axis":"vertical"}},{"id":"55b7eb26-9481-40d9-bec8-dd90e76c72c2","action":"crop","parameters":{"x":1,"y":2,"width":30,"height":40}}]}"#.utf8)
        let receipt = try JSONDecoder().decode(AssetEditReceipt.self, from: data)
        #expect(receipt.document.edits.map(\.action) == ["rotate", "mirror", "crop"])
        #expect(receipt.document.edits.last?.parameters == .init(x: 1, y: 2, width: 30, height: 40))
        let encoded = try JSONEncoder().encode(receipt.document)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["edits"])
        let rows = try #require(object["edits"] as? [[String: Any]])
        #expect(rows.allSatisfy { Set($0.keys) == ["action", "parameters"] })
        #expect(try JSONDecoder().decode(AssetEditList.self, from: encoded).edits == receipt.document.edits)
    }

    /// 每个future文档代表本版本不能完整表达的服务端行为，均必须阻止编辑而非静默删字段。
    @Test(arguments: [
        #"{"edits":[],"futureVersion":2}"#,
        #"{"edits":[{"action":"rotate","parameters":{"angle":90},"blend":"future"}]}"#,
        #"{"edits":[{"action":"rotate","parameters":{"angle":90,"interpolation":"future"}}]}"#,
        #"{"edits":[{"action":"future","parameters":{"angle":90}}]}"#,
    ])
    func rejectsFutureBehavior(_ future: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AssetEditList.self, from: Data(future.utf8)) }
    }

    /// 真实URLSession客户端必须核对响应照片身份；HTTP200本身不能授权覆盖另一张照片的编辑。
    @Test func mismatchedResponseIdentityIsRejectedAtReadBoundary() async throws {
        let assetID = UUID()
        let url = try #require(URL(string: "https://edits-\(assetID.uuidString).example.invalid/api"))
        let endpoint = url.appending(path: "assets/\(assetID.uuidString)/edits")
        EditReceiptURLProtocol.responses.withLock { $0[endpoint] = Data("{\"assetId\":\"\(UUID())\",\"edits\":[]}".utf8) }
        defer { EditReceiptURLProtocol.responses.withLock { $0.removeValue(forKey: endpoint) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditReceiptURLProtocol.self]
        let client = LibraryMutationClient(apiURL: url, token: "synthetic", userID: "synthetic", configuration: configuration)
        defer { client.cancel() }
        await #expect(throws: LibraryWriteError.self) { try await client.edits(assetID.uuidString) }
    }
}

/// 同步提供隔离的合成HTTP200；按唯一URL映射响应，测试并行时不共享照片身份。
private final nonisolated class EditReceiptURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Mutex<[URL: Data]>([:])
    /// request只在本测试已登记URL时拦截，不能访问真实网络。
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return responses.withLock { $0[url] != nil }
    }

    /// request不改写，便于真实客户端保留URL及鉴权语义。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 向URLSession返回登记字节；无映射时显式失败，绝不回退外网。
    override func startLoading() {
        guard let url = request.url, let body = Self.responses.withLock({ $0[url] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// 同步fixture没有待执行任务，取消不产生额外回调。
    override func stopLoading() {}
}
