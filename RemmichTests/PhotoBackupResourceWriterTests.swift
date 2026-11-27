import Foundation
import Testing
@testable import Remmich

@Suite("Backup resource background callbacks")
@MainActor struct PhotoBackupResourceWriterTests {
    @Test func backgroundChunksFinishOnceAndIgnoreLateDelivery() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "BackupWriter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try PhotoBackupResourceFileWriter(file: file, cancelRequest: { _ in })
        try await writer.read { receive, complete in
            DispatchQueue.global().async {
                receive(Data("first".utf8))
                receive(Data("second".utf8))
                complete(nil)
                complete(nil)
                receive(Data("late".utf8))
            }
            return 0
        }
        #expect(try Data(contentsOf: file) == Data("firstsecond".utf8))
    }

    @Test func cancellationFinishesWaitingReadWithoutACompletionCallback() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "BackupWriter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try PhotoBackupResourceFileWriter(file: file, cancelRequest: { _ in })
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await writer.read { _, _ in
                continuation.yield(())
                return 0
            }
        }
        var events = started.makeAsyncIterator()
        _ = await events.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: file).isEmpty)
    }
}
