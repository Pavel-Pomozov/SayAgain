import XCTest

final class CommunicationFlowUITests: XCTestCase {
    @MainActor private func launch(capture: Bool = false, onboarding: Bool = false, largeType: Bool = false, camera: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if !onboarding { app.launchArguments += ["--skip-onboarding"] }
        if capture { app.launchArguments += ["--ui-test-capture"] }
        if camera { app.launchArguments += ["--ui-test-camera"] }
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor private func enable(_ toggle: XCUIElement, in app: XCUIApplication) {
        reveal(toggle, in: app)
        if toggle.value as? String != "1" {
            // Target the native switch track, not the wide Form label container.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let enabled = NSPredicate(format: "value == '1'")
        expectation(for: enabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 4)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Enabled preference"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let hittable = NSPredicate(format: "isHittable == true")
        expectation(for: hittable, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    @MainActor func testBackNavigationPreservesSpeechClue() {
        let app = launch(capture: true)
        app.buttons["Help Me Say It"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        XCTAssertTrue(app.buttons["Water"].waitForExistence(timeout: 3))
        app.buttons["backToReview"].tap()
        XCTAssertTrue(app.staticTexts["“water”"].waitForExistence(timeout: 3))
        app.buttons["Use This"].tap()
        app.buttons["Water"].tap()
        app.buttons["backToSuggestions"].tap()
        XCTAssertTrue(app.buttons["Water"].waitForExistence(timeout: 3))
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        app.buttons["backToPhrases"].tap()
        XCTAssertTrue(app.buttons["I want water."].waitForExistence(timeout: 3))
        app.buttons["backToSuggestions"].tap()
        app.buttons["backToReview"].tap()
        app.buttons["Edit"].tap()
        // Use a stable ID: SwiftUI's vertical input has differing modern and
        // legacy automation types, and populated inputs lose placeholders.
        let field = app.descendants(matching: .any)["communicationClueInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        app.buttons["Clear Text"].tap()
        field.tap()
        field.typeText("coffee")
        app.buttons["Use Clue"].tap()
        XCTAssertTrue(app.staticTexts["“coffee”"].waitForExistence(timeout: 3))
        app.buttons["Use This"].tap()
        XCTAssertTrue(app.buttons["Coffee"].waitForExistence(timeout: 3))
    }

    @MainActor func testSuggestionsOfferPhotoAndTypedCluesWithoutDrawing() {
        let app = launch(capture: true)
        app.buttons["Help Me Say It"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        XCTAssertTrue(app.buttons["Add a visual clue"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Type a clue"].exists)
        XCTAssertFalse(app.buttons["Draw a clue"].exists)
    }

    @MainActor func testPlaybackControlFrameStaysFixedAcrossStates() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-playback-layout"]
        app.launch()
        let playback = app.buttons["speechPlaybackControl"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        let idleFrame = playback.frame
        XCTAssertTrue(playback.label.contains("Replay"))

        app.buttons["Set Preparing"].tap()
        XCTAssertTrue(playback.label.contains("Stop"))
        let preparingFrame = playback.frame

        app.buttons["Set Speaking"].tap()
        let speakingFrame = playback.frame
        app.buttons["Set Idle"].tap()
        let completedFrame = playback.frame

        XCTAssertEqual(preparingFrame.minY, idleFrame.minY, accuracy: 1)
        XCTAssertEqual(speakingFrame.minY, idleFrame.minY, accuracy: 1)
        XCTAssertEqual(completedFrame.minY, idleFrame.minY, accuracy: 1)
        XCTAssertEqual(preparingFrame.height, idleFrame.height, accuracy: 1)
        XCTAssertEqual(speakingFrame.height, idleFrame.height, accuracy: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Stable speech control layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testRetakeCancelPreservesPhotoReview() {
        let app = launch(capture: true, camera: true)
        app.buttons["Help Me Say It"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["I heard"].waitForExistence(timeout: 3))
        let useThis = app.buttons["Use This"]
        waitUntilHittable(useThis)
        useThis.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addVisualClue = app.buttons["Add a visual clue"]
        waitUntilHittable(addVisualClue)
        addVisualClue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Open Camera"].tap()
        app.buttons["Capture Test Photo"].tap()
        XCTAssertTrue(app.buttons["Take Another Photo"].waitForExistence(timeout: 10))
        let retake = app.buttons["Take Another Photo"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: retake)
        waitForExpectations(timeout: 15)
        retake.tap()
        app.buttons["cancelCameraFixture"].tap()
        XCTAssertTrue(app.navigationBars["Review Photo Clue"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Take Another Photo"].exists)
        XCTAssertFalse(app.buttons["Open Camera"].exists)
    }

    @MainActor func testListeningDoneAndCancel() {
        let app = launch(capture: true)
        app.buttons["Help Me Say It"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Test capture fixture · Microphone Off"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["I heard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["“water”"].exists)
        let review = XCTAttachment(screenshot: app.screenshot()); review.name = "Transcript review"; review.lifetime = .keepAlways; add(review)
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        waitUntilHittable(cancel)
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["SayAgain"].waitForExistence(timeout: 5))
    }
    @MainActor func testTypedClueLiteralPhraseAndDone() {
        let app = launch()
        app.buttons["Help Me Say It"].tap()
        app.buttons["Type a Clue"].tap()
        let field = app.textFields["Type any part you can."]
        if field.waitForExistence(timeout: 2) { field.tap(); field.typeText("water") }
        else { let multiline = app.textViews.firstMatch; XCTAssertTrue(multiline.waitForExistence(timeout: 2)); multiline.tap(); multiline.typeText("water") }
        app.buttons["Use Clue"].tap()
        XCTAssertTrue(app.buttons["Use This"].waitForExistence(timeout: 3))
        app.buttons["Use This"].tap()
        XCTAssertTrue(app.buttons["Water"].waitForExistence(timeout: 3))
        app.buttons["Water"].tap()
        app.buttons["Just say “Water.”"].tap()
        XCTAssertTrue(app.staticTexts["Water"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Speak"].exists)
        XCTAssertFalse(app.buttons["Replay"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["SayAgain"].waitForExistence(timeout: 3))
    }
    @MainActor func testTypedMessageIsReviewedVerbatimBeforeSpeaking() {
        let app = launch()
        app.buttons["Say Typed Message"].tap()
        let editor = app.textViews["typedMessageInput"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Please call my sister.")
        app.buttons["Review"].tap()
        XCTAssertTrue(app.staticTexts["Please call my sister."].waitForExistence(timeout: 3))
        app.buttons["Use This Message"].tap()
        XCTAssertTrue(app.staticTexts["Please call my sister."].waitForExistence(timeout: 3))
        app.buttons["Review"].tap()
        XCTAssertTrue(app.staticTexts["Check the wording before you choose to speak it."].exists)
        app.buttons["Edit Message"].tap()
        XCTAssertEqual(editor.value as? String, "Please call my sister.")
    }
    @MainActor func testTypedClueCanBeEditedAndRemovedFromSuggestions() {
        let app = launch(capture: true)
        app.buttons["Help Me Say It"].tap()
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        app.buttons["Remove Speech Clue"].tap()
        app.buttons["Type a clue"].tap()
        let field = app.descendants(matching: .any)["communicationClueInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("coffee")
        app.buttons["Use Clue"].tap()
        XCTAssertTrue(app.buttons["Coffee"].waitForExistence(timeout: 3))
        app.buttons["Edit Typed Clue"].tap()
        let editField = app.descendants(matching: .any)["communicationClueInput"]
        XCTAssertTrue(editField.waitForExistence(timeout: 3))
        XCTAssertEqual(editField.value as? String, "coffee")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Coffee"].waitForExistence(timeout: 3))
        app.buttons["Remove Typed Clue"].tap()
        XCTAssertTrue(app.buttons["Something Else…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["coffee"].exists)
    }
    @MainActor func testQuickNeedsAndPainWithoutCapture() {
        let app = launch()
        app.buttons["Quick Needs"].tap()
        app.buttons["NO"].tap()
        XCTAssertTrue(app.staticTexts["No."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Speak"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Quick Needs"].waitForExistence(timeout: 3))
        app.buttons["PAIN"].tap()
        let simplePain = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "I am in pain")).firstMatch
        XCTAssertTrue(simplePain.waitForExistence(timeout: 3))
        simplePain.tap()
        XCTAssertTrue(app.staticTexts["I am in pain."].waitForExistence(timeout: 3))
        app.buttons["Speak"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Quick Needs"].waitForExistence(timeout: 3))
        app.buttons["PAIN"].tap()
        app.buttons["Add details"].tap()
        app.buttons["Left Arm"].tap()
        app.buttons["Severe"].tap()
        let emergencySwitch = app.switches["This is an emergency"]
        XCTAssertTrue(emergencySwitch.waitForExistence(timeout: 3))
        if emergencySwitch.value as? String != "1" {
            emergencySwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(emergencySwitch.value as? String, "1")
        app.buttons["Review Message"].tap()
        XCTAssertTrue(app.staticTexts["This is an emergency. I have severe pain in my left arm."].waitForExistence(timeout: 3))
        app.buttons["Speak"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 15))
        app.buttons["Replay"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 3))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 3))
    }
    @MainActor func testPersonalWordSaveAndCancel() {
        let app = launch()
        app.buttons["Personal Words"].tap()
        app.buttons["Add a personal word"].tap()
        let field = app.textFields["Word or name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("Sarah")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Sarah"].waitForExistence(timeout: 3))
        app.buttons["Sarah"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText(" changed")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Sarah"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Sarah changed"].exists)
        app.buttons["Sarah"].tap()
        let newPhrase = app.textFields["Write a phrase"]
        for _ in 0..<4 { if newPhrase.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(newPhrase.waitForExistence(timeout: 3))
        newPhrase.tap(); newPhrase.typeText("Please call Sarah.")
        // Save commits text that remains in the phrase editor field.
        app.buttons["Save"].tap()
        app.buttons["Sarah"].tap()
        let savedPhrase = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "personalPhrase-")).firstMatch
        for _ in 0..<4 { if savedPhrase.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(savedPhrase.waitForExistence(timeout: 3))
        savedPhrase.tap(); savedPhrase.typeText(" changed")
        app.buttons["Cancel"].tap()
        app.buttons["Sarah"].tap()
        for _ in 0..<4 { if savedPhrase.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(savedPhrase.value as? String, "Please call Sarah.")
        app.buttons["Cancel"].tap()
    }
    @MainActor func testOnboardingAndSettingsExplanation() {
        let app = launch(onboarding: true)
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 3))
        app.buttons["Skip"].tap()
        app.buttons["Settings"].tap()
        let explanation = app.buttons["What SayAgain does"]
        for _ in 0..<6 {
            if explanation.exists && explanation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        explanation.tap()
        XCTAssertTrue(app.navigationBars["What SayAgain does"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Share a clue")).firstMatch.exists)
    }
    @MainActor func testOfflineDemoRequiresHumanSelections() {
        let app = launch()
        app.buttons["Offline Demo"].tap()
        app.buttons["Begin breakfast demo"].tap()
        XCTAssertTrue(app.staticTexts["“wa...”"].exists)
        XCTAssertTrue(app.staticTexts["Example speech clue · Microphone Off"].exists)
        app.buttons["Add a visual clue"].tap()
        XCTAssertTrue(app.staticTexts["Example visual labels: glass, drink"].exists)
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        XCTAssertTrue(app.staticTexts["I want water."].exists)
        XCTAssertTrue(app.buttons["Speak"].exists)
        XCTAssertFalse(app.buttons["Replay"].exists)
        app.buttons["Speak"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 20))
        app.buttons["Finish Example"].tap()
        app.buttons["Try the Sarah example"].tap()
        app.buttons["Sarah"].tap()
        XCTAssertTrue(app.buttons["Please call Sarah."].exists)
        app.buttons["Please call Sarah."].tap()
        XCTAssertTrue(app.staticTexts["Please call Sarah."].exists)
        app.buttons["demoBack"].tap()
        XCTAssertTrue(app.buttons["Please call Sarah."].exists)
        app.buttons["Please call Sarah."].tap()
        app.buttons["Finish Example"].tap()
        app.buttons["Restart Demo"].tap()
        XCTAssertTrue(app.buttons["Begin breakfast demo"].exists)
        app.buttons["closeDemo"].tap()
        XCTAssertTrue(app.navigationBars["SayAgain"].waitForExistence(timeout: 3))
    }

    @MainActor func testOfflineDemoTypedMessageIsReviewedBeforeSpeaking() {
        let app = launch()
        app.buttons["Offline Demo"].tap()
        let typedEntry = app.buttons["demoTypedMessageEntry"]
        XCTAssertTrue(typedEntry.waitForExistence(timeout: 3))
        typedEntry.tap()
        let editor = app.textViews["demoTypedMessageInput"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("I need a quiet moment.")
        app.buttons["demoReviewTypedMessage"].tap()
        XCTAssertTrue(app.staticTexts["I need a quiet moment."].waitForExistence(timeout: 3))
        app.buttons["demoContinueTypedMessage"].tap()
        XCTAssertTrue(app.buttons["Speak"].exists)
        XCTAssertFalse(app.buttons["Replay"].exists)
        app.buttons["Speak"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 20))
        app.buttons["Review"].tap()
        XCTAssertTrue(app.staticTexts["I need a quiet moment."].exists)
        app.buttons["Edit"].tap()
        XCTAssertEqual(editor.value as? String, "I need a quiet moment.")
    }

    @MainActor func testWithdrawnChoiceIsNotLearnedOrSaved() {
        let app = launch(capture: true)
        app.buttons["Settings"].tap()
        enable(app.switches["learnFromChoices"], in: app)
        enable(app.switches["saveRecentPhrases"], in: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Help Me Say It"].tap()
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        reveal(app.staticTexts["testLearnedCount"], in: app)
        XCTAssertTrue(app.staticTexts["testLearnedCount"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["testLearnedCount"].label, "Learned choices: 0")
        XCTAssertEqual(app.staticTexts["testHistoryCount"].label, "Recent phrases: 0")
    }

    @MainActor func testSpeakCommitsChoiceOnceAndQuickNeedsCanSaveHistory() {
        let app = launch(capture: true)
        app.buttons["Settings"].tap()
        enable(app.switches["learnFromChoices"], in: app)
        enable(app.switches["saveRecentPhrases"], in: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Help Me Say It"].tap()
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        app.buttons["Speak"].tap()
        XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 20))
        app.buttons["Replay"].tap()
        app.buttons["Done"].tap()
        app.buttons["Quick Needs"].tap()
        app.buttons["NO"].tap()
        app.buttons["Speak"].tap()
        app.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Settings"].tap()
        reveal(app.staticTexts["testLearnedCount"], in: app)
        XCTAssertTrue(app.staticTexts["testLearnedCount"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["testLearnedCount"].label, "Learned choices: 1")
        XCTAssertEqual(app.staticTexts["testHistoryCount"].label, "Recent phrases: 2")
    }

    @MainActor func testDemoAndQuickNeedsAtLargestDynamicType() {
        let app = launch(largeType: true)
        let demoButton = app.buttons["Offline Demo"]
        reveal(demoButton, in: app)
        demoButton.tap()
        XCTAssertTrue(app.buttons["Begin breakfast demo"].isHittable)
        app.buttons["Begin breakfast demo"].tap()
        XCTAssertTrue(app.buttons["Add a visual clue"].isHittable)
        app.buttons["Add a visual clue"].tap()
        reveal(app.buttons["Water"], in: app)
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        XCTAssertTrue(app.buttons["Speak"].isHittable)
        XCTAssertTrue(app.buttons["Finish Example"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Demo speech at largest type"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["closeDemo"].tap()
        for _ in 0..<6 { app.swipeDown() }
        reveal(app.buttons["Quick Needs"], in: app)
        app.buttons["Quick Needs"].tap()
        XCTAssertTrue(app.navigationBars["Quick Needs"].waitForExistence(timeout: 3))
        reveal(app.buttons["YES"], in: app)
        XCTAssertTrue(app.buttons["YES"].isHittable)
        reveal(app.buttons["NO"], in: app)
        XCTAssertTrue(app.buttons["NO"].isHittable)
    }

    @MainActor func testVisualClueFullScreenReviewAndTypedFallback() {
        let app = launch(capture: true, camera: true)
        XCTAssertFalse(app.staticTexts["Microphone Off · Camera Off"].exists)
        app.buttons["Help Me Say It"].tap()
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        app.buttons["Add a visual clue"].tap()
        XCTAssertTrue(app.navigationBars["Add a Visual Clue"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Capture Test Photo"].exists)
        app.buttons["Open Camera"].tap()
        XCTAssertTrue(app.staticTexts["Camera test fixture · Camera Off"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Full-screen camera fixture"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Capture Test Photo"].tap()
        XCTAssertTrue(app.navigationBars["Review Photo Clue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["visualClueResult"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.images["Your photo clue. Not saved."].waitForExistence(timeout: 3))
        let review = XCTAttachment(screenshot: app.screenshot()); review.name = "Photo review"; review.lifetime = .keepAlways; add(review)
        app.buttons["Type What’s in the Photo"].tap()
        let field = app.textFields["Type any part you can."]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("glass")
        app.buttons["Use Clue"].tap()
        XCTAssertTrue(app.buttons["Water"].waitForExistence(timeout: 5))
        app.buttons["Water"].tap()
        app.buttons["I want water."].tap()
        XCTAssertTrue(app.staticTexts["I want water."].waitForExistence(timeout: 3))
    }

    @MainActor func testVisualClueCancelLeavesSuggestionsUsable() {
        let app = launch(capture: true, camera: true)
        app.buttons["Help Me Say It"].tap()
        app.buttons["Done"].tap()
        app.buttons["Use This"].tap()
        app.buttons["Add a visual clue"].tap()
        app.buttons["Open Camera"].tap()
        XCTAssertTrue(app.buttons["Capture Test Photo"].waitForExistence(timeout: 3))
        app.buttons["cancelCameraFixture"].tap()
        XCTAssertTrue(app.navigationBars["Add a Visual Clue"].waitForExistence(timeout: 3))
        app.buttons["cancelVisualClue"].tap()
        XCTAssertTrue(app.buttons["Water"].waitForExistence(timeout: 3))
    }

    @MainActor func testListeningControlsAtLargestDynamicType() {
        let app = launch(capture: true, largeType: true)
        app.buttons["Help Me Say It"].tap()
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Listening at largest Dynamic Type"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["SayAgain"].waitForExistence(timeout: 3))
    }
}
