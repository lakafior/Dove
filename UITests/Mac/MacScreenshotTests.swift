import XCTest

/// The Mac screenshot tour (`scripts/screenshots.sh`): Dove in demo mode (`-demo`, public-domain content, no accounts,
/// nothing of the real app's Keychain, files or defaults touched), one launch per screen. Screenshots are of the
/// window only.
@MainActor
final class MacScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        app.activate()
        return app
    }

    private func snap(_ element: XCUIElement, as name: String, settle: TimeInterval = 2) {
        // Posters load from Wikimedia Commons; give them a moment.
        Thread.sleep(forTimeInterval: settle)
        Screenshot.save(element.screenshot(), as: name, in: self)
    }

    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows["Dove"].firstMatch.exists ? app.windows["Dove"].firstMatch : app.windows.firstMatch
    }

    /// The start page with the sidebar shown (it starts hidden).
    func test1Home() {
        let app = launch()
        let window = mainWindow(app).waitToAppear()
        app.staticTexts["Recently added"].waitToAppear()
        window.toolbars.buttons["Show Sidebar"].waitToAppear().click()
        snap(window, as: "mac-home", settle: 4)
    }

    func test2Sources() {
        let app = launch()
        let window = mainWindow(app).waitToAppear()
        let field = window.textFields.firstMatch.waitToAppear()
        field.click()
        field.typeText("Nosferatu\r")
        let result = window.buttons.matching(NSPredicate(format: "label CONTAINS 'Nosferatu'")).firstMatch
        result.waitToAppear().click()
        window.staticTexts["2160p"].waitToAppear()
        // No tooltip over the table.
        window.staticTexts["Nosferatu"].firstMatch.hover()
        snap(window, as: "mac-sources")
    }

    func test3Library() {
        let app = launch()
        let window = mainWindow(app).waitToAppear()
        window.links["Library"].waitToAppear().click()
        window.staticTexts["Metropolis"].waitToAppear()
        snap(window, as: "mac-library", settle: 4)
    }

    func test4Settings() {
        let app = launch()
        mainWindow(app).waitToAppear()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS 'Settings' OR title CONTAINS 'Settings' OR title == 'General'")).firstMatch
        snap(settings.waitToAppear(), as: "mac-settings")
    }
}
