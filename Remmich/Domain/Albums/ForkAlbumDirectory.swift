import Foundation

/// Fork目录独立于官方DTO；未启用扩展的服务器继续使用标准相簿列表。
nonisolated struct ForkAlbumDirectory: Sendable {
    struct Category: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    struct Group: Decodable, Sendable {
        let groupName: String
        let categoryId: String
    }

    struct State: Decodable, Sendable {
        let categories: [Category]
        let groups: [Group]
    }

    struct Album: Decodable, Sendable {
        let id: String
        let customGroupName: String?
    }

    static let defaultCategory = "__default__"
    let categories: [Category]
    private let albumGroups: [String: String]
    private let groupCategories: [String: String]

    init(state: State, albums: [Album]) {
        categories = state.categories
        albumGroups = Dictionary(albums.map { ($0.id, ($0.customGroupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }, uniquingKeysWith: { first, _ in first })
        groupCategories = Dictionary(state.groups.map { ($0.groupName, $0.categoryId) }, uniquingKeysWith: { first, _ in first })
    }

    var groupNames: [String] {
        Set(albumGroups.values).sorted()
    }

    func includes(albumID: String, category: String?, group: String?) -> Bool {
        let name = albumGroups[albumID] ?? ""
        let categoryID = groupCategories[name] ?? Self.defaultCategory
        return (category == nil || category == categoryID) && (group == nil || group == name)
    }

    func searchText(albumID: String) -> String {
        let group = albumGroups[albumID] ?? ""
        let category = categories.first { $0.id == groupCategories[group] }?.name ?? "默认"
        return "\(category) \(group)"
    }
}

/// 仅发送GET，不写服务器；鉴权失败与功能不支持必须区分，且禁止跨站重定向携带凭据。
nonisolated struct ForkServerReader: Sendable {
    let apiURL: URL
    let token: String

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    func albumDirectory() async throws -> ForkAlbumDirectory? {
        guard let stateData = try await get("fork/album-categories", optional: true) else { return nil }
        let state = try JSONDecoder().decode(ForkAlbumDirectory.State.self, from: stateData)
        guard let albumData = try await get("albums", optional: false) else { return nil }
        let albums = try JSONDecoder().decode([ForkAlbumDirectory.Album].self, from: albumData)
        return ForkAlbumDirectory(state: state, albums: albums)
    }

    private func get(_ path: String, optional: Bool) async throws -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if optional, [404, 405, 501].contains(response.statusCode) {
            return nil
        }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
