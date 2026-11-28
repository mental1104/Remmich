import Foundation

/// Only fixed validation categories and aggregate counts cross this boundary. Never add media,
/// bucket dates, account identifiers, URLs, response bodies or localized error descriptions.
nonisolated struct LibraryIndexFailureDiagnostic: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case selectedMonth, mergedCatalog, finalCatalog }
    enum Reason: String, Codable, Sendable { case countMismatch, duplicateIDs, wrongMonth, bucketCountMismatch }
    let stage: Stage
    let reason: Reason
    let expectedCount: Int
    let actualCount: Int
    var uniqueIDCount: Int? = nil
    var wrongMonthCount: Int? = nil
    var mismatchedBucketCount: Int? = nil
}

typealias LibraryIndexFailureReporter = @Sendable (LibraryIndexFailureDiagnostic) async -> Void

#if DEBUG
    /// Explicit production opt-in only. Domain/controller constructors default to no reporter so
    /// isolated unit tests cannot accidentally write to the real Application Support directory.
    actor LibraryIndexFailureFileSink {
        nonisolated static let shared = LibraryIndexFailureFileSink()
        private let session = UUID().uuidString
        private var sequence = 0

        /// Construct the Sendable callback outside MainActor inference, capturing only this actor.
        nonisolated static func makeReporter() -> LibraryIndexFailureReporter {
            let sink = shared
            return { diagnostic in await sink.record(diagnostic) }
        }

        private nonisolated struct Document: Encodable {
            let formatVersion = 1
            let session: String
            let sequence: Int
            let diagnostic: LibraryIndexFailureDiagnostic
        }

        /// A small atomic replacement is serialized here; any I/O failure leaves the original
        /// validation error and accepted generation unchanged. No failure text is logged.
        func record(_ diagnostic: LibraryIndexFailureDiagnostic) {
            guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            sequence += 1
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appending(path: "library-sync-debug.json")
                let data = try JSONEncoder().encode(Document(session: session, sequence: sequence, diagnostic: diagnostic))
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                #if os(iOS)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                #endif
            } catch { /* Diagnostics must never replace or recover an indexing failure. */ }
        }
    }
#endif
