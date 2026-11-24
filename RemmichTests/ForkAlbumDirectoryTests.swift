import XCTest
@testable import Remmich

final class ForkAlbumDirectoryTests: XCTestCase {
    func testDefaultCategoryAndGroupIntersection() throws {
        let state = try JSONDecoder().decode(ForkAlbumDirectory.State.self, from: Data(#"{"categories":[{"id":"c","name":"Trips"}],"groups":[{"groupName":"Paris","categoryId":"c"}]}"#.utf8))
        let albums = try JSONDecoder().decode([ForkAlbumDirectory.Album].self, from: Data(#"[{"id":"a","customGroupName":" Paris "},{"id":"b"}]"#.utf8))
        let directory = ForkAlbumDirectory(state: state, albums: albums)
        XCTAssertTrue(directory.includes(albumID: "a", category: "c", group: "Paris"))
        XCTAssertFalse(directory.includes(albumID: "a", category: ForkAlbumDirectory.defaultCategory, group: nil))
        XCTAssertTrue(directory.includes(albumID: "b", category: ForkAlbumDirectory.defaultCategory, group: ""))
        XCTAssertEqual(directory.searchText(albumID: "a"), "Trips Paris")
    }
}
