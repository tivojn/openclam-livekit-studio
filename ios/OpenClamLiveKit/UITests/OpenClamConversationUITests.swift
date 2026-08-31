import XCTest

final class OpenClamConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-OpenClamUITestCleanDeletableAvatar",
        ]
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

        openSettingsThroughSidebar()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Chat & tap-to-talk AI"].exists)
        XCTAssertTrue(app.staticTexts["Screen & Shared Context"].exists)
        capture("settings")
    }

    func testAssistantResponseExposesSelectionCopyAndReadAloudControls() throws {
        app.terminate()
        app.launchArguments.append("-OpenClamUITestHoldSpeechPreparation")
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))

        // This journey validates chat controls, not avatar manipulation. Put
        // the thread layer in front so a wide avatar remains visible without
        // owning the response-action hit area.
        putThreadLayerInFront()

        let selectableText = app.textViews.matching(
            identifier: "openclam-selectable-message-text"
        ).firstMatch
        XCTAssertTrue(
            selectableText.waitForExistence(timeout: 3),
            "Assistant text must use the native selectable text surface."
        )

        let copy = try XCTUnwrap(
            firstHittableButton(label: "Copy assistant response", timeout: 3),
            "The visible assistant response must expose Copy."
        )
        let readAloud = try XCTUnwrap(
            firstHittableButton(label: "Read assistant response aloud", timeout: 3),
            "The visible assistant response must expose Read Aloud."
        )
        XCTAssertTrue(readAloud.isEnabled)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertGreaterThanOrEqual(readAloud.frame.height, 44)
        let readAloudIdentifier = readAloud.identifier

        copy.tap()
        XCTAssertTrue(selectableText.exists)

        let readAloudControl = app.buttons[readAloudIdentifier]
        XCTAssertTrue(readAloudControl.waitForExistence(timeout: 2))
        readAloudControl.tap()
        let stopSpeaking = app.buttons[readAloudIdentifier]
        let stopLabelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Stop speaking"),
            object: stopSpeaking
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopLabelExpectation], timeout: 3),
            .completed,
            "Per-response Read Aloud must become cancellable while speech prepares or plays."
        )
        XCTAssertEqual(stopSpeaking.identifier, readAloudIdentifier)
        stopSpeaking.tap()
        let readAgain = app.buttons[readAloudIdentifier]
        let readAgainExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Read assistant response aloud"),
            object: readAgain
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [readAgainExpectation], timeout: 2),
            .completed
        )
        capture("assistant-response-actions")
    }

    func testLocalReadAloudKeepsAvatarSpeechControlsResponsive() throws {
        unfoldAvatarRail()
        let opacityControl = app.buttons["openclam-avatar-opacity-control"]
        XCTAssertTrue(opacityControl.waitForExistence(timeout: 3))
        if opacityControl.label == "Open opacity control" {
            opacityControl.tap()
        }
        let opacity = app.sliders["openclam-avatar-opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 3))
        XCTAssertTrue(opacity.isHittable)
        app.buttons["openclam-avatar-opacity-control"].tap()
        XCTAssertTrue(opacity.waitForNonExistence(timeout: 2))

        // Normalize the first pass to the face crop. This makes the smoke a
        // repeatable visual oracle for mouth/head stability even when a prior
        // UI test or user session persisted full-body framing.
        selectAvatarMode("Close-up")

        func exerciseSpeech(_ attachmentName: String) {
            let play = app.buttons["Play latest reply"]
            XCTAssertTrue(play.waitForExistence(timeout: 3))
            play.tap()

            let stop = app.buttons["Stop speaking"]
            XCTAssertTrue(
                stop.waitForExistence(timeout: 3),
                "Read-aloud must enter the speaking state so avatar lip sync is exercised."
            )
            capture(attachmentName)

            // Assert and cancel the control while the current utterance is
            // active. Waiting a fixed three seconds made this depend on the
            // persisted reply length rather than the speech lifecycle.
            XCTAssertTrue(stop.isHittable)
            stop.tap()
            XCTAssertTrue(play.waitForExistence(timeout: 3))
        }

        exerciseSpeech("avatar-speaking-closeup")

        selectAvatarMode("Standby")
        exerciseSpeech("avatar-speaking-full-body")
    }

    func testComposerKeyboardDoesNotHideNavigationOrModelChooser() throws {
        XCTAssertFalse(app.buttons["Text to speech"].exists)
        let modelMenu = app.buttons["Language model"]
        XCTAssertFalse(
            modelMenu.exists,
            "The collapsed composer must keep provider and model details hidden."
        )

        let attachmentMenu = app.buttons["openclam-attachment-menu"]
        XCTAssertTrue(attachmentMenu.waitForExistence(timeout: 3))
        let compactPrompt = app.buttons["Message the AI assistant"]
        XCTAssertTrue(compactPrompt.waitForExistence(timeout: 3))
        let compactAction = app.buttons["Start tap to talk"]
        XCTAssertTrue(compactAction.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(
            compactAction.frame.maxX - attachmentMenu.frame.minX,
            app.frame.width * 0.78,
            "The resting composer should float at a normal near-full-screen width."
        )
        XCTAssertGreaterThanOrEqual(
            compactPrompt.frame.width,
            app.frame.width * 0.40,
            "Hiding model details should give the resting prompt the freed composer width."
        )
        attachmentMenu.tap()
        XCTAssertTrue(app.buttons["Take Photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Choose photo or video"].exists)
        XCTAssertTrue(app.buttons["Choose file"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        if compactPrompt.waitForExistence(timeout: 1) {
            compactPrompt.tap()
        }

        let composer = app.textFields["Message the AI assistant"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        composer.typeText("Keyboard layout check")

        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons["openclam-tts-button"].exists,
            "Speech belongs in the avatar rail, not inside either composer state."
        )
        XCTAssertTrue(app.buttons["Open sidebar"].isHittable)
        XCTAssertTrue(app.buttons["openclam-avatar-rail-fold-button"].isHittable)

        XCTAssertTrue(modelMenu.exists)
        XCTAssertTrue(modelMenu.isHittable)
        XCTAssertGreaterThanOrEqual(modelMenu.frame.height, 44)

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        let controls = [attachmentMenu, modelMenu, send]
        for control in controls {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertEqual(control.frame.midY, send.frame.midY, accuracy: 1)
        }
        XCTAssertLessThanOrEqual(
            composer.frame.maxY,
            send.frame.minY - 4,
            "The text editor's own padding must not displace or overlap the bottom controls."
        )
        XCTAssertLessThanOrEqual(
            send.frame.maxY,
            app.keyboards.element.frame.minY - 5,
            "The safe-area composer must remain visibly raised above the software keyboard."
        )
        capture("keyboard-and-composer")

        app.buttons["Open sidebar"].tap()
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 3))
    }

    func testModelMenuOffersProviderChoicesAndAISettings() throws {
        let modelMenu = app.buttons["Language model"]
        XCTAssertFalse(
            modelMenu.exists,
            "The model chooser must remain hidden until the composer is focused."
        )

        let compactPrompt = app.buttons["Message the AI assistant"]
        if compactPrompt.waitForExistence(timeout: 1) {
            compactPrompt.tap()
        } else {
            let composer = app.textFields["Message the AI assistant"]
            XCTAssertTrue(composer.waitForExistence(timeout: 2))
            composer.tap()
        }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
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
        unfoldAvatarRail()
        XCTAssertTrue(
            app.buttons["openclam-live-talk-rail-button"].waitForExistence(timeout: 2)
        )
        capture("conversation-single-live-talk-phone")

        openSettingsThroughSidebar()
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

    func testImportedAvatarDeleteCancelConfirmFallbackAndRelaunchPersistence() throws {
        let fixtureID = "ui-test-deletable-avatar"
        let fixtureName = "UI Test Imported Avatar"

        app.terminate()
        app.launchArguments.append("-OpenClamUITestSeedDeletableAvatar")
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))

        openSettingsThroughSidebar()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))

        let fixtureCard = app.descendants(matching: .any)[
            "openclam-avatar-agent-\(fixtureID)"
        ]
        XCTAssertTrue(fixtureCard.waitForExistence(timeout: 3))
        XCTAssertTrue(fixtureCard.label.contains("IMPORTED"))
        fixtureCard.tap()
        XCTAssertTrue(app.navigationBars[fixtureName].waitForExistence(timeout: 3))

        let makeActive = app.buttons["Make this the active agent"]
        XCTAssertTrue(makeActive.waitForExistence(timeout: 2))
        makeActive.tap()
        XCTAssertTrue(
            app.navigationBars[fixtureName].waitForNonExistence(timeout: 5),
            "Activating an avatar should dismiss settings and return to its conversation."
        )
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 3))
        openSettingsThroughSidebar()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))
        XCTAssertTrue(fixtureCard.waitForExistence(timeout: 3))
        XCTAssertTrue(fixtureCard.label.contains("ACTIVE"))
        fixtureCard.tap()
        XCTAssertTrue(app.navigationBars[fixtureName].waitForExistence(timeout: 3))

        let deleteControl = app.buttons["openclam-avatar-editor-delete"]
        let formScrollStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.12, dy: 0.76)
        )
        let formScrollEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.12, dy: 0.24)
        )
        for _ in 0..<18 where !deleteControl.exists || !deleteControl.isHittable {
            formScrollStart.press(forDuration: 0.05, thenDragTo: formScrollEnd)
        }
        XCTAssertTrue(deleteControl.exists)
        XCTAssertTrue(deleteControl.isHittable)

        deleteControl.tap()
        let confirmDelete = app.buttons["Delete \(fixtureName)"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        // iOS 26 presents this confirmation as a popover and omits the
        // explicit cancel row in compact simulator automation. Tapping the
        // system dismiss region is the platform's cancel action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.62)).tap()
        XCTAssertTrue(confirmDelete.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars[fixtureName].exists)
        XCTAssertTrue(deleteControl.exists)

        deleteControl.tap()
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        confirmDelete.tap()
        XCTAssertTrue(app.navigationBars[fixtureName].waitForNonExistence(timeout: 5))
        unfoldAvatarRail()
        let activeAvatar = app.buttons["Choose avatar"]
        XCTAssertTrue(activeAvatar.waitForExistence(timeout: 5))
        XCTAssertEqual(activeAvatar.value as? String, "Captain Ayer")

        openSettingsThroughSidebar()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))
        XCTAssertTrue(fixtureCard.waitForNonExistence(timeout: 3))

        let captainAyer = app.descendants(matching: .any)[
            "openclam-avatar-agent-captain-ayer"
        ]
        XCTAssertTrue(captainAyer.waitForExistence(timeout: 2))
        XCTAssertTrue(
            captainAyer.label.contains("ACTIVE"),
            "Deleting the selected imported avatar must fall back to Captain Ayer."
        )

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
        openSettingsThroughSidebar()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)[
            "openclam-avatar-agent-settings-link"
        ].tap()
        XCTAssertTrue(app.navigationBars["Avatar Agents"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "openclam-avatar-agent-\(fixtureID)"
            ].waitForExistence(timeout: 1),
            "A confirmed deletion must remain deleted after relaunch."
        )
        let relaunchedAyer = app.descendants(matching: .any)[
            "openclam-avatar-agent-captain-ayer"
        ]
        XCTAssertTrue(relaunchedAyer.waitForExistence(timeout: 2))
        XCTAssertTrue(relaunchedAyer.label.contains("ACTIVE"))
        capture("imported-avatar-delete-persisted")
    }

    func testAvatarStartsOnBeneathConversationAndWarmEarIsIndependent() throws {
        // The rail intentionally fades to its idle opacity after a few seconds,
        // and a preceding UI test can leave that timer elapsed. Normalize the
        // rail to its visible, unfolded state without resetting app data.
        unfoldAvatarRail()
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        XCTAssertEqual(foldControl.label, "Fold all tools")
        let railState = try XCTUnwrap(rail.value as? String)
        XCTAssertTrue(
            ["Visible", "Idle"].contains(railState),
            "The expanded rail may legitimately finish its fade while XCTest queries it."
        )
        XCTAssertTrue(app.buttons["Open sidebar"].isHittable)
        XCTAssertTrue(foldControl.isHittable)

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
        XCTAssertTrue(
            waitForValue("Visible", on: rail, timeout: 2),
            "Composer activity should wake the expanded avatar rail."
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.34)).tap()
        XCTAssertTrue(waitForValue("Visible", on: rail, timeout: 2))

        putThreadLayerInFront(fullyTransparent: true)
    }

    func testInvisibleAvatarReturnsPhysicalVerticalSwipesToTheThread() throws {
        startFreshChat()
        for index in 1...4 {
            sendLocalMessage("Thank you — invisible scroll history turn \(index).")
        }

        let latestUser = app.descendants(matching: .any)[
            "openclam-latest-user-message"
        ]
        XCTAssertTrue(latestUser.waitForExistence(timeout: 3))

        putThreadLayerInFront(fullyTransparent: true)

        let before = latestUser.frame.minY
        // A submitted turn is intentionally anchored near the top, so first
        // drag downward toward older history. Keep the physical drag inside
        // the visible thread rather than beginning on the keyboard, which
        // would exercise keyboard gesture handling instead of layer routing.
        let swipeDownStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.20)
        )
        let swipeDownEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.52)
        )
        swipeDownStart.press(forDuration: 0.06, thenDragTo: swipeDownEnd)

        let movedDown = expectation(
            for: NSPredicate { _, _ in
                !latestUser.isHittable || latestUser.frame.minY > before + 44
            },
            evaluatedWith: nil
        )
        wait(for: [movedDown], timeout: 3)
        capture("invisible-avatar-thread-swipe")
    }

    func testNewestUserTurnAnchorsAtTopWithLongHistoryAndDynamicType() throws {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
        startFreshChat()

        for index in 1...5 {
            sendLocalMessage("Thank you — long history turn \(index).")
        }
        let finalTurn = "Thank you for checking this deliberately long final message at the largest accessibility text size. It should stay on the trailing side and begin near the top while leaving room below for the answer."
        sendLocalMessage(finalTurn)

        let thread = app.scrollViews["openclam-conversation-thread"]
        let latestUser = app.descendants(matching: .any)[
            "openclam-latest-user-message"
        ]
        XCTAssertTrue(thread.waitForExistence(timeout: 3))
        XCTAssertTrue(latestUser.waitForExistence(timeout: 3))
        XCTAssertTrue(latestUser.isHittable)
        XCTAssertGreaterThan(
            latestUser.frame.midX,
            app.frame.midX,
            "The submitted user bubble must remain aligned to the trailing side."
        )
        XCTAssertGreaterThanOrEqual(latestUser.frame.minY, thread.frame.minY - 4)
        XCTAssertLessThanOrEqual(
            latestUser.frame.minY,
            thread.frame.minY + 128,
            "The newest submitted turn must be placed near the top of the visible thread."
        )

        let oldGreeting = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Ask anything'")
        ).firstMatch
        XCTAssertTrue(
            !oldGreeting.exists
                || !oldGreeting.isHittable
                || oldGreeting.frame.maxY <= thread.frame.minY,
            "Older entries must be pushed above the visible thread after a new send."
        )
        capture("dynamic-type-user-turn-top-anchor")
    }

    func testVisibleAvatarStageSwipeChangesOpacityAndLeavesCanvasGapsScrollable() throws {
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 3))
        if foldControl.label == "Show all tools" {
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 2))
        }

        putAvatarLayerInFront()

        // A one-finger vertical swipe controls opacity in Standby too. Size
        // and position belong exclusively to the separate two-finger gesture.
        selectAvatarMode("Standby")

        let opacityControl = app.buttons["openclam-avatar-opacity-control"]
        XCTAssertTrue(opacityControl.waitForExistence(timeout: 2))
        if opacityControl.label == "Open opacity control" {
            opacityControl.tap()
        }
        let opacity = app.sliders["openclam-avatar-opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 3))
        XCTAssertTrue(opacity.isHittable)

        // Normalize the persisted slider first, so an upward swipe always has
        // visible range to increase regardless of a prior user preference.
        opacity.adjust(toNormalizedSliderPosition: 0.25)
        let before = String(describing: opacity.value ?? "")
        // This is deliberately an app-coordinate drag through the avatar's
        // left-leg hit region, not the transparent gap between both legs and
        // not a drag on the accessibility Slider.
        let stageStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.43, dy: 0.55)
        )
        let stageEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.43, dy: 0.20)
        )
        stageStart.press(forDuration: 0.06, thenDragTo: stageEnd)

        let didChange = expectation(
            for: NSPredicate { _, _ in
                String(describing: opacity.value ?? "") != before
            },
            evaluatedWith: nil
        )
        wait(for: [didChange], timeout: 2)
        XCTAssertTrue(opacity.exists)

        let opacityAfterStageDrag = String(describing: opacity.value ?? "")
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForValue("Idle", on: rail, timeout: 6))

        // A drag through the left transparent canvas must belong to the
        // conversation scroll view, not the avatar. The thread observer wakes
        // the rail and the opacity semantic value remains unchanged.
        let gapStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.08, dy: 0.56)
        )
        let gapEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.08, dy: 0.31)
        )
        gapStart.press(forDuration: 0.06, thenDragTo: gapEnd)
        XCTAssertTrue(waitForValue("Visible", on: rail, timeout: 2))
        XCTAssertEqual(String(describing: opacity.value ?? ""), opacityAfterStageDrag)

        putThreadLayerInFront(fullyTransparent: true)
        XCTAssertTrue(opacity.exists)
        XCTAssertTrue(String(describing: opacity.value ?? "").contains("0"))
    }

    func testAvatarCarouselActivatesTheFrontCardWithoutAnExtraUseStep() throws {
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 2))
        if foldControl.label == "Show all tools" {
            XCTAssertTrue(foldControl.isHittable)
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        }
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        let chooseAvatar = app.buttons["Choose avatar"]
        XCTAssertTrue(chooseAvatar.exists)
        XCTAssertTrue(chooseAvatar.isEnabled)
        XCTAssertTrue(chooseAvatar.isHittable)
        XCTAssertEqual(chooseAvatar.identifier, "openclam-avatar-picker")
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
        let nextCard = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "openclam-avatar-carousel-card-",
                "Not selected"
            )
        ).firstMatch
        XCTAssertTrue(nextCard.waitForExistence(timeout: 2))
        // The stacked card centers overlap by design. Tap its visibly exposed
        // outer edge so XCUI delivers the physical event to that card rather
        // than to the front card above it.
        let exposedEdgeX = nextCard.frame.midX >= activeFrontCard.frame.midX
            ? 0.90
            : 0.10
        nextCard.coordinate(
            withNormalizedOffset: CGVector(dx: exposedEdgeX, dy: 0.50)
        ).tap()

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

    func testAraUnifiedAvatarModeMenuUsesOnlyValidatedV3Clips() throws {
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 3))
        if foldControl.label == "Show all tools" {
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 2))
        }

        let chooseAvatar = app.buttons["Choose avatar"]
        XCTAssertTrue(chooseAvatar.waitForExistence(timeout: 2))
        chooseAvatar.tap()

        let cards = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openclam-avatar-carousel-card-"
            )
        )
        let cardLabels = Set(cards.allElementsBoundByIndex.map(\.label))
        XCTAssertTrue(
            cardLabels.isSuperset(of: ["Captain Ayer", "Ara"]),
            "The merged picker must always include both shipped avatars."
        )
        XCTAssertFalse(
            app.buttons["openclam-avatar-carousel-card-ui-test-deletable-avatar"].exists,
            "The disposable UI-test avatar must be removed before launch."
        )

        let araCard = app.buttons["openclam-avatar-carousel-card-ara"]
        XCTAssertTrue(araCard.waitForExistence(timeout: 2))
        if String(describing: araCard.value ?? "") == "Not selected" {
            let frontCard = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND value BEGINSWITH %@",
                    "openclam-avatar-carousel-card-",
                    "Selected"
                )
            ).firstMatch
            XCTAssertTrue(frontCard.waitForExistence(timeout: 2))
            let exposedEdgeX = araCard.frame.midX >= frontCard.frame.midX
                ? 0.90
                : 0.10
            araCard.coordinate(
                withNormalizedOffset: CGVector(dx: exposedEdgeX, dy: 0.50)
            ).tap()
            XCTAssertTrue(waitForValue("Selected", on: araCard, timeout: 2))
        }
        araCard.tap()
        XCTAssertTrue(app.buttons["Close avatar carousel"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(waitForValue("Ara", on: chooseAvatar, timeout: 2))

        let modeMenu = app.buttons["openclam-avatar-mode-menu"]
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 2))
        modeMenu.tap()
        XCTAssertTrue(app.buttons["Standby"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Close-up"].exists)
        XCTAssertTrue(app.buttons["Horizon Walk"].exists)
        XCTAssertTrue(app.buttons["Horizon Walk"].isEnabled)
        XCTAssertTrue(app.buttons["Edge Idle"].isEnabled)
        XCTAssertTrue(app.buttons["Moves"].isEnabled)
        app.buttons["Edge Idle"].tap()
        XCTAssertTrue(waitForValue("Edge Idle", on: modeMenu, timeout: 2))
        capture("ara-v3-edge-idle-physical-left-edge")

        selectAvatarMode("Standby")
        XCTAssertTrue(waitForValue("Standby", on: modeMenu, timeout: 2))
    }

    func testAraMotionCannotBlockComposerTapToTalkAndEmptySpeechIsExplained() throws {
        app.terminate()
        app.launchArguments.append("-OpenClamUITestSpeechInputReady")
        app.launch()
        XCTAssertTrue(app.buttons["Open sidebar"].waitForExistence(timeout: 8))
        startFreshChat()
        unfoldAvatarRail()

        let chooseAvatar = app.buttons["Choose avatar"]
        XCTAssertTrue(chooseAvatar.waitForExistence(timeout: 3))
        chooseAvatar.tap()
        let araCard = app.buttons["openclam-avatar-carousel-card-ara"]
        XCTAssertTrue(araCard.waitForExistence(timeout: 2))
        if String(describing: araCard.value ?? "") == "Not selected" {
            let frontCard = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND value BEGINSWITH %@",
                    "openclam-avatar-carousel-card-",
                    "Selected"
                )
            ).firstMatch
            XCTAssertTrue(frontCard.waitForExistence(timeout: 2))
            araCard.coordinate(
                withNormalizedOffset: CGVector(
                    dx: araCard.frame.midX >= frontCard.frame.midX ? 0.90 : 0.10,
                    dy: 0.50
                )
            ).tap()
            XCTAssertTrue(waitForValue("Selected", on: araCard, timeout: 2))
        }
        araCard.tap()
        XCTAssertTrue(app.buttons["Close avatar carousel"].waitForNonExistence(timeout: 2))

        // Recreate the reported overlap with a sustained full-height clip while
        // the composer stays visible. Moves is intentionally a short one-shot,
        // so Edge Idle is the stable UI oracle for hit-testing the composer.
        selectAvatarMode("Close-up")
        selectAvatarMode("Edge Idle")
        let modeMenu = app.buttons["openclam-avatar-mode-menu"]
        XCTAssertTrue(waitForValue("Edge Idle", on: modeMenu, timeout: 2))

        let start = app.buttons["Start tap to talk"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(
            start.isHittable,
            "Visible avatar motion must not intercept the composer microphone."
        )
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let stop = app.buttons["Stop listening and send"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 2),
            "A physical microphone tap must immediately enter the listening state."
        )
        let status = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "tap Stop")
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(status.label.contains("tap Stop"))
        capture("ara-motion-ptt-listening")

        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let error = app.descendants(matching: .any)["openclam-composer-error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 2),
            "An empty dictation must leave visible next-step guidance."
        )
        XCTAssertTrue(error.label.contains("Tap the microphone"))
        capture("ara-motion-ptt-empty-guidance")
    }

    func testThreadUsesRailSafeWidthAndEveryStarterPromptCanScrollIntoView() throws {
        startFreshChat()
        putThreadLayerInFront()

        let text = app.textViews.matching(
            identifier: "openclam-selectable-message-text"
        ).firstMatch
        let liveTalk = app.buttons["openclam-live-talk-rail-button"]
        let fold = app.buttons["openclam-avatar-rail-fold-button"]
        let suggestions = app.scrollViews["openclam-starter-suggestions"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertTrue(liveTalk.waitForExistence(timeout: 3))
        XCTAssertTrue(suggestions.waitForExistence(timeout: 3))
        XCTAssertEqual(liveTalk.frame.width, 44, accuracy: 0.5,
                       "An idle connection halo must not enlarge the rail control's bounds.")
        XCTAssertEqual(liveTalk.frame.height, 44, accuracy: 0.5)
        let expandedTextWidth = text.frame.width
        XCTAssertGreaterThanOrEqual(liveTalk.frame.minX - text.frame.maxX, 8)
        XCTAssertLessThanOrEqual(
            liveTalk.frame.minX - text.frame.maxX,
            16,
            "Assistant text should use the safe lane, without a second empty rail spacer."
        )
        XCTAssertLessThanOrEqual(suggestions.frame.maxX, liveTalk.frame.minX - 8)
        capture("thread-expanded-rail-safe-width")

        fold.tap()
        XCTAssertTrue(waitForLabel("Show all tools", on: fold, timeout: 3))
        let widerText = expectation(
            for: NSPredicate { _, _ in text.frame.width >= expandedTextWidth + 44 },
            evaluatedWith: nil
        )
        wait(for: [widerText], timeout: 3)
        XCTAssertEqual(text.frame.width - expandedTextWidth, 46, accuracy: 2)
        XCTAssertGreaterThanOrEqual(text.frame.maxX, app.frame.maxX - 20)
        capture("thread-folded-rail-normal-width")

        // Exercise the real nested horizontal scroll view in thread-front
        // mode. Do not select a prompt or invoke any network/provider action.
        let promptIDs = ["nearby", "email", "calendar", "ask-anything"]
        var fullyVisible = Set<String>()
        let textYBeforeHorizontalScroll = text.frame.minY
        for _ in 0..<5 {
            for id in promptIDs {
                let chip = app.buttons["openclam-starter-prompt-\(id)"]
                if chip.exists, chip.isHittable,
                   chip.frame.minX >= suggestions.frame.minX - 1,
                   chip.frame.maxX <= suggestions.frame.maxX + 1 {
                    fullyVisible.insert(id)
                }
            }
            if fullyVisible.count == promptIDs.count { break }
            suggestions.swipeLeft()
        }
        XCTAssertEqual(fullyVisible, Set(promptIDs))
        XCTAssertEqual(text.frame.minY, textYBeforeHorizontalScroll, accuracy: 2)
        XCTAssertTrue(app.buttons["openclam-attachment-menu"].exists)
        capture("all-starter-prompts-horizontally-reachable")
    }

    func testLiveTalkUsesOnePersistentPhoneControlOnTheAvatarRail() throws {
        startFreshChat()
        unfoldAvatarRail()

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
        if foldControl.label == "Show all tools" {
            XCTAssertTrue(foldControl.isHittable)
            foldControl.tap()
        }
        XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))

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

        XCTAssertFalse(phone.exists)
        XCTAssertTrue(waitForLabel("Show all tools", on: foldControl, timeout: 3))
        XCTAssertGreaterThanOrEqual(foldControl.frame.width, 44)
        XCTAssertGreaterThanOrEqual(foldControl.frame.height, 44)
        XCTAssertTrue(foldControl.isHittable)
        if accessibilityComposer.exists {
            XCTAssertFalse(rail.frame.intersects(accessibilityComposer.frame))
            XCTAssertLessThanOrEqual(rail.frame.maxY, accessibilityComposer.frame.minY)
        }
        foldControl.tap()
        XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        XCTAssertTrue(phone.waitForExistence(timeout: 2))
        XCTAssertTrue(foldControl.isHittable)
        capture("avatar-rail-fold-show-and-starter-clearance")
    }

    private func putAvatarLayerInFront() {
        unfoldAvatarRail()
        let layer = app.buttons["openclam-avatar-layer-menu"]
        XCTAssertTrue(layer.waitForExistence(timeout: 2))
        if layer.value as? String != "Avatar in front" {
            layer.tap()
            XCTAssertTrue(waitForValue("Avatar in front", on: layer, timeout: 2))
        }
    }

    private func putThreadLayerInFront(fullyTransparent: Bool = false) {
        unfoldAvatarRail()
        let layer = app.buttons["openclam-avatar-layer-menu"]
        XCTAssertTrue(layer.waitForExistence(timeout: 2))
        if layer.value as? String != "Thread in front" {
            layer.tap()
            XCTAssertTrue(waitForValue("Thread in front", on: layer, timeout: 2))
        }
        guard fullyTransparent else { return }
        let opacityControl = app.buttons["openclam-avatar-opacity-control"]
        XCTAssertTrue(opacityControl.waitForExistence(timeout: 2))
        if opacityControl.label == "Open opacity control" { opacityControl.tap() }
        let opacity = app.sliders["openclam-avatar-opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 2))
        opacity.adjust(toNormalizedSliderPosition: 0)
    }

    private func unfoldAvatarRail() {
        let foldControl = app.buttons["openclam-avatar-rail-fold-button"]
        XCTAssertTrue(foldControl.waitForExistence(timeout: 3))
        let rail = app.descendants(matching: .any)["openclam-avatar-tool-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        if foldControl.label == "Show all tools" {
            XCTAssertTrue(foldControl.isHittable)
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        } else if rail.value as? String != "Visible" {
            // An unfolded rail is allowed to fade to Idle. Fold and reopen it
            // so tests that need controls normalize both expansion and opacity.
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Show all tools", on: foldControl, timeout: 3))
            foldControl.tap()
            XCTAssertTrue(waitForLabel("Fold all tools", on: foldControl, timeout: 3))
        }
        XCTAssertEqual(foldControl.label, "Fold all tools")
        XCTAssertTrue(
            ["Visible", "Idle"].contains(rail.value as? String ?? ""),
            "An unfolded rail may finish its idle fade before XCTest reads it."
        )
    }

    private func selectAvatarMode(_ title: String) {
        unfoldAvatarRail()
        let menu = app.buttons["openclam-avatar-mode-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        if String(describing: menu.value ?? "") == title { return }
        menu.tap()
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 2))
        XCTAssertTrue(choice.isEnabled)
        choice.tap()
        XCTAssertTrue(waitForValue(title, on: menu, timeout: 2))
    }

    private func openSettingsThroughSidebar() {
        if app.navigationBars["Settings"].exists { return }

        let sidebarSettings = app.buttons["Sidebar settings"]
        if !sidebarSettings.exists {
            let sidebar = app.buttons["Open sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
            XCTAssertTrue(sidebar.isHittable)
            sidebar.tap()
        }

        XCTAssertTrue(sidebarSettings.waitForExistence(timeout: 3))
        XCTAssertTrue(sidebarSettings.isHittable)
        sidebarSettings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    private func startFreshChat() {
        app.buttons["Open sidebar"].tap()
        XCTAssertTrue(app.textFields["Search chats"].waitForExistence(timeout: 3))
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.isHittable)
        newChat.tap()
        XCTAssertTrue(app.navigationBars["New chat"].waitForExistence(timeout: 3))
    }

    private func firstHittableButton(
        label: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let query = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        )

        repeat {
            if let visible = query.allElementsBoundByIndex.reversed().first(
                where: \.isHittable
            ) {
                return visible
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return nil
    }

    private func sendLocalMessage(_ text: String) {
        let compactPrompt = app.buttons["Message the AI assistant"]
        if compactPrompt.waitForExistence(timeout: 0.5) {
            compactPrompt.tap()
        }

        let composer = app.textFields["Message the AI assistant"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.isHittable)
        composer.tap()
        composer.typeText(text)

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isHittable)
        send.tap()

        let latestUser = app.descendants(matching: .any)[
            "openclam-latest-user-message"
        ]
        let delivered = expectation(
            for: NSPredicate { _, _ in
                latestUser.exists
                    && String(describing: latestUser.value ?? "").contains(text)
            },
            evaluatedWith: nil
        )
        wait(for: [delivered], timeout: 4)
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
