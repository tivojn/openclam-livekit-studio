import XCTest

final class AvatarAgentSaveDismissUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = baseLaunchArguments + [
            "-OpenClamUITestCleanDeletableAvatar",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testImportedAvatarSaveWithKeyboardPersistsAndReturnsToAgentList() throws {
        relaunch(seedingImportedAvatar: true)
        openAvatarAgents()

        let fixtureID = "ui-test-deletable-avatar"
        let originalName = "UI Test Imported Avatar"
        let savedName = originalName + " Saved"
        let card = app.descendants(matching: .any)[
            "openclam-avatar-agent-\(fixtureID)"
        ]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()
        XCTAssertTrue(app.navigationBars[originalName].waitForExistence(timeout: 3))
        let name = app.textFields["Agent name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText(" Saved")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 2))

        let save = app.buttons["openclam-avatar-save-and-close"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertEqual(save.label, "Save")
        XCTAssertTrue(save.isHittable)
        save.tap()

        XCTAssertTrue(
            app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3),
            "A successful save must pop exactly one level to Avatar Agents."
        )
        XCTAssertTrue(save.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 2))

        relaunch(seedingImportedAvatar: true)
        openAvatarAgents()
        let relaunchedCard = app.descendants(matching: .any)[
            "openclam-avatar-agent-\(fixtureID)"
        ]
        XCTAssertTrue(relaunchedCard.waitForExistence(timeout: 3))
        XCTAssertTrue(relaunchedCard.label.contains(savedName))
        relaunchedCard.tap()
        XCTAssertTrue(app.navigationBars[savedName].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Agent name"].value as? String, savedName)
    }

    func testProtectedAvatarValidationFailureRetainsEditorDraftAtLargeTextSize() throws {
        openAvatarAgents()

        let captainAyer = app.descendants(matching: .any)[
            "openclam-avatar-agent-captain-ayer"
        ]
        XCTAssertTrue(captainAyer.waitForExistence(timeout: 3))
        captainAyer.tap()
        XCTAssertTrue(app.navigationBars["Captain Ayer"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons["openclam-avatar-editor-delete"].exists,
            "A protected built-in avatar must not expose deletion."
        )

        let name = app.textFields["Agent name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        let invalidSuffix = String(repeating: "A", count: 65)
        name.typeText(invalidSuffix)
        let expectedDraft = "Captain Ayer" + invalidSuffix
        XCTAssertEqual(name.value as? String, expectedDraft)
        XCTAssertTrue(app.keyboards.element.exists)

        let save = app.buttons["openclam-avatar-save-and-close"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertEqual(save.label, "Save")
        XCTAssertTrue(save.isHittable)
        save.tap()

        XCTAssertTrue(
            save.waitForExistence(timeout: 2),
            "Validation failure must keep the editor open for correction."
        )
        XCTAssertEqual(name.value as? String, expectedDraft)
        XCTAssertTrue(
            app.keyboards.element.exists,
            "Validation failure must not discard the active edit session."
        )
        XCTAssertTrue(
            app.staticTexts["Use an avatar name between 1 and 64 characters."]
                .waitForExistence(timeout: 2)
        )
    }

    private var baseLaunchArguments: [String] {
        [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
    }

    private func relaunch(seedingImportedAvatar: Bool) {
        app.terminate()
        app.launchArguments = baseLaunchArguments
        if seedingImportedAvatar {
            app.launchArguments.append("-OpenClamUITestSeedDeletableAvatar")
        }
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
    }

    private func openAvatarAgents() {
        app.buttons["Open sidebar"].tap()
        XCTAssertTrue(app.buttons["Sidebar settings"].waitForExistence(timeout: 3))
        app.buttons["Sidebar settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))
    }
}
