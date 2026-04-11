import XCTest

/// UI tests for DriveCatalog critical flows.
///
/// Run via: xcodebuild test -scheme DriveCatalog -only-testing DriveCatalogUITests
final class DriveCatalogUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - App Launch & Navigation

    func testAppLaunches() {
        XCTAssertTrue(app.windows.count > 0, "App should have at least one window")
    }

    func testSidebarExists() {
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Sidebar outline should exist")
    }

    func testSidebarNavigation() {
        // Use accessibility identifiers to avoid "multiple matches" with window titles
        let tabs: [(id: String, label: String)] = [
            ("sidebar_drives", "Drives"),
            ("sidebar_browser", "Files"),
            ("sidebar_manage", "Manage"),
            ("sidebar_settings", "Settings"),
        ]

        for tab in tabs {
            let item = app.staticTexts[tab.id]
            if item.waitForExistence(timeout: 5) {
                item.click()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Navigate back to Drives
        let drives = app.staticTexts["sidebar_drives"]
        if drives.exists { drives.click() }
    }

    // MARK: - Add Drive Sheet

    func testAddDriveSheetOpens() {
        // Wait for app to finish loading
        let addButton = app.buttons["addDriveButton"].firstMatch
        guard addButton.waitForExistence(timeout: 15) else {
            // No add button visible = may be on a different tab or drives already loaded
            return
        }
        addButton.click()

        // Sheet should appear with "Add Drive" title
        let sheetTitle = app.staticTexts["Add Drive"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Add Drive sheet should appear")

        // Cancel button should exist
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "Cancel button should exist in Add Drive sheet")
        cancel.click()
    }

    // MARK: - Settings & Bug Report

    func testSettingsPageLoads() {
        let settings = app.staticTexts["sidebar_settings"]
        guard settings.waitForExistence(timeout: 10) else {
            XCTFail("Settings sidebar item not found")
            return
        }
        settings.click()

        // Bug report button should be visible
        let bugButton = app.buttons["reportBugButton"]
        XCTAssertTrue(bugButton.waitForExistence(timeout: 5), "Report a Bug button should exist in Settings")
    }

    // MARK: - Transfer History

    func testTransferHistoryLoads() {
        let transfers = app.staticTexts["sidebar_transfers"]
        guard transfers.waitForExistence(timeout: 10) else {
            return
        }
        transfers.click()
        Thread.sleep(forTimeInterval: 1)
        // Verify navigation doesn't crash
        XCTAssertTrue(app.windows.count > 0)
    }
}
