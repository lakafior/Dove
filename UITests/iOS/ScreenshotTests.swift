import XCTest

/// The screenshot tour (`scripts/screenshots.sh`): Dove in demo mode (`-demo`, public-domain content, no accounts),
/// one launch per screen so a failure on one leaves the others.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + arguments
        app.launch()
        return app
    }

    private func snap(_ name: String, settle: TimeInterval = 2) {
        // Posters load from Wikimedia Commons; give them a moment.
        Thread.sleep(forTimeInterval: settle)
        Screenshot.save(XCUIScreen.main.screenshot(), as: name, in: self)
    }

    func test1Search() {
        let app = launch()
        app.staticTexts["Recently added"].waitToAppear()
        snap("iphone-search", settle: 4)
    }

    func test2Sources() {
        let app = launch()
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        field.waitToAppear().tap()
        field.typeText("Nosferatu\n")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nosferatu'")).firstMatch.waitToAppear().tap()
        app.buttons["Sources"].waitToAppear().tap()
        app.staticTexts["2160p"].waitToAppear()
        snap("iphone-sources")
    }

    func test3Library() {
        let app = launch()
        app.tabBars.buttons["Library"].waitToAppear().tap()
        app.staticTexts["Metropolis"].waitToAppear()
        snap("iphone-library", settle: 4)
    }

    func test4Series() {
        let app = launch()
        app.tabBars.buttons["Library"].waitToAppear().tap()
        let series = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Beverly Hillbillies'")).firstMatch
        if !series.waitForExistence(timeout: 10) { app.swipeUp() }
        series.waitToAppear().tap()
        app.staticTexts["Season 1"].waitToAppear()
        snap("iphone-series")
    }

    func test5Audiobook() {
        let app = launch(["-demoAudiobook"])
        app.staticTexts["The Adventures of Sherlock Holmes"].waitToAppear()
        snap("iphone-audiobook", settle: 4)
    }

    func test6Downloads() {
        let app = launch()
        app.tabBars.buttons["Downloads"].waitToAppear().tap()
        app.staticTexts["Metropolis (1927) 1080p.mkv"].waitToAppear()
        snap("iphone-downloads")
    }

    func test7Setup() {
        let app = launch()
        app.tabBars.buttons["Settings"].waitToAppear().tap()
        let setup = app.buttons["Set up Dove again"]
        for _ in 0..<4 where !setup.isHittable { app.swipeUp() }
        setup.waitToAppear().tap()
        snap("iphone-setup")
    }
}
