import Foundation
import Testing
@testable import Remmich

@Suite("Backup read retry boundaries")
@MainActor struct PhotoBackupReadRetryTests {
    @Test(arguments: [false, true]) func temporaryConnectionFailureRecoversWithinBound(_ fullIndex: Bool) async throws {
        let base = RetryQueryFixture()
        base.failures = 2
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0, 0, 0])
        if fullIndex {
            _ = try await reader.localMediaMetadataSnapshot()
        } else {
            _ = try await reader.localMediaMetadata(cloudIDs: [])
        }
        #expect(base.reads == 3)
    }

    @Test func exhaustionStopsAndWritesAreNeverReplayed() async throws {
        let base = RetryQueryFixture()
        base.failures = 100
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0, 0])
        await #expect(throws: URLError.self) { try await reader.localMediaMetadata(cloudIDs: []) }
        #expect(base.reads == 3)
        await #expect(throws: URLError.self) { try await reader.recordICloudMatches([:]) }
        #expect(base.writes == 1)
    }

    @Test(arguments: [401, 403, 400, 404])
    func permanentHTTPFailuresDoNotRetry(_ code: Int) async throws {
        let base = RetryQueryFixture()
        base.httpError = code
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0, 0])
        await #expect(throws: LibraryWriteError.self) { try await reader.localMediaMetadata(cloudIDs: []) }
        #expect(base.reads == 1)
    }

    @Test func cancellationDuringBackoffDoesNotIssueAnotherRead() async throws {
        let base = RetryQueryFixture()
        base.failures = 100
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let reader = PhotoBackupRetryingQueries(base: base, delays: [30_000_000_000], status: { _ in continuation.yield(()) })
        let task = Task { try await reader.localMediaMetadata(cloudIDs: []) }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(base.reads == 1)
    }

    @Test func retiredContextCannotRetryOnAnotherAccount() async throws {
        let base = RetryQueryFixture()
        base.failures = 100
        var current = true
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0], validate: {
            if !current {
                throw LibraryWriteError.changedAccount
            }
        }, status: { _ in current = false })
        await #expect(throws: LibraryWriteError.self) { try await reader.localMediaMetadata(cloudIDs: []) }
        #expect(base.reads == 1)
    }

    @Test(arguments: [408, 429] + Array(500 ... 599))
    func temporaryGatewayFailuresHaveBoundedRetries(_ code: Int) async throws {
        let base = RetryQueryFixture()
        base.httpError = code
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0, 0])
        await #expect(throws: LibraryWriteError.self) { try await reader.localMediaMetadata(cloudIDs: []) }
        #expect(base.reads == 3)
    }

    @Test(arguments: [URLError.cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .unsupportedURL])
    func cancellationAndSecurityErrorsAreNotRetried(_ code: URLError.Code) async throws {
        let base = RetryQueryFixture()
        base.failures = 100; base.transportCode = code
        let reader = PhotoBackupRetryingQueries(base: base, delays: [0, 0])
        await #expect(throws: URLError.self) { try await reader.localMediaMetadata(cloudIDs: []) }
        #expect(base.reads == 1)
    }
}

@MainActor private final class RetryQueryFixture: PhotoBackupContinuityQuerying {
    var reads = 0
    var writes = 0
    var failures = 0
    var httpError: Int?
    var transportCode = URLError.networkConnectionLost

    @MainActor func localMediaMetadataSnapshot() async throws -> [LocalMediaRemoteMetadataRecord] {
        try await localMediaMetadata(cloudIDs: [])
    }

    @MainActor func localMediaMetadata(cloudIDs _: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        reads += 1
        if let httpError {
            throw LibraryWriteError.http(httpError)
        }
        if reads <= failures {
            throw URLError(transportCode)
        }
        return []
    }

    func lookupBackupChecksums(_: [PhotoBackupCachedChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        []
    }

    func localMediaAsset(_: String) async throws -> LocalMediaRemoteAsset {
        throw URLError(.networkConnectionLost)
    }

    @MainActor func recordICloudMatches(_: [UUID: String]) async throws {
        writes += 1
        throw URLError(.networkConnectionLost)
    }
}
