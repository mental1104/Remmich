import Foundation

/// 不连接真实图库；覆盖路径、请求体、权限错误、查重和编辑契约。
final class ContractProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable { let status: Int; let body: String }
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Stub)?

    static func install(_ value: @escaping @Sendable (URLRequest) throws -> Stub) {
        lock.lock(); defer { lock.unlock() }
        handler = value
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let stub = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@main
struct ForkContractChecks {
    static let assetID = "11111111-1111-4111-8111-111111111111"
    static let albumID = "22222222-2222-4222-8222-222222222222"

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let existing = request.httpBody {
            data = existing
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw LibraryWriteError.malformedResponse }
                if count == 0 {
                    break
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else {
            data = Data("{}".utf8)
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractProtocol.self]
        let client = LibraryMutationClient(apiURL: URL(string: "https://fixture.invalid/api")!, token: "fixture-token", userID: assetID, configuration: config)
        defer { client.cancel() }
        ContractProtocol.install { request in
            precondition(request.httpMethod == "DELETE" && request.url!.path == "/api/assets")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let payload = try body(request)
            precondition(payload["force"] as? Bool == false)
            precondition(payload["ids"] as? [String] == [assetID])
            return .init(status: 204, body: "")
        }
        try await client.trash(assetID)
        print("PASS: trash uses official route, current credentials and force=false")

        ContractProtocol.install { _ in preconditionFailure("Invalid IDs must not send a request") }
        do { try await client.trash("../outside"); preconditionFailure("Invalid ID accepted") }
        catch LibraryWriteError.invalidID {}
        print("PASS: invalid/path-injection ID rejected before network")

        ContractProtocol.install { request in
            let payload = try body(request)
            precondition(request.httpMethod == "PUT" && request.url!.path == "/api/assets/\(assetID)")
            precondition(payload["isFavorite"] as? Bool == true)
            precondition(payload["visibility"] == nil && payload["description"] == nil)
            return .init(status: 403, body: "{\"message\":\"private server detail\"}")
        }
        do { try await client.update(assetID, favorite: true); preconditionFailure("403 treated as success") }
        catch LibraryWriteError.http(403) {}
        print("PASS: field-scoped update and permission denial surfaced")

        ContractProtocol.install { request in
            precondition(request.httpMethod == "PUT" && request.url!.path == "/api/albums/\(albumID)/assets")
            let payload = try body(request)
            precondition(payload["ids"] as? [String] == [assetID])
            return .init(status: 200, body: "[{\"success\":false}]")
        }
        do { try await client.add(assetID, to: albumID); preconditionFailure("Partial failure accepted") }
        catch LibraryWriteError.malformedResponse {}
        print("PASS: per-asset album failure is not reported as success")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let checksum = try LibraryMutationClient.checksum(file)
        precondition(checksum == "a9993e364706816aba3e25717850c26c9cd0d89d")
        for trashed in [false, true] {
            ContractProtocol.install { request in
                precondition(request.httpMethod == "POST" && request.url!.path == "/api/assets/bulk-upload-check")
                let assets = try body(request)["assets"] as! [[String: String]]
                precondition(assets[0]["checksum"] == "a9993e364706816aba3e25717850c26c9cd0d89d")
                return .init(status: 200, body: "{\"results\":[{\"id\":\"\(assets[0]["id"]!)\",\"action\":\"reject\",\"assetId\":\"\(assetID)\",\"isTrashed\":\(trashed)}]}")
            }
            do {
                let uploaded = try await client.upload(file: file, filename: "abc.jpg", created: .now, modified: .now, favorite: false)
                precondition(!trashed && uploaded.status == "duplicate" && uploaded.id == assetID)
            } catch LibraryWriteError.trashedDuplicate { precondition(trashed) }
        }
        print("PASS: streaming SHA1, duplicate skip and trashed-duplicate rejection")

        ContractProtocol.install { request in
            if request.url!.path == "/api/assets/bulk-upload-check" {
                let assets = try body(request)["assets"] as! [[String: String]]
                return .init(status: 200, body: "{\"results\":[{\"id\":\"\(assets[0]["id"]!)\",\"action\":\"accept\"}]}")
            }
            precondition(request.httpMethod == "POST" && request.url!.path == "/api/assets")
            precondition(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Remmich-") == true)
            precondition(request.value(forHTTPHeaderField: "x-immich-checksum") == "a9993e364706816aba3e25717850c26c9cd0d89d")
            return .init(status: 201, body: "{\"id\":\"\(assetID)\",\"status\":\"created\"}")
        }
        let created = try await client.upload(file: file, filename: "unsafe\"\r\nname.jpg", created: .now, modified: .now, favorite: true)
        precondition(created.status == "created")
        print("PASS: accepted original streams through the authenticated multipart upload route")

        ContractProtocol.install { request in
            let payload = try body(request)
            precondition(request.httpMethod == "PUT" && request.url!.path == "/api/assets/\(assetID)/edits")
            let edits = payload["edits"] as! [[String: Any]]
            precondition(edits[0]["action"] as? String == "crop" && edits[1]["action"] as? String == "rotate")
            return .init(status: 200, body: "{}")
        }
        try await client.saveEdits(assetID, .init(edits: [.init(action: "crop", parameters: .init(x: 0, y: 0, width: 10, height: 10)),
                                                          .init(action: "rotate", parameters: .init(angle: 90))]))
        print("PASS: non-destructive edits use official crop-first schema")

        let state = try JSONDecoder().decode(ForkAlbumDirectory.State.self, from: Data(#"{"categories":[{"id":"c","name":"Trips"}],"groups":[{"groupName":"Paris","categoryId":"c"}]}"#.utf8))
        let albums = try JSONDecoder().decode([ForkAlbumDirectory.Album].self, from: Data(#"[{"id":"a","customGroupName":" Paris "},{"id":"b"}]"#.utf8))
        let directory = ForkAlbumDirectory(state: state, albums: albums)
        precondition(directory.includes(albumID: "a", category: "c", group: "Paris"))
        precondition(!directory.includes(albumID: "a", category: "wrong", group: nil))
        precondition(directory.includes(albumID: "b", category: ForkAlbumDirectory.defaultCategory, group: ""))
        precondition(directory.searchText(albumID: "a") == "Trips Paris")
        print("PASS: fork category intersection, whitespace and default category")
        print("All offline contract checks passed; no production network requests were made.")
    }
}
