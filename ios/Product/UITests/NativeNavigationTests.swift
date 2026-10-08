import XCTest

final class NativeNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = try XCTUnwrap(Bundle(for: Self.self)
            .object(forInfoDictionaryKey: "OWTargetAppBundleIdentifier") as? String)
        XCTAssertFalse(identifier.isEmpty, "The signed test bundle must identify its actual target app")
        app = XCUIApplication(bundleIdentifier: identifier)
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
    }

    private func selectTab(_ name: String, title: String? = nil) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isHittable, "The \(name) tab must be reachable by touch")
        button.tap()
        XCTAssertTrue(button.isSelected)
        if let title {
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
        }
    }

    private func revealAndTap(_ label: String) {
        let button = app.buttons[label].firstMatch
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable, "Missing reachable control: \(label)")
        button.tap()
    }

    private func record(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testNativeTabsAndSettingsNavigation() {
        selectTab("Models", title: "Models")
        record("Models tab reached by touch")
        selectTab("Watches", title: "Watches")
        record("Watch scheduling disclosure")
        selectTab("Settings", title: "Settings")
        revealAndTap("Usage and storage")
        XCTAssertTrue(app.navigationBars["Usage and storage"].waitForExistence(timeout: 10))
        record("Usage and storage screen")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        revealAndTap("Saved facts")
        XCTAssertTrue(app.navigationBars["Saved memory"].waitForExistence(timeout: 10))
        record("Saved memory screen")
        app.navigationBars.buttons.firstMatch.tap()
        revealAndTap("File tools and folder access")
        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 10))
        record("File tools screen")
        selectTab("Chat")
    }

    func testNativeDiscoveryFiltersCancelWithoutDownload() {
        selectTab("Models", title: "Models")
        revealAndTap("Search Hugging Face")
        XCTAssertTrue(app.navigationBars["Discover"].waitForExistence(timeout: 10))
        revealAndTap("Filters")
        XCTAssertTrue(app.navigationBars["Discovery filters"].waitForExistence(timeout: 10))
        record("Discovery filter controls")
        let cancel = app.navigationBars["Discovery filters"].buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Discover"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Discovery filters"].exists)
        record("Discovery after cancelled filter sheet")
    }

    func testNativeMemoryEditorValidationAndCancel() {
        selectTab("Settings", title: "Settings")
        revealAndTap("Saved facts")
        revealAndTap("Add a fact")
        let editor = app.navigationBars["Add a fact"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let save = editor.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "An empty fact cannot be saved")
        let field = app.textFields.firstMatch.exists
            ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("UI draft " + UUID().uuidString)
        XCTAssertTrue(save.isEnabled, "A nonempty fact within the limit can be saved")
        field.typeText(String(repeating: "x", count: 170))
        XCTAssertFalse(save.isEnabled, "An oversized fact cannot be saved")
        record("Unsaved memory editor rejects oversized fact")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Saved memory"].waitForExistence(timeout: 10))
        revealAndTap("Add a fact")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(editor.buttons["Save"].isEnabled,
                       "Reopening the editor must discard the cancelled draft")
        editor.buttons["Cancel"].tap()
    }

    func testNativeMemoryToolPreferencesPersistAndRestore() throws {
        selectTab("Settings", title: "Settings")
        let labels = ["Let chat read saved facts", "Let chat request memory changes"]
        func memorySwitch(_ label: String) -> XCUIElement {
            let control = app.switches[label].firstMatch
            for _ in 0..<8 {
                if control.exists && control.isHittable { break }
                app.swipeUp()
            }
            for _ in 0..<8 {
                if control.exists && control.isHittable { break }
                app.swipeDown()
            }
            XCTAssertTrue(control.exists && control.isHittable)
            return control
        }
        func value(_ control: XCUIElement) throws -> String {
            let result = try XCTUnwrap(control.value as? String)
            XCTAssertTrue(["0", "1"].contains(result))
            return result
        }
        let initial = try labels.map { try value(memorySwitch($0)) }
        addTeardownBlock { [self] in
            app.activate()
            selectTab("Settings", title: "Settings")
            for (label, expected) in zip(labels, initial) {
                let control = memorySwitch(label)
                if try value(control) != expected { control.tap() }
                XCTAssertEqual(try value(control), expected,
                               "Restore each original memory permission even after a failure")
            }
        }
        for (label, original) in zip(labels, initial) {
            let control = memorySwitch(label)
            control.tap()
            XCTAssertEqual(try value(control), original == "0" ? "1" : "0")
        }
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        selectTab("Settings", title: "Settings")
        for (label, original) in zip(labels, initial) {
            XCTAssertEqual(try value(memorySwitch(label)), original == "0" ? "1" : "0",
                           "The changed preference must survive a controlled process relaunch")
        }
    }

    func testNativeHomeReturnAndProcessRelaunch() {
        selectTab("Watches", title: "Watches")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10)
                      || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        record("Foreground return after Home")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        selectTab("Models", title: "Models")
        record("Models after controlled process relaunch")
    }
}
