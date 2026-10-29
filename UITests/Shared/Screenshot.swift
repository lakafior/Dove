import XCTest

/// Keeps a screenshot in the result bundle under `name`; `scripts/screenshots.sh` exports the attachments
/// (`xcresulttool export attachments`) as `docs/screenshots/<name>.png`. The Mac test runner is sandboxed, so the
/// tests do not write files themselves.
@MainActor
enum Screenshot {
    static func save(_ screenshot: XCUIScreenshot, as name: String, in test: XCTestCase) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

extension XCUIElement {
    /// Waits for the element, failing the test with its description when it never comes.
    @MainActor
    @discardableResult
    func waitToAppear(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCTFail("Not found: \(self)", file: file, line: line)
        }
        return self
    }
}
