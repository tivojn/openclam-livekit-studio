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

    func testDynamicMotionsBundledLibraryAndPlayback() throws {
        app.terminate()
        app.launchArguments += ["-ai.provider.settings.v2.active-avatar.v1", avatarID,
            "-captainAyer.overlay.mode", "standby", "-captainAyer.overlay.interactionLayer", "avatar",
            "-captainAyer.overlay.opacity", "1", "-captainAyer.overlay.hidden", "NO"]
        app.launch()
        let renderer = app.descendants(matching: .any)["openclam-shared-3d-renderer"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"), object: renderer)], timeout: 120), .completed)
        openWardrobe()
        let browse = app.buttons["openclam-3d-browse-motions"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.label.contains("62"), "TestFlight must include the full private motion library")
        let reactions = app.switches["openclam-3d-dynamicMotions"]
        XCTAssertTrue(reactions.exists)
        if reactions.value as? String != "1" { reactions.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        capture("dynamic-motions-default-controls")
        browse.tap()
        let wave = app.buttons["openclam-3d-motion-wave"]
        XCTAssertTrue(wave.waitForExistence(timeout: 5))
        wave.tap()
        let status = app.staticTexts["openclam-3d-motion-status"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Playing: Wave"), object: status)], timeout: 15), .completed)
        capture("dynamic-motions-library-wave")
        app.navigationBars["Dynamic motions"].buttons["BackButton"].tap()
        let random = app.buttons["Random dance"]
        XCTAssertTrue(random.waitForExistence(timeout: 5))
        random.tap()
        let danceStatus = app.staticTexts["openclam-3d-motion-status"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Playing:", "Playing: Wave"), object: danceStatus)], timeout: 15), .completed)
        app.buttons["Done"].tap()
        capture("dynamic-dance-start")
        sleep(2)
        capture("dynamic-dance-later")
        XCTAssertEqual(renderer.value as? String, "Ready")
        openWardrobe()
        app.buttons["Stop motion"].tap()
        XCTAssertEqual(reactions.value as? String, "0", "Stop must also pause automatic reactions")
        reactions.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(reactions.value as? String, "1")
        app.buttons["Done"].tap()
    }

    func testTypedMotionCommandUsesLocalRenderer() throws {
        app.terminate()
        app.launchArguments += ["-ai.provider.settings.v2.active-avatar.v1", avatarID,
            "-captainAyer.overlay.mode", "closeup", "-captainAyer.overlay.opacity", "1"]
        app.launch()
        let renderer = app.descendants(matching: .any)["openclam-shared-3d-renderer"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"), object: renderer)], timeout: 120), .completed)
        let compact = app.buttons["Message the AI assistant"]
        if compact.exists { compact.tap() }
        let composer = app.textFields["Message the AI assistant"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Tia, do joyful sway")
        app.buttons["Send message"].tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Here’s Joyful Sway.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "A named motion must execute locally without asking an AI provider")
        capture("dynamic-motion-typed-request")
    }

    func testWardrobeAndAuthoredPoses() throws {
        app.terminate()
        app.launchArguments += ["-OpenClamUITestMacRenderer",
            "-ai.provider.settings.v2.active-avatar.v1", avatarID,
            "-captainAyer.overlay.mode", "standby",
            "-captainAyer.overlay.interactionLayer", "avatar",
            "-captainAyer.overlay.opacity", "1", "-captainAyer.overlay.hidden", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["openclam-3d-controls"].waitForExistence(timeout: 12))
        let renderer = app.descendants(matching: .any)["openclam-shared-3d-renderer"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 12))
        XCTAssertTrue(NSPredicate(format: "value == %@", "Ready").evaluate(with: renderer)
            || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"),
                object: renderer)], timeout: 60) == .completed, "The model must finish rendering before wardrobe interaction")
        openWardrobe()
        func choose(_ group: String, _ choice: String) {
            let picker = app.descendants(matching: .any)["openclam-3d-choice-\(group)"]
            XCTAssertTrue(picker.waitForExistence(timeout: 8))
            picker.tap()
            let option = app.buttons[choice]
            XCTAssertTrue(option.waitForExistence(timeout: 4))
            option.tap()
            sleep(1)
        }
        let cursorSwitch = app.switches["openclam-3d-followCursor"]
        XCTAssertTrue(cursorSwitch.waitForExistence(timeout: 8))
        if !cursorSwitch.isHittable { app.swipeUp() }
        let initialCursor = cursorSwitch.value as? String
        cursorSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(cursorSwitch.value as? String, initialCursor)
        cursorSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(cursorSwitch.value as? String, initialCursor)
        let playbackSwitch = app.switches["openclam-3d-playTransitions"]
        if playbackSwitch.value as? String != "1" { playbackSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(playbackSwitch.value as? String, "1")
        choose("outfit", "Casual · T-shirt & jeans")
        choose("body", "Heart")
        XCTAssertEqual(playbackSwitch.value as? String, "0", "A chosen pose must pause playback")
        capture("wardrobe-casual-heart")
        choose("outfit", "Dress & heels")
        choose("body", "Standing · 3")
        capture("wardrobe-dress-standing")
        choose("prop", "FN SCAR 20S")
        playbackSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(playbackSwitch.value as? String, "1")
        XCTAssertTrue(app.descendants(matching: .any)["openclam-3d-choice-prop"].label.contains("FN SCAR 20S"))
        sleep(5)
        XCTAssertTrue(app.descendants(matching: .any)["openclam-3d-choice-prop"].label.contains("FN SCAR 20S"), "A transition must keep the prop equipped")
        capture("wardrobe-rifle")
        choose("prop", "Unica 6")
        XCTAssertEqual(playbackSwitch.value as? String, "1", "Selecting another prop must keep playback on")
        app.buttons["Done"].tap()
        openWardrobe()
        XCTAssertTrue(playbackSwitch.waitForExistence(timeout: 8))
        XCTAssertEqual(playbackSwitch.value as? String, "1")
        XCTAssertTrue(app.descendants(matching: .any)["openclam-3d-choice-prop"].label.contains("Unica 6"))
        let reset = app.buttons["openclam-3d-appearance-reset"]
        // Reopening returns to the medium detent; Form creates lower rows on scroll.
        for _ in 0 ..< 3 where !reset.exists || !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.waitForExistence(timeout: 8))
        reset.tap()
        app.buttons["Done"].tap()
        sleep(2)
        capture("wardrobe-original-reset")
        app.terminate()
        app.launch()
        let cachedRenderer = app.descendants(matching: .any)["openclam-shared-3d-renderer"]
        XCTAssertTrue(cachedRenderer.waitForExistence(timeout: 12))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"), object: cachedRenderer)], timeout: 20), .completed,
            "Reopening must render from the prepared texture cache")
        capture("wardrobe-cached-relaunch")
    }

    /// Run against a private 3D fixture without extras.openclamAvatar.
    func testWardrobeEntryForLegacyPackage() throws {
        app.terminate()
        app.launchArguments += ["-ai.provider.settings.v2.active-avatar.v1", avatarID + "-legacy",
            "-captainAyer.overlay.mode", "standby", "-captainAyer.overlay.hidden", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["openclam-3d-controls"].waitForExistence(timeout: 12))
        sleep(5)
        openWardrobe()
        guard app.staticTexts["openclam-3d-library-missing"].waitForExistence(timeout: 8) else {
            throw XCTSkip("Install a legacy 3D avatar without a wardrobe library for this test.")
        }
        let importer = app.buttons["openclam-3d-import-wardrobe"]
        XCTAssertTrue(importer.exists && importer.isEnabled)
        capture("wardrobe-legacy-import")
        importer.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 8), "The import action must open Files")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(importer.waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
    }

    private func openWardrobe() {
        let entry = app.descendants(matching: .any)["Wardrobe & Poses"]
        // A rail tap during its idle fade can wake it without opening its menu.
        // Retry only while the menu is closed, as a second tap closes it.
        for _ in 0 ..< 3 where !entry.exists {
            unfoldAvatarRail()
            app.descendants(matching: .any)["openclam-3d-controls"].tap()
            _ = entry.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(entry.exists)
        entry.tap()
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
        let controls = app.descendants(matching: .any)["openclam-3d-controls"]
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

/// Unlike the interaction suite, this never prelaunches the app in setUp.
/// The release audit clears only this simulator's 3DTextures cache beforehand.
final class OpenClam3DColdLaunchUITests: XCTestCase {
    func testColdLaunchRendersWithoutOpeningControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ai.provider.settings.v2.active-avatar.v1", "tia",
            "-captainAyer.overlay.mode", "standby",
            "-captainAyer.overlay.interactionLayer", "avatar",
            "-captainAyer.overlay.opacity", "1", "-captainAyer.overlay.hidden", "NO"]
        app.launch()
        let renderer = app.descendants(matching: .any)["openclam-shared-3d-renderer"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"), object: renderer)], timeout: 120), .completed,
            "A cold launch must finish without tapping 3D controls or Retry")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "3d-cold-launch-no-taps"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"), object: renderer)], timeout: 30), .completed)
        app.terminate()
    }
}
