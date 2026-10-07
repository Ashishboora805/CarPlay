import XCTest

/// UI smoke tests. The app runs with `-UITestMode`: in-memory storage and a synthetic
/// three-channel playlist, with no network access required.
final class LumenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
    }

    func testTabNavigation() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        for name in ["Live", "Guide", "Web", "Settings", "Home"] {
            tabBar.buttons[name].tap()
            XCTAssertTrue(tabBar.buttons[name].isSelected, "\(name) tab should be selected")
        }
    }

    func testLiveTVListsSeededChannels() {
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo News'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo Sports'")).firstMatch.exists)
    }

    func testSearchFiltersChannels() {
        app.tabBars.buttons["Live"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("music")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo Music'")).firstMatch.waitForExistence(timeout: 5))
        // Search is debounced, so wait for the unfiltered rows to disappear.
        let news = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo News'")).firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: news)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed)
    }

    func testToggleFavoriteViaSwipe() {
        app.tabBars.buttons["Live"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo News'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Favorite"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo News' AND label CONTAINS 'Favorite'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testAddPlaylistFormValidatesURL() {
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Playlists'")).firstMatch.tap()
        app.buttons["Add Playlist"].tap()
        // Multi-line (axis: .vertical) text fields are exposed as text views.
        let urlField = app.textViews["playlistURL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText("not a url")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Enter a valid playlist URL starting with http:// or https://."].waitForExistence(timeout: 3))
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
