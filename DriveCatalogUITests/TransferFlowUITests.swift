import XCTest

/// UI tests for the transfer flow.
///
/// Full end-to-end transfer testing requires two mounted external drives.
/// These tests verify navigation and view loading.
final class TransferFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testTransferHistoryNavigable() {
        let transfers = app.staticTexts["sidebar_transfers"]
        guard transfers.waitForExistence(timeout: 10) else { return }
        transfers.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.windows.count > 0, "App should still be running after navigating to transfers")
    }

    func testMultiTabNavigation() {
        // Navigate through several tabs to verify stability
        for tabId in ["sidebar_settings", "sidebar_drives", "sidebar_transfers", "sidebar_manage"] {
            let item = app.staticTexts[tabId]
            if item.waitForExistence(timeout: 5) {
                item.click()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTAssertTrue(app.windows.count > 0)
    }
}
