import CryptoKit
import Foundation

nonisolated enum LibraryWriteError: LocalizedError {
    case invalidID, unavailable, changedAccount, busy, malformedResponse, trashedDuplicate
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidID: "无效的资源标识。"
        case .unavailable: "请先连接服务器。"
        case .changedAccount: "账户或连接已变更，请重新操作。"
        case .busy: "请等待当前操作完成。"
        case .malformedResponse: "服务器返回的数据不符合约定，未确认操作成功。"
        case .trashedDuplicate: "服务器回收站中已有此文件，请先决定是否恢复；未标记为备份成功。"
        case let .http(code): "服务器返回 HTTP \(code)。请检查权限、版本和连接；不自动重试写操作。"
        }
    }
}

nonisolated struct ManagedAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let isFavorite: Bool
    let visibility: String
    let isTrashed: Bool
    let type: String
    let originalFileName: String
    let livePhotoVideoId: String?
    let exifInfo: Exif?

    struct Exif: Decodable, Sendable {
        let description: String?
        let exifImageWidth: Int?
        let exifImageHeight: Int?
    }
}

nonisolated struct ManagedAlbum: Decodable, Identifiable, Sendable {
    let id: String
    let albumName: String
    let ownerId: String
}

nonisolated struct AssetEditList: Codable, Sendable {
    var edits: [Edit]

    struct Edit: Codable, Sendable, Equatable {
        let action: String
        let parameters: Parameters
    }

    struct Parameters: Codable, Sendable, Equatable {
        var x: Int? = nil
        var y: Int? = nil
        var width: Int? = nil
        var height: Int? = nil
        var angle: Int? = nil
        var axis: String? = nil
    }
}

