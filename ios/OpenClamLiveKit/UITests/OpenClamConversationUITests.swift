import XCTest

final class OpenClamConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))

        XCTAssertFalse(
            app.staticTexts["Shared context is temporarily unavailable"]
                .waitForExistence(timeout: 1),
            "A clean launch must not be blocked by a speculative shared-context alert."
        )
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testSidebarNewChatAndSettingsRemainReachable() throws {
        app.buttons["Open sidebar"].tap()

        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New chat"].isHittable)
        XCTAssertTrue(app.buttons["Sidebar settings"].isHittable)
        capture("sidebar")

        app.buttons["New chat"].tap()
        XCTAssertTrue(app.navigationBars["New chat"].waitForExistence(timeout: 3))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Chat & tap-to-talk AI"].exists)
        XCTAssertTrue(app.staticTexts["Screen & Shared Context"].exists)
        capture("settings")
    }

    func testComposerKeyboardDoesNotHideNavigationOrModelChooser() throws {
        XCTAssertFalse(app.buttons["Text to speech"].exists)

        let attachmentMenu = app.buttons["openclam-attachment-menu"]
        XCTAssertTrue(attachmentMenu.waitForExistence(timeout: 3))
        attachmentMenu.tap()
        XCTAssertTrue(app.buttons["Take Photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Choose photo or video"].exists)
        XCTAssertTrue(app.buttons["Choose file"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        let compactPrompt = app.buttons["Message the AI assistant"]
        if compactPrompt.waitForExistence(timeout: 1) {
            compactPrompt.tap()
        }

        let composer = app.textFields["Message the AI assistant"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        composer.typeText("Keyboard layout check")

        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["openclam-tts-button"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Open sidebar"].isHittable)
        XCTAssertTrue(app.buttons["Settings"].isHittable)

        let modelMenu = app.buttons["Language model"]
        XCTAssertTrue(modelMenu.exists)
        XCTAssertTrue(modelMenu.isHittable)
        XCTAssertGreaterThanOrEqual(modelMenu.frame.height, 44)
        capture("keyboard-and-composer")

        app.buttons["Open sidebar"].tap()
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 3))
    }

    func testModelMenuOffersProviderChoicesAndAISettings() throws {
        let modelMenu = app.buttons["Language model"]
        XCTAssertTrue(modelMenu.waitForExistence(timeout: 3))
        modelMenu.tap()

        XCTAssertTrue(app.buttons["Manage AI Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["OpenAI"].exists)
        XCTAssertTrue(app.buttons["xAI"].exists)
        capture("model-menu")

        app.buttons["Manage AI Settings"].tap()
        XCTAssertTrue(app.navigationBars["Chat & Tap-to-Talk AI"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Language model"].exists)
    }

    func testChatPTTAndAvatarLiveTalkSettingsExplainTheirBoundaries() throws {
        XCTAssertTrue(
            app.buttons["openclam-live-talk-rail-button"].waitForExistence(timeout: 2)
        )
        capture("conversation-single-live-talk-phone")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Chat & tap-to-talk AI"].exists)
        XCTAssertTrue(app.staticTexts["Avatar agents"].exists)
        capture("settings-ai-boundaries")

        app.descendants(matching: .any)[
            "openclam-chat-ptt-ai-settings-link"
        ].tap()
        XCTAssertTrue(
            app.navigationBars["Chat & Tap-to-Talk AI"].waitForExistence(timeout: 3)
        )
        let mapping = app.descendants(matching: .any)["openclam-chat-ptt-ai-map"]
        XCTAssertTrue(mapping.waitForExistence(timeout: 2))
        let normalizedMapping = mapping.label
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        XCTAssertTrue(
            normalizedMapping.contains("language model typed chat and tap to talk replies")
        )
        XCTAssertTrue(
            normalizedMapping.contains("speech recognition tap to talk microphone only")
        )
        XCTAssertTrue(
            normalizedMapping.contains("text to speech speaker and read aloud replies")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "openclam-open-avatar-live-talk-settings"
            ].exists
        )
        capture("chat-and-ptt-ai-map")

        app.navigationBars["Chat & Tap-to-Talk AI"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))
        let compactLiveTalkSummary = app.descendants(matching: .any)
            .matching(
                identifier: "openclam-avatar-live-talk-summary-captain-ayer"
            )
            .firstMatch
        XCTAssertTrue(compactLiveTalkSummary.exists)
        XCTAssertEqual(
            compactLiveTalkSummary.value as? String,
            "LiveKit managed · Sarah"
        )

        let liveTalkBoundary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Continuous Live Talk")
        ).firstMatch
        let friendlySystemVoice = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "System voice")
        ).firstMatch
        let friendlyAppleDictation = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Speech: Apple Dictation")
        ).firstMatch
        let rawSystemVoice = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "system-voice")
        ).firstMatch
        let rawAppleDictation = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "apple-dictation")
        ).firstMatch
        var sawFriendlySystemVoice = friendlySystemVoice.exists
        var sawFriendlyAppleDictation = friendlyAppleDictation.exists
        var sawRawSystemVoice = rawSystemVoice.exists
        var sawRawAppleDictation = rawAppleDictation.exists
        for _ in 0..<14 where !isVisiblyPresented(liveTalkBoundary) {
            app.swipeUp()
            sawFriendlySystemVoice = sawFriendlySystemVoice || friendlySystemVoice.exists
            sawFriendlyAppleDictation = sawFriendlyAppleDictation || friendlyAppleDictation.exists
            sawRawSystemVoice = sawRawSystemVoice || rawSystemVoice.exists
            sawRawAppleDictation = sawRawAppleDictation || rawAppleDictation.exists
        }
        XCTAssertTrue(
            isVisiblyPresented(liveTalkBoundary),
            "The Continuous Live Talk explanation must be visibly scrolled into the viewport."
        )
        XCTAssertTrue(sawFriendlySystemVoice)
        XCTAssertTrue(sawFriendlyAppleDictation)
        XCTAssertFalse(sawRawSystemVoice)
        XCTAssertFalse(sawRawAppleDictation)
        capture("avatar-agents-live-talk-boundary")

        let captainAyer = app.descendants(matching: .any)[
            "openclam-avatar-agent-captain-ayer"
        ]
        for _ in 0..<14 where !captainAyer.exists || !captainAyer.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(captainAyer.exists && captainAyer.isHittable)
        captainAyer.tap()
        XCTAssertTrue(app.navigationBars["Captain Ayer"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "gpt-5.6-luna")
            ).firstMatch.exists
        )

        enableSwitch("openclam-avatar-custom-voice-toggle")
        scrollToElement("openclam-avatar-voice-provider")
        let voiceProvider = app.descendants(matching: .any)[
            "openclam-avatar-voice-provider"
        ]
        XCTAssertTrue(voiceProvider.waitForExistence(timeout: 2))
        voiceProvider.tap()
        choosePickerValue("xAI")

        scrollToElement("openclam-avatar-voice")
        let avatarVoice = app.descendants(matching: .any)["openclam-avatar-voice"]
        XCTAssertTrue(avatarVoice.waitForExistence(timeout: 2))
        avatarVoice.tap()
        let rex = pickerValueElement("Rex")
        capture("avatar-xai-voice-choices")
        rex.tap()

        scrollToElement("openclam-avatar-custom-stt-toggle")
        enableSwitch("openclam-avatar-custom-stt-toggle")
        scrollToElement("openclam-avatar-stt-provider")
        let sttProvider = app.descendants(matching: .any)[
            "openclam-avatar-stt-provider"
        ]
        XCTAssertTrue(sttProvider.waitForExistence(timeout: 2))
        sttProvider.tap()
        choosePickerValue("xAI")
        scrollToElement("openclam-avatar-stt-model")
        let sttModel = app.descendants(matching: .any)["openclam-avatar-stt-model"]
        XCTAssertTrue(sttModel.waitForExistence(timeout: 2))
        XCTAssertTrue((sttModel.value as? String)?.contains("grok-transcribe") == true)

        scrollToElement("openclam-managed-fish-voice")
        let managedVoice = app.descendants(matching: .any)[
            "openclam-managed-fish-voice"
        ]
        XCTAssertTrue(managedVoice.waitForExistence(timeout: 2))
        XCTAssertTrue((managedVoice.value as? String)?.contains("Sarah") == true)
        managedVoice.tap()
        capture("managed-fish-voice-picker-sarah")
        let fishVoiceNames = [
            "Sarah", "Hannah", "Jordan", "Adrian", "Ethan", "Laura", "Selene",
        ]
        var seenFishVoices = Set<String>()
        for _ in 0..<10 {
            for name in fishVoiceNames
            where pickerValueElementIfPresent(beginningWith: name) != nil {
                seenFishVoices.insert(name)
            }
            if seenFishVoices.count == fishVoiceNames.count { break }
            app.swipeUp()
        }
        XCTAssertEqual(seenFishVoices, Set(fishVoiceNames))
        capture("managed-fish-voice-picker")
        app.navigationBars["Captain Ayer"].tap()
        XCTAssertTrue(waitForHittable(managedVoice, timeout: 2))

        scrollToElement("openclam-live-talk-mode-tts")
        let ttsLiveTalkMode = app.descendants(matching: .any)[
            "openclam-live-talk-mode-tts"
        ]
        ttsLiveTalkMode.tap()
        choosePickerValue("Follow this avatar")
        let byokDisclosure = app.descendants(matching: .any)[
            "openclam-live-talk-byok-tts"
        ]
        XCTAssertTrue(byokDisclosure.waitForExistence(timeout: 2))
        XCTAssertTrue(byokDisclosure.label.contains("xAI key is shared securely"))
        capture("live-talk-follow-avatar-byok-disclosure")

        scrollToEarlierElement("openclam-live-talk-mode-llm")
        let llmLiveTalkMode = app.descendants(matching: .any)[
            "openclam-live-talk-mode-llm"
        ]
        XCTAssertTrue(llmLiveTalkMode.waitForExistence(timeout: 2))
        llmLiveTalkMode.tap()
        _ = pickerValueElement("Follow this avatar")
        capture("live-talk-managed-or-follow-avatar")
    }

    func testAvatarStartsOnBeneathConversationAndWarmEarIsIndependent() throws {
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        XCTAssertEqual(rail.value as? String, "Visible")
        XCTAssertTrue(app.buttons["Open sidebar"].isHittable)
        XCTAssertTrue(app.buttons["Settings"].isHittable)

        let ear = app.buttons["openclam-warm-ear-button"]
        XCTAssertTrue(ear.waitForExistence(timeout: 2))
        let initialEarValue = ear.value as? String
        ear.tap()
        XCTAssertNotEqual(ear.value as? String, initialEarValue)
        XCTAssertTrue(rail.exists)
        capture("avatar-conversation-overlay-and-ear")

        XCTAssertTrue(waitForValue("Idle", on: rail, timeout: 6))
        let compactPrompt = app.buttons["Message the AI assistant"]
        if compactPrompt.exists {
            compactPrompt.tap()
        } else {
            XCTAssertTrue(app.textFields["Message the AI assistant"].waitForExistence(timeout: 2))
            app.textFields["Message the AI assistant"].tap()
        }
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(rail.value as? String, "Idle")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.34)).tap()
        XCTAssertTrue(waitForValue("Visible", on: rail, timeout: 2))

        let hideAvatar = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Hide '")
        ).firstMatch
        XCTAssertTrue(hideAvatar.waitForExistence(timeout: 2))
        hideAvatar.tap()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Show '")
            ).firstMatch.waitForExistence(timeout: 2)
        )

        // With the avatar truly hidden, the thread owns one-finger drags.
        XCTAssertTrue(waitForValue("Idle", on: rail, timeout: 6))
        let scrollStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.30, dy: 0.56)
        )
        let scrollEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.30, dy: 0.32)
        )
        scrollStart.press(forDuration: 0.05, thenDragTo: scrollEnd)
        XCTAssertTrue(waitForValue("Visible", on: rail, timeout: 2))
    }

    func testAvatarCarouselActivatesTheFrontCardWithoutAnExtraUseStep() throws {
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 2))
        if foldControl.label == "Show avatar tools" {
            XCTAssertTrue(foldControl.isHittable)
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold avatar tools", on: foldControl, timeout: 3))
        }
        let chooseAvatar = app.buttons["Choose avatar"]
        XCTAssertTrue(chooseAvatar.exists)
        XCTAssertTrue(chooseAvatar.isEnabled)
        XCTAssertTrue(chooseAvatar.isHittable)
        XCTAssertEqual(chooseAvatar.identifier, "person.2.fill")
        let initialAvatarName = try XCTUnwrap(chooseAvatar.value as? String)

        chooseAvatar.tap()

        let closeCarousel = app.buttons["Close avatar carousel"]
        XCTAssertTrue(closeCarousel.waitForExistence(timeout: 2))
        XCTAssertTrue(rail.waitForNonExistence(timeout: 1))
        XCTAssertFalse(app.buttons["openclam-live-talk-rail-button"].exists)
        XCTAssertTrue(closeCarousel.isHittable)
        XCTAssertGreaterThanOrEqual(closeCarousel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(closeCarousel.frame.height, 44)
        XCTAssertGreaterThanOrEqual(closeCarousel.frame.minY, 150)
        let styleControl = app.buttons["Switch carousel style"]
        XCTAssertTrue(styleControl.exists)
        XCTAssertTrue(styleControl.isHittable)
        XCTAssertGreaterThanOrEqual(styleControl.frame.height, 44)
        XCTAssertGreaterThanOrEqual(styleControl.frame.minY, 150)
        XCTAssertFalse(app.buttons["Use"].exists)
        let selectionGuidance = app.descendants(matching: .any)[
            "openclam-avatar-carousel-selection-guidance"
        ]
        XCTAssertTrue(selectionGuidance.exists)
        XCTAssertLessThan(selectionGuidance.frame.maxY, app.frame.maxY - 84)
        capture("avatar-carousel-direct-selection")

        let activeFrontCard = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "openclam-avatar-carousel-card-",
                "Selected, on stage"
            )
        ).firstMatch
        XCTAssertTrue(activeFrontCard.waitForExistence(timeout: 2))
        let dragStart = activeFrontCard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.62, dy: 0.44)
        )
        let dragEnd = activeFrontCard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.32, dy: 0.44)
        )
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        let selectedCard = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "openclam-avatar-carousel-card-",
                "Selected"
            )
        ).firstMatch
        XCTAssertTrue(selectedCard.waitForExistence(timeout: 2))
        let selectedAvatarName = selectedCard.label
        XCTAssertNotEqual(selectedAvatarName, initialAvatarName)
        selectedCard.tap()

        XCTAssertTrue(closeCarousel.waitForNonExistence(timeout: 2))
        XCTAssertTrue(waitForValue(selectedAvatarName, on: chooseAvatar, timeout: 3))
        XCTAssertTrue(app.buttons["openclam-live-talk-rail-button"].isHittable)
        capture("avatar-carousel-direct-selection-result")
    }

    func testLiveTalkUsesOnePersistentPhoneControlOnTheAvatarRail() throws {
        let phone = app.buttons["openclam-live-talk-rail-button"]
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(phone.waitForExistence(timeout: 3))
        XCTAssertTrue(rail.exists)
        XCTAssertTrue(waitForHittable(phone, timeout: 3))
        XCTAssertEqual(phone.label, "Start Live Talk")
        XCTAssertEqual(
            app.buttons.matching(
                identifier: "openclam-live-talk-rail-button"
            ).count,
            1
        )
        XCTAssertFalse(app.buttons["openclam-live-talk-button"].exists)
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 2))
        if foldControl.label == "Show avatar tools" {
            XCTAssertTrue(foldControl.isHittable)
            foldControl.tap()
        }
        XCTAssertTrue(waitForLabel("Fold avatar tools", on: foldControl, timeout: 3))

        let starterSuggestions = app.scrollViews["openclam-starter-suggestions"]
        let accessibilityComposer = app.textFields["Message the AI assistant"]
        if starterSuggestions.exists {
            XCTAssertLessThanOrEqual(
                starterSuggestions.frame.maxX,
                phone.frame.minX - 8,
                "Starter suggestions must reserve the avatar rail instead of sliding underneath it."
            )
            capture("avatar-rail-starter-clearance")
        } else {
            // Accessibility text sizes intentionally prioritize the compact prompt
            // and composer instead of presenting horizontally scrolling starter chips.
            XCTAssertFalse(starterSuggestions.exists)
            XCTAssertTrue(accessibilityComposer.exists)
            XCTAssertTrue(accessibilityComposer.isHittable)
            XCTAssertFalse(rail.frame.intersects(accessibilityComposer.frame))
            XCTAssertLessThanOrEqual(rail.frame.maxY, accessibilityComposer.frame.minY)
            capture("avatar-rail-accessibility-composer-clearance")
        }

        XCTAssertGreaterThanOrEqual(foldControl.frame.width, 44)
        XCTAssertGreaterThanOrEqual(foldControl.frame.height, 44)
        XCTAssertTrue(foldControl.isHittable)
        foldControl.tap()

        XCTAssertTrue(phone.exists)
        XCTAssertTrue(waitForHittable(phone, timeout: 3))
        XCTAssertTrue(waitForLabel("Show avatar tools", on: foldControl, timeout: 3))
        XCTAssertGreaterThanOrEqual(foldControl.frame.width, 44)
        XCTAssertGreaterThanOrEqual(foldControl.frame.height, 44)
        XCTAssertTrue(foldControl.isHittable)
        if accessibilityComposer.exists {
            XCTAssertFalse(rail.frame.intersects(accessibilityComposer.frame))
            XCTAssertLessThanOrEqual(rail.frame.maxY, accessibilityComposer.frame.minY)
        }
        foldControl.tap()
        XCTAssertTrue(waitForLabel("Fold avatar tools", on: foldControl, timeout: 3))
        XCTAssertTrue(foldControl.isHittable)
        capture("avatar-rail-fold-show-and-starter-clearance")
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = expectation(
            for: NSPredicate(format: "value == %@", value),
            evaluatedWith: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = expectation(
            for: NSPredicate(format: "exists == true AND hittable == true"),
            evaluatedWith: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = expectation(
            for: NSPredicate(format: "label == %@", label),
            evaluatedWith: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func choosePickerValue(_ value: String) {
        pickerValueElement(value).tap()
    }

    private func pickerValueElement(_ value: String) -> XCUIElement {
        let text = app.staticTexts[value]
        if text.waitForExistence(timeout: 2) {
            return text
        }
        let button = app.buttons[value]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        return button
    }

    private func pickerValueElementIfPresent(beginningWith value: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", value)
        let text = app.staticTexts.matching(predicate).firstMatch
        if text.exists { return text }
        let button = app.buttons.matching(predicate).firstMatch
        return button.exists ? button : nil
    }

    private func enableSwitch(_ identifier: String) {
        scrollToElement(identifier)
        let toggle = app.switches.matching(identifier: identifier).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        if toggle.value as? String != "1" {
            XCTAssertTrue(toggle.isHittable)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        }
        XCTAssertTrue(waitForValue("1", on: toggle, timeout: 2))
    }

    private func scrollToElement(_ identifier: String) {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<6
        where !element.exists
            || !element.isHittable
            || element.frame.maxY > app.frame.maxY - 8
        {
            app.swipeUp()
        }
        XCTAssertTrue(
            element.exists
                && element.isHittable
                && element.frame.maxY <= app.frame.maxY - 8,
            "Could not fully reveal \(identifier)"
        )
    }

    private func scrollToEarlierElement(_ identifier: String) {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<6
        where !element.exists
            || !element.isHittable
            || element.frame.minY < 8
        {
            app.swipeDown()
        }
        XCTAssertTrue(
            element.exists
                && element.isHittable
                && element.frame.minY >= 8,
            "Could not fully reveal earlier element \(identifier)"
        )
    }

    private func isVisiblyPresented(_ element: XCUIElement) -> Bool {
        guard element.exists, !element.frame.isEmpty else { return false }
        return element.frame.intersects(app.frame.insetBy(dx: 0, dy: 100))
    }
}
