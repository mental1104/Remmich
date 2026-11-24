import Foundation
import Testing
@testable import Remmich

struct LibraryManagementControllerTests {
    @Test @MainActor func changingAccountRejectsLateWritesAndReleasesBusyState() async throws {
        let controller = LibraryManagementController()
        let first = session("first")
        controller.configure(session: first, endpoint: first.apiURL)
        let owner = controller.generation
        let gate = ManagementTestGate()
        let pending = Task {
            try await controller.perform { _ in
                await gate.wait()
                return "old account result"
            }
        }
        while !controller.busy {
            await Task.yield()
        }
        do {
            _ = try await controller.perform { _ in 2 }
            Issue.record("Concurrent write should have been rejected")
        } catch LibraryWriteError.busy {}
        let second = session("second")
        controller.configure(session: second, endpoint: second.apiURL)
        await gate.release()
        do {
            _ = try await pending.value
            Issue.record("Old account result should have been rejected")
        } catch LibraryWriteError.changedAccount {}
        #expect(controller.generation != owner)
        #expect(controller.busy == false)
        #expect(controller.revision == 0)
        let value = try await controller.perform { _ in 3 }
        #expect(value == 3 && controller.revision == 1)
        controller.configure(session: nil, endpoint: nil)
    }

    private func session(_ user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://fixture.invalid/api")!, accessToken: "fixture-\(user)", userID: user,
              userEmail: "fixture@example.invalid", name: user, isAdmin: false,
              serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
    }
}

private actor ManagementTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
