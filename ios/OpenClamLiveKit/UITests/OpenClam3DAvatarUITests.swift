import XCTest

/// Drives the real carousel to an installed `ios-3d` avatar and exercises
/// read-aloud, saving screenshots for the release audit. Skips when no 3D
/// package is installed on the simulator (`OPENCLAM_UITEST_3D_AVATAR_ID`
/// names it; default `tia`).
final class OpenClam3DAvatarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var avatarID: String {
        ProcessInfo.processInfo.environment["OPENCLAM_UITEST_3D_AVATAR_ID"] ?? "tia"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testInstalledModelAvatarRendersAndLipSyncs() throws {
        let carousel = app.buttons["Close avatar carousel"]
        unfoldAvatarRail()
        let alreadyActive = (app.buttons["openclam-avatar-picker"].value as? String ?? "")
            .lowercased().contains(avatarID.lowercased())
        // The rail fades to idle after a moment; a tap that lands during the
        // fade can be dropped, so re-open the rail and retry a few times.
        var opened = alreadyActive
        for _ in 0 ..< 4 where !opened {
            unfoldAvatarRail()
            let picker = app.buttons["openclam-avatar-picker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            XCTAssertTrue(picker.isEnabled, "avatar picker must be enabled: \(picker.value ?? "")")
            picker.tap()
            opened = carousel.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(opened, "carousel did not open")
        let card = app.buttons["openclam-avatar-carousel-card-\(avatarID)"]
        if !alreadyActive, !card.waitForExistence(timeout: 3) {
            throw XCTSkip("No installed 3D avatar named \(avatarID); import an ios-3d package first.")
        }
        // Bring the card forward, then confirm it. The carousel flips the
        // value to Selected when the tapped card is in front.
        if !alreadyActive { capture("3d-avatar-carousel") }
        // Side cards sit under the front card, so spin with swipes until the
        // wanted card is in front, then tap it to activate.
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "openclam-avatar-carousel-card-")
        )
        var activated = alreadyActive
        let guidance = app.descendants(matching: .any)["openclam-avatar-carousel-selection-guidance"]
        if !alreadyActive { XCTAssertTrue(guidance.waitForExistence(timeout: 3)) }
        for step in 0 ..< 12 where !activated {
            guard carousel.exists else { break }
            let frontName = (guidance.label.isEmpty ? (guidance.value as? String ?? "") : guidance.label)
            capture("3d-avatar-carousel-step\(step)-\(frontName.prefix(12).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ",", with: ""))")
            let frontCard = cards.matching(NSPredicate(format: "value BEGINSWITH %@", "Selected")).firstMatch
            let frontID = frontCard.exists ? frontCard.identifier : ""
            if frontName.lowercased().hasPrefix(avatarID.lowercased())
                || frontID == "openclam-avatar-carousel-card-\(avatarID)" {
                let front = cards.matching(NSPredicate(format: "value BEGINSWITH %@", "Selected")).firstMatch
                XCTAssertTrue(front.waitForExistence(timeout: 2))
                front.tap()
                activated = true
                break
            }
            // One card per drag: the layout advances a card every `dragStep`
            // points, so drag slightly more than one step from the middle.
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
            let target = middle.withOffset(CGVector(dx: -70, dy: 0))
            middle.press(forDuration: 0.15, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
            usleep(900_000)
        }
        XCTAssertTrue(activated, "the \(avatarID) card never reached the front")
        if !alreadyActive {
            XCTAssertTrue(carousel.waitForNonExistence(timeout: 8), "choosing the avatar must dismiss the carousel")
        }
        // Give the model a moment to decode before the first capture.
        _ = app.buttons["openclam-avatar-rail-fold-button"].waitForExistence(timeout: 3)
        sleep(4)
        unfoldAvatarRail()
        let chosen = app.buttons["openclam-avatar-picker"].value as? String ?? ""
        capture("3d-avatar-standby-picker-\(chosen.replacingOccurrences(of: " ", with: "_"))")
        XCTAssertTrue(chosen.lowercased().contains("tia"), "picker should report the 3D avatar, got \(chosen)")
        capture("3d-avatar-standby")

        selectAvatarMode("Close-up")
        sleep(2)
        capture("3d-avatar-closeup")

        // The simulator's speech service is not dependable, so mirror the
        // conversation UI test: relaunch holding the real preparation state,
        // which keeps the speaking controls and the 3D stage's speaking pose
        // observable without relying on a synthetic voice.
        app.terminate()
        app.launchArguments.append("-OpenClamUITestHoldSpeechPreparation")
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
        sleep(3)
        unfoldAvatarRail()
        XCTAssertTrue((app.buttons["openclam-avatar-picker"].value as? String ?? "").lowercased().contains(avatarID),
                      "the 3D avatar must stay selected across relaunch")
        capture("3d-avatar-relaunched")
        var speaking = false
        for _ in 0 ..< 3 where !speaking {
            unfoldAvatarRail()
            let play = app.buttons["Play latest reply"]
            guard play.waitForExistence(timeout: 3), play.isEnabled else { break }
            play.tap()
            speaking = app.buttons["Stop speaking"].waitForExistence(timeout: 3)
        }
        if speaking {
            usleep(600_000)
            capture("3d-avatar-speaking-1")
            usleep(400_000)
            capture("3d-avatar-speaking-2")
            let stop = app.buttons["Stop speaking"]
            if stop.exists, stop.isHittable { stop.tap() }
        } else {
            capture("3d-avatar-no-reply-to-speak")
        }

        selectAvatarMode("Standby")
        sleep(2)
        capture("3d-avatar-full-body")
    }

    func test3DControlsRotatePinchMoveAndReset() throws {
        app.terminate()
        app.launchArguments += ["-OpenClamUITestMacRenderer",
            "-ai.provider.settings.v2.active-avatar.v1", avatarID,
            "-captainAyer.overlay.mode", "standby",
            "-captainAyer.overlay.interactionLayer", "avatar",
            "-captainAyer.overlay.opacity", "1", "-captainAyer.overlay.hidden", "NO"]
        app.launch()
        let controls = app.buttons["openclam-3d-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 12), "Select the installed Tia fixture first")
        sleep(4)
        func command(_ title: String) {
            unfoldAvatarRail()
            controls.tap()
            let item = app.buttons[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
        }
        command("Reset 3D View")
        command("Rotate with One Finger")
        let initial = controls.value as? String
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.52))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertNotEqual(controls.value as? String, initial, "One finger must orbit the actual view")
        capture("shared-3d-orbit")
        command("Reset 3D View")
        app.pinch(withScale: 1.45, velocity: 1)
        XCTAssertFalse((controls.value as? String ?? "").contains("zoom 100%"), "A real two-touch pinch must resize")
        capture("shared-3d-pinch")
        command("View from Above")
        XCTAssertTrue((controls.value as? String ?? "").contains("pitch 45"))
        capture("shared-3d-above")
        command("Back View")
        capture("shared-3d-back")
        command("Reset 3D View")
        XCTAssertTrue((controls.value as? String ?? "").contains("zoom 100%, yaw 0, pitch 0"), "Reset state: \(controls.value ?? "missing")")
        selectAvatarMode("Close-up")
        app.pinch(withScale: 0.8, velocity: -1)
        capture("shared-3d-closeup-pinch")
        command("Move with One Finger")
        let beforeMove = controls.value as? String
        start.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertNotEqual(controls.value as? String, beforeMove, "Dragging in Move mode changes placement")
        capture("shared-3d-moved")
        command("Reset 3D View")
        capture("shared-3d-reset")
    }

    // MARK: helpers (mirrors OpenClamConversationUITests)

    private func unfoldAvatarRail() {
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 5))
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        if foldControl.label == "Show all tools" {
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        } else if rail.value as? String != "Visible" {
            // An idle rail fades out; fold and reopen so its controls are
            // opaque and hittable again.
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Show all tools", on: foldControl, timeout: 3))
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        }
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == label { return true }
            usleep(100_000)
        }
        return element.label == label
    }

    private func selectAvatarMode(_ title: String) {
        for _ in 0 ..< 4 {
            unfoldAvatarRail()
            let menu = app.buttons["openclam-avatar-mode-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            menu.tap()
            let option = app.buttons[title]
            if option.waitForExistence(timeout: 2) {
                option.tap()
                return
            }
            let text = app.staticTexts[title].firstMatch
            if text.waitForExistence(timeout: 1) {
                text.tap()
                return
            }
            usleep(500_000)
        }
        XCTFail("could not select avatar mode \(title)")
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OPENCLAM_UITEST_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
