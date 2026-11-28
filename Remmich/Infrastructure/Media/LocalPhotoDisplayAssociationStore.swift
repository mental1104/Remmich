import Foundation

/// 仅展示Cloud ID关系的独立边界，不接收或修改legacy匹配文档及备份表。
nonisolated protocol LocalPhotoDisplayAssociationPersisting: Sendable {
    func load(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) async throws -> [LocalMediaAssociation]
    func merge(_ value: LocalMediaAssociation, scope: MediaAccountScope, access: LocalPhotoLibraryAccess, permit: LocalMediaSavePermit) async throws -> Bool
    func remove(_ id: UUID, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
}

/// 每个账号独立sidecar；merge的读取、校验及原子写在同一actor操作内完成，避免丢更新。
actor LocalPhotoDisplayAssociationStore: LocalPhotoDisplayAssociationPersisting {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("LocalPhotoDisplayAssociations", isDirectory: true)
    }

    private nonisolated struct Entry: Codable, Sendable {
        let remoteID: UUID
        let remoteRevision: Date
        let displayRevision: Date?
        let localID: String
        let modifiedAt: Date
        let kind: String
        let checksum: String

        init(_ value: LocalMediaAssociation) throws {
            guard value.source == .exactCloudIdentity, let modified = value.localIdentity.modificationDate else {
                throw LocalMediaMetadataError.invalidMetadata
            }
            remoteID = value.remoteID; remoteRevision = value.remoteRevision; displayRevision = value.displayRevision
            localID = value.localIdentity.localIdentifier; modifiedAt = modified; checksum = value.checksum
            kind = value.localIdentity.mediaKind == .video ? "video" : value.localIdentity.mediaKind == .livePhoto ? "livePhoto" : "image"
            _ = try association()
        }

        func association() throws -> LocalMediaAssociation {
            let mediaKind: LocalPhotoIdentity.MediaKind
            switch kind {
            case "image": mediaKind = .image
            case "video": mediaKind = .video
            case "livePhoto": mediaKind = .livePhoto
            default: throw LocalMediaMetadataError.invalidMetadata
            }
            guard !localID.isEmpty, modifiedAt.timeIntervalSince1970.isFinite,
                  remoteRevision.timeIntervalSince1970.isFinite, displayRevision?.timeIntervalSince1970.isFinite ?? true,
                  let digest = Data(base64Encoded: checksum), digest.count == 20, digest.base64EncodedString() == checksum
            else {
                throw LocalMediaMetadataError.invalidMetadata
            }
            return .init(remoteID: remoteID, remoteRevision: remoteRevision,
                         localIdentity: .init(localIdentifier: localID, modificationDate: modifiedAt, mediaKind: mediaKind),
                         checksum: checksum, source: .exactCloudIdentity, displayRevision: displayRevision)
        }
    }

    private nonisolated struct Document: Codable, Sendable {
        let formatVersion: Int
        let namespace: String
        let access: LocalPhotoLibraryAccess
        var entries: [Entry]
    }

    func load(scope: MediaAccountScope, access: LocalPhotoLibraryAccess) throws -> [LocalMediaAssociation] {
        try Task.checkCancellation()
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        guard let document = try read(scope: scope), document.access == access else { return [] }
        return try document.entries.map { try $0.association() }
    }

    func merge(_ value: LocalMediaAssociation, scope: MediaAccountScope, access: LocalPhotoLibraryAccess, permit: LocalMediaSavePermit) throws -> Bool {
        try Task.checkCancellation()
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        let entry = try Entry(value), previous = try read(scope: scope)
        var entries = previous?.access == access ? previous?.entries ?? [] : []
        entries.removeAll { $0.remoteID == value.remoteID }
        entries.append(entry)
        let document = Document(formatVersion: 1, namespace: scope.cacheNamespace, access: access, entries: entries)
        let data = try JSONEncoder().encode(document)
        try Task.checkCancellation()
        return try permit.writeIfCurrent {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(scope), options: .atomic)
        }
    }

    func remove(_ id: UUID, scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> Bool {
        try Task.checkCancellation()
        guard var document = try read(scope: scope), document.entries.contains(where: { $0.remoteID == id }) else {
            return try permit.writeIfCurrent {}
        }
        document.entries.removeAll { $0.remoteID == id }
        let data = try JSONEncoder().encode(document)
        try Task.checkCancellation()
        return try permit.writeIfCurrent { try data.write(to: file(scope), options: .atomic) }
    }

    private func file(_ scope: MediaAccountScope) -> URL {
        directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
    }

    private func read(scope: MediaAccountScope) throws -> Document? {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.formatVersion == 1, document.namespace == scope.cacheNamespace,
              document.access == .full || document.access == .limited,
              Set(document.entries.map(\.remoteID)).count == document.entries.count else { throw LocalMediaMetadataError.invalidMetadata }
        for entry in document.entries {
            _ = try entry.association()
        }
        return document
    }
}
