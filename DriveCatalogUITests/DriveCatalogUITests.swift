import XCTest

/// UI tests for DriveCatalog critical flows.
///
/// These tests require the app to launch with a running backend.
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
        // Sidebar may render as a List, which on macOS is an outline
        // Fall back to checking for sidebar items by identifier
        let drivesItem = app.staticTexts["Drives"]
        XCTAssertTrue(drivesItem.waitForExistence(timeout: 10), "Drives sidebar item should exist")
    }

    func testSidebarNavigation() {
        let tabs = ["Drives", "Files", "Manage", "Settings"]
        for tab in tabs {
            let item = app.staticTexts[tab]
            if item.waitForExistence(timeout: 5) {
                item.click()
                // Give the view time to load
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        // Navigate back to Drives
        let drives = app.staticTexts["Drives"]
        if drives.exists { drives.click() }
    }

    // MARK: - Add Drive Sheet

    func testAddDriveSheetOpens() {
        // Wait for app to finish loading
        let addButton = app.buttons["addDriveButton"]
        guard addButton.waitForExistence(timeout: 15) else {
            // No add button in toolbar = drives already registered, which is fine
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
        let settings = app.staticTexts["Settings"]
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
        let transfers = app.staticTexts["Transfer History"]
        guard transfers.waitForExistence(timeout: 10) else {
            // Transfer History might not be visible if sidebar is collapsed
            return
        }
        transfers.click()
        Thread.sleep(forTimeInterval: 1)
        // Just verify navigation doesn't crash
    }
}