/// 独立写入通道只暴露明确的官方操作；浏览 SDK 的只读保护继续保留。
final nonisolated class LibraryMutationClient: Sendable {
    let apiURL: URL
    let userID: String
    private let token: String
    private let session: URLSession

    final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    init(apiURL: URL, token: String, userID: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiURL = apiURL
        self.token = token
        self.userID = userID
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    private func validID(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw LibraryWriteError.invalidID }
        return value
    }

    private func request(_ method: String, _ components: [String]) throws -> URLRequest {
        try Task.checkCancellation()
        guard ["https", "http"].contains(apiURL.scheme), apiURL.host != nil,
              apiURL.user == nil, apiURL.password == nil, apiURL.query == nil, apiURL.fragment == nil,
              !token.contains("\r"), !token.contains("\n") else { throw LibraryWriteError.unavailable }
        var request = URLRequest(url: components.reduce(apiURL) { $0.appendingPathComponent($1) })
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LibraryWriteError.malformedResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw LibraryWriteError.http(response.statusCode) }
        return data
    }

    private func send(_ method: String, _ path: [String], body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        var request = try request(method, path)
        if !query.isEmpty {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            request.url = components.url
        }
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return try checked(data, response)
    }

    func asset(_ id: String) async throws -> ManagedAsset {
        try await JSONDecoder().decode(ManagedAsset.self, from: send("GET", ["assets", validID(id)]))
    }

    func albums(containing assetID: String? = nil) async throws -> [ManagedAlbum] {
        let query = try assetID.map { try [URLQueryItem(name: "assetId", value: validID($0))] } ?? []
        return try await JSONDecoder().decode([ManagedAlbum].self, from: send("GET", ["albums"], query: query))
    }

    func edits(_ id: String) async throws -> AssetEditList {
        try await JSONDecoder().decode(AssetEditList.self, from: send("GET", ["assets", validID(id), "edits"]))
    }

    func update(_ id: String, favorite: Bool? = nil, visibility: String? = nil, description: String? = nil) async throws {
        struct Update: Encodable { let isFavorite: Bool?; let visibility: String?; let description: String? }
        let body = try JSONEncoder().encode(Update(isFavorite: favorite, visibility: visibility, description: description))
        _ = try await send("PUT", ["assets", validID(id)], body: body)
    }

    func trash(_ id: String) async throws {
        struct Body: Encodable { let ids: [String]; let force = false }
        _ = try await send("DELETE", ["assets"], body: JSONEncoder().encode(Body(ids: [validID(id)])))
    }

    func restore(_ id: String) async throws {
        struct Body: Encodable { let ids: [String] }
        _ = try await send("POST", ["trash", "restore", "assets"], body: JSONEncoder().encode(Body(ids: [validID(id)])))
    }

    func saveEdits(_ id: String, _ edits: AssetEditList) async throws {
        _ = try await send("PUT", ["assets", validID(id), "edits"], body: JSONEncoder().encode(edits))
    }

    func resetEdits(_ id: String) async throws {
        _ = try await send("DELETE", ["assets", validID(id), "edits"])
    }

    func createAlbum(name: String, assetID: String? = nil) async throws -> ManagedAlbum {
        struct Body: Encodable { let albumName: String; let assetIds: [String] }
        let body = try JSONEncoder().encode(Body(albumName: name, assetIds: assetID.map { try [validID($0)] } ?? []))
        return try await JSONDecoder().decode(ManagedAlbum.self, from: send("POST", ["albums"], body: body))
    }

    func renameAlbum(_ id: String, name: String) async throws {
        struct Body: Encodable { let albumName: String }
        _ = try await send("PUT", ["albums", validID(id)], body: JSONEncoder().encode(Body(albumName: name)))
    }

    func deleteAlbum(_ id: String) async throws {
        _ = try await send("DELETE", ["albums", validID(id)])
    }

    func remove(_ assetID: String, from albumID: String) async throws {
        struct Body: Encodable { let ids: [String] }
        struct Result: Decodable { let success: Bool }
        let data = try await send("DELETE", ["albums", validID(albumID), "assets"], body: JSONEncoder().encode(Body(ids: [validID(assetID)])))
        let results = try JSONDecoder().decode([Result].self, from: data)
        guard results.count == 1, results.allSatisfy(\.success) else { throw LibraryWriteError.malformedResponse }
    }

    func add(_ assetID: String, to albumID: String) async throws {
        struct Body: Encodable { let ids: [String] }
        struct Result: Decodable { let success: Bool }
        let data = try await send("PUT", ["albums", validID(albumID), "assets"], body: JSONEncoder().encode(Body(ids: [validID(assetID)])))
        let results = try JSONDecoder().decode([Result].self, from: data)
        guard results.count == 1, results.allSatisfy(\.success) else { throw LibraryWriteError.malformedResponse }
    }

    struct UploadResult: Decodable, Sendable { let id: String; let status: String }

    /// 流式计算校验和、先查重、再从磁盘上传；绝不把大视频整体读入内存。
    @concurrent func upload(file: URL, filename: String, created: Date, modified: Date,
                            favorite: Bool, hidden: Bool = false, livePhotoVideoID: String? = nil) async throws -> UploadResult
    {
        let checksum = try Self.checksum(file)
        struct Check: Encodable { let assets: [Item]; struct Item: Encodable { let id: String; let checksum: String } }
        struct Checks: Decodable {
            let results: [Item]
            struct Item: Decodable { let id: String; let action: String; let assetId: String?; let isTrashed: Bool? }
        }
        let key = UUID().uuidString
        let checkBody = try JSONEncoder().encode(Check(assets: [.init(id: key, checksum: checksum)]))
        let check = try await JSONDecoder().decode(Checks.self, from: send("POST", ["assets", "bulk-upload-check"], body: checkBody))
        guard check.results.count == 1, let result = check.results.first, result.id == key else { throw LibraryWriteError.malformedResponse }
        if result.action == "reject" {
            guard result.isTrashed != true else { throw LibraryWriteError.trashedDuplicate }
            guard let id = result.assetId else { throw LibraryWriteError.malformedResponse }
            return try UploadResult(id: validID(id), status: "duplicate")
        }
        guard result.action == "accept" else { throw LibraryWriteError.malformedResponse }
        let boundary = "Remmich-\(UUID().uuidString)"
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        FileManager.default.createFile(atPath: bodyFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyFile)
        defer { try? output.close() }
        func write(_ value: String) throws {
            try output.write(contentsOf: Data(value.utf8))
        }
        var fields = ["fileCreatedAt": created.ISO8601Format(), "fileModifiedAt": modified.ISO8601Format(), "isFavorite": String(favorite)]
        if hidden {
            fields["visibility"] = "hidden"
        }
        if let livePhotoVideoID {
            fields["livePhotoVideoId"] = try validID(livePhotoVideoID)
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        // 原始名称可能带引号或换行，必须清理以避免 multipart 头注入。
        let safeName = filename.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\\", with: "_")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try output.synchronize()
        var request = try request("POST", ["assets"])
        request.timeoutInterval = 3600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        let uploaded = try JSONDecoder().decode(UploadResult.self, from: checked(data, response))
        _ = try validID(uploaded.id)
        guard ["created", "duplicate"].contains(uploaded.status) else { throw LibraryWriteError.malformedResponse }
        return uploaded
    }

    static func checksum(_ file: URL) throws -> String {
        var hash = Insecure.SHA1()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
