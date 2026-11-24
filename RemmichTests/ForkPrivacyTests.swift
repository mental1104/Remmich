import Foundation
import Testing
@testable import Remmich

struct ForkPrivacyTests {
    @Test func publicCoordinatesRequireExplicitConsentIncludingOldPreferences() throws {
        #expect(MapsPlacesPreferences().allowPublicLookup != true)
        let old = try JSONDecoder().decode(MapsPlacesPreferences.self, from: Data(#"{"endpoint":"https://photon.komoot.io","localCountries":[]}"#.utf8))
        #expect(old.allowPublicLookup != true)
    }

    @Test @MainActor func publicLookupMakesNoRequestBeforeConsent() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let session = try AccountSession(apiURL: #require(URL(string: "https://fixture.invalid/api")), accessToken: "fixture", userID: "privacy",
                                         userEmail: "fixture@example.invalid", name: "Fixture", isAdmin: false,
                                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session)
        try await fixture.seed(scope: scope)
        let client = NoCoordinateRequests()
        let locations = try AssetLocationStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), client: client, store: fixture.store)
        locations.configure(scope: scope)
        _ = try await locations.resolve(#require(PlaceCoordinate(latitude: 31, longitude: 121)), assetID: "asset")
        #expect(await client.calls == 0)
    }
}

private actor NoCoordinateRequests: PlaceLookingUp {
    private(set) var calls = 0
    func lookup(_: PlaceCoordinate, endpoint _: URL, language _: PlaceLanguage) async throws -> PlaceLocation? {
        calls += 1
        Issue.record("Public coordinate request without consent")
        return nil
    }

    func test(endpoint _: URL) async throws -> Bool {
        true
    }
}
