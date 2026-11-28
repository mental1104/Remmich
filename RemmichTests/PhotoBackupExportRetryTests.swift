import Foundation
import Photos
import Testing
@testable import Remmich

/// 只替换导出端口，不调用Photos、文件或网络；重试必须保留同一源及本次云读取许可。
@Suite("PhotoKit export retry boundaries")
@MainActor struct PhotoBackupExportRetryTests {
    @Test(arguments: [false, true])
    func retriesNetworkErrorWithoutChangingCloudPermission(_ allowCloud: Bool) async throws {
        let source = syntheticSource()
        let base = SyntheticRetryExporter(errors: [photosError(.networkError)])
        let exporter = PhotoSyncRetryingExporter(base: base, retry: PhotoSyncRetry(delays: [0], keepWaiting: false))
        let resources = try await exporter.export(source, allowCloud: allowCloud)
        #expect(base.sources == [source, source])
        #expect(base.cloudChoices == [allowCloud, allowCloud])
        #expect(resources.primary.file == base.resources.primary.file)
    }

    @Test(arguments: [PHPhotosError.Code.networkAccessRequired, .accessUserDenied, .identifierNotFound, .operationInterrupted])
    func doesNotRetryOtherPhotosErrors(_ code: PHPhotosError.Code) async throws {
        let original = photosError(code)
        let base = SyntheticRetryExporter(errors: [original])
        let exporter = PhotoSyncRetryingExporter(base: base, retry: PhotoSyncRetry(delays: [0], keepWaiting: false))
        do {
            _ = try await exporter.export(syntheticSource(), allowCloud: false)
            Issue.record("An unapproved or unavailable resource must retain its original failure")
        } catch {
            let actual = error as NSError
            #expect(actual.domain == original.domain && actual.code == original.code)
        }
        #expect(base.sources.count == 1 && base.cloudChoices == [false])
        #expect(!PhotoSyncRetry.isTransient(original))
    }

    @Test func requiresTheExactPhotosErrorDomain() {
        #expect(!PhotoSyncRetry.isTransient(NSError(domain: "SyntheticOtherDomain", code: PHPhotosError.Code.networkError.rawValue)))
    }

    @Test func exhaustedTransientFailureUsesSafeNetworkReason() async throws {
        let base = SyntheticRetryExporter(errors: [photosError(.networkError), photosError(.networkError)])
        let exporter = PhotoSyncRetryingExporter(base: base, retry: PhotoSyncRetry(delays: [0], keepWaiting: false))
        do {
            _ = try await exporter.export(syntheticSource(), allowCloud: true)
            Issue.record("An exhausted export must fail without publishing partial resources")
        } catch {
            let failure = try #require(error as? PhotoBackupExportError)
            #expect(failure.reason == .network)
        }
        #expect(base.sources.count == 2 && base.cloudChoices == [true, true])
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDuringBackoffRetiresImmediately() async throws {
        let base = SyntheticRetryExporter(errors: [photosError(.networkError)])
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let retry = PhotoSyncRetry(delays: [1_000_000_000], keepWaiting: true, status: { _ in signal.yield(()) })
        let exporter = PhotoSyncRetryingExporter(base: base, retry: retry)
        let source = syntheticSource()
        let task = Task { try await exporter.export(source, allowCloud: true) }
        let observer = Task { _ = await task.result; signal.finish() }
        defer { task.cancel(); observer.cancel(); signal.finish() }
        var iterator = waiting.makeAsyncIterator()
        try #require(await iterator.next() != nil, "The export must reach its retry wait")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await observer.value
        #expect(base.sources.count == 1 && base.cloudChoices == [true])
    }

    @Test(arguments: [false, true])
    func accountValidationRetiresBeforeAnyFurtherExport(_ revokeDuringBackoff: Bool) async throws {
        var current = revokeDuringBackoff
        let base = SyntheticRetryExporter(errors: [photosError(.networkError)])
        let retry = PhotoSyncRetry(delays: [0], keepWaiting: true, validate: {
            guard current else { throw LibraryWriteError.changedAccount }
        }, status: { _ in current = false })
        let exporter = PhotoSyncRetryingExporter(base: base, retry: retry)
        do {
            _ = try await exporter.export(syntheticSource(), allowCloud: true)
            Issue.record("A retired account must not publish or restart an export")
        } catch {
            guard let failure = error as? LibraryWriteError, case .changedAccount = failure else {
                Issue.record("Account validation must preserve its original error")
                return
            }
        }
        #expect(base.sources.count == (revokeDuringBackoff ? 1 : 0))
        #expect(base.cloudChoices.allSatisfy { $0 })
    }

    private func syntheticSource() -> PhotoBackupSource {
        .init(localID: "synthetic-export-source", modifiedAt: .distantPast, kind: .photo)
    }

    private func photosError(_ code: PHPhotosError.Code) -> NSError {
        NSError(domain: PHPhotosErrorDomain, code: code.rawValue)
    }
}

/// 全部状态在MainActor内；URL仅为合成回执，不创建或读取任何文件。
@MainActor private final class SyntheticRetryExporter: PhotoBackupResourceExporting {
    private var errors: [any Error]
    private(set) var sources: [PhotoBackupSource] = []
    private(set) var cloudChoices: [Bool] = []
    let resources = PhotoBackupResources(directory: URL(fileURLWithPath: "/synthetic-export"),
                                         primary: .init(file: URL(fileURLWithPath: "/synthetic-export/original"), name: "synthetic.jpg"),
                                         motion: nil, created: .distantPast, modified: .distantPast, favorite: false)

    init(errors: [any Error]) {
        self.errors = errors
    }

    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        sources.append(source); cloudChoices.append(allowCloud)
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        return resources
    }
}
