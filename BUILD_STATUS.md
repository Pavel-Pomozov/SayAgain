# Build status

## Playback, performance, and drawing-scope update

**Recorded:** 2026-10-13  
**Environment:** Xcode 26.6 (build 17F113), iOS/iPadOS SDK 26.5, Swift 6 strict concurrency

The Speak/Stop/Replay control is now shared across the main app, offline demo, typed-message output, Quick Needs, and Settings voice preview. Playback has one authoritative `idle` / `preparing` / `speaking` state. The button remains a single view with a fixed footer layout; preparation feedback appears above the footer. The synthesizer is created only for the first explicit playback request and then reused. Settings caches its system voice catalog. Stale callbacks and rapid stop/replay requests are guarded by request identity and cancellation.

Drawing and PencilKit are removed from the app, demo, and current feature descriptions. Photo and typed clues remain. Candidate ranking now uses prepared, normalized vocabulary and indexed usage/mapping snapshots while preserving the existing weights and deterministic tie-break rules. The listening meter limits only UI amplitude publication to 30 updates per second; audio buffers, transcription, watchdogs, Done, and Cancel remain active at their original cadence. Signposts contain operation names and durations only, not communication content.

| Check | Result | Evidence |
| --- | --- | --- |
| SwiftPM package tests | 48 passed, 0 failures: 41 core and 7 audio-driver tests | `swift test --package-path SayAgainChallenge.swiftpm` |
| iPhone 17 Pro / iOS 26.5 full app scheme | 36 passed, 0 failures | `/private/tmp/SayAgain-UI-DD/Logs/Test/Test-SayAgain-2026.10.13_14-30-55--0700.xcresult` |
| iPad Pro 13-inch M5 / iPadOS 26.5 full app scheme, Dark appearance | 36 passed, 0 failures | `/private/tmp/SayAgain-iPad-DD/Logs/Test/Test-SayAgain-2026.10.13_14-37-28--0700.xcresult` |
| iPhone Light appearance, latest shared-button layout regression | 1 passed, 0 failures; same control frame recorded for idle, preparing, and speaking | `/private/tmp/SayAgain-UI-DD/Logs/Test/Test-SayAgain-2026.10.13_14-43-52--0700.xcresult` |
| iPhone 17 Pro / iOS 26.5 UI suite, Dark appearance | 19 passed, 0 failures | `/private/tmp/SayAgain-UI-DD/Logs/Test/Test-SayAgain-2026.10.13_14-46-27--0700.xcresult` |
| iPad Pro 13-inch M5 / iPadOS 26.5 UI suite, Light appearance | 19 passed, 0 failures | `/private/tmp/SayAgain-iPad-DD/Logs/Test/Test-SayAgain-2026.10.13_14-52-30--0700.xcresult` |
| Manual visual spot check | iPad portrait onboarding and Home in Light, Home and Quick Needs phrase output in Dark; no clipping or footer movement observed | Simulator visual review; not a complete screen-by-screen accessibility audit |
| iOS Simulator Release app build | Passed, unsigned | `xcodebuild -project SayAgain.xcodeproj -scheme SayAgain -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` |
| Offline Challenge SwiftPM Release build | Passed | `swift build -c release --package-path SayAgainChallenge.swiftpm` |
| Refreshed Challenge ZIP | About 60 KB; ZIP integrity passed; clean extraction passed all 48 package tests; `.build` and `.swiftpm` caches excluded | `Submission/SayAgainChallenge.zip`; clean extraction at `/private/tmp/SayAgainChallenge-final-clean-20261013` |
| Ranking performance fixture | About 0.007 seconds average for 1,000 terms and 1,000 mappings on this Mac test host | Clean-extraction core performance test; not a physical-iPhone p95 measurement |
| Static source scan | No `TODO`, `FIXME`, `fatalError`, `try!`, or `as!` in Swift source; no active drawing/PencilKit implementation | `rg` source scan, 2026-10-13 |
| Physical-device playback/capture, VoiceOver/Switch Control, standalone playground open/run | Not verified in this update | Requires hands-on device/accessibility and app-playground validation |

The complete schemes passed on iPhone 17 Pro and iPad Pro. Separate 19-case UI suites passed on iPhone Dark and iPad Light, and the shared-button layout regression passed on iPhone Light after the final label-animation change. The initial iPhone full run used the simulator’s default appearance, which was not captured in its result metadata. This is cross-device appearance coverage, not manual validation of every screen at every accessibility configuration. Simulator tests validate layout and control state, not audible output, microphone input, or camera operation on a physical device. Xcode emitted a nonfatal debugger-version diagnostic during simulator launches; it did not affect test results. The refreshed package is verified from a clean extraction, but it has not yet been opened and run through the Xcode or Swift Playgrounds app-playground workflow.

## Reliability implementation update

**Recorded:** 2026-10-13  
**Environment:** Xcode 26.6 (build 17F113), iOS/iPadOS SDK 26.5, Swift 6, strict concurrency; iPhone 17 Pro / iOS 26.5 simulator

This update consolidates shared audio-session ownership for live capture and speech output, scopes capture operations by session ID, handles unexpected speech-result stream termination, drains converted audio at end-of-stream, and moves cancellable deterministic ranking off the UI actor. It also makes spoken-choice correction replace only the current flow’s own learning/history writes, adds built-in vocabulary recency storage through a SwiftData v1→v2 lightweight migration, and shares one speech-output driver between the app and demo. Back navigation keeps accepted clues and candidate results.

| Check | Result | Evidence |
| --- | --- | --- |
| SwiftPM offline core/demo suite | 39 passed, 0 failures (rerun 2026-10-13) | `swift test --package-path SayAgainChallenge.swiftpm` |
| iPhone 17 Pro / iOS 26.5 app unit tests | 17 passed, 0 failures, including v1→v2 store migration and speech capture session tests | `Test-SayAgain-2026.10.13_02-05-39--0700.xcresult` |
| Generic iOS Simulator app build | Passed | `xcodebuild -project SayAgain.xcodeproj -scheme SayAgain -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet` |
| Unsigned iOS device Release build | Passed; 4.6 MB app bundle. Built Info.plist has version 1.0/build 1, iOS 26.0 minimum, microphone/camera usage strings, and no multi-scene manifest. Privacy manifest is in the app bundle. | `Build/Products/Release-iphoneos/SayAgain.app` |
| Simulator launch after single-scene configuration | Passed: installed and launched `org.sayagain.communication` on iPhone 17 Pro / iOS 26.5; app showed the native Home screen | `simctl install` / `simctl launch`, screenshot `/private/tmp/SayAgain-home-20261013.png` |
| Refreshed Challenge ZIP | 54 KB; ZIP integrity passed; clean extracted copy passed 39/39 offline tests; `.build` and `.swiftpm` workspace caches excluded | `Submission/SayAgainChallenge.zip`; extracted under `/private/tmp/SayAgainChallenge-extracted-20261013` |
| Complete iPhone 17 Pro / iOS 26.5 app test scheme | 35 passed, 0 failures: 17 app unit tests and 18 UI tests | `/private/tmp/SayAgain-UI-DD/Logs/Test/Test-SayAgain-2026.10.13_13-22-13--0700.xcresult` |
| Physical device capture, playback, Apple Intelligence, VoiceOver/Switch Control | Not verified in this update | Requires on-device/manual validation |

The first UI run in this update executed 18 cases and exposed three test failures: two controls were tapped before the destination was stably hittable, and the photo test required Vision to return no labels. The UI tests now wait for visible, hittable controls and target their centers; the photo review exposes a stable accessibility identifier for its completed result, and the test accepts whichever valid on-device classification/fallback result occurs. The three affected cases passed on rerun, followed by a complete app test scheme run with 17 unit and 18 UI tests passing (35 total, 0 failures). Xcode continued to print a nonfatal `DebuggerVersionStore` / “no debugger version” diagnostic during simulator launches; it did not prevent test execution. The app’s current Info.plist no longer opts into multi-scene support, matching the single-window v1 decision; Apple documents that a false or absent support setting prevents UIKit from creating multiple scenes ([Info.plist key](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIApplicationSceneManifest/UIApplicationSupportsMultipleScenes)). A simulator install/launch succeeded after this change. Do not interpret simulator results as proof of live mic/camera operation or physical playback. The refreshed Challenge package still needs an independent Xcode/Swift Playgrounds app-playground open-and-run check.

## Latest reliability and competition preparation update

**Recorded:** 2026-10-11  
**Environment:** Xcode 26.6, iOS/iPadOS SDK 26.5, Swift 6, strict concurrency

Implemented direct typed-message composition with verbatim review before Speak; explicit edit/remove controls for speech, typed, photo, and drawing clues; an immediate “I am in pain” phrase plus optional detail flow; emergency wording in the reviewed phrase when the person selects the emergency toggle; and shared-phrase cleanup when a Personal Word is deleted. Personal terms and learned mappings now have deterministic input ordering. Quick Needs and typed messages remain available if the persistent and fallback data stores both fail.

Speech capture now has a recurring audio-arrival watchdog, a retry fallback after input-route removal, and a finalization timeout that is canceled after successful finalization. Speech output stays in a preparing state until AVSpeechSynthesizer confirms playback start, offers a calm retry message if playback does not start within five seconds, and records opt-in learning/history only after playback actually begins. Short utterances that finish before the start callback are recorded from the finish callback.

The standalone Challenge demo now also offers **Say Typed Message** as a separate, offline path. The person enters text, reviews it verbatim, and chooses Speak; playback state follows the synthesizer’s start callback. It does not alter the breakfast ambiguity demo or save typed text.

Competition timing was rechecked on 2026-10-11: Apple’s 2026 Swift Student Challenge deadline has passed, and the next cycle’s rules are not posted here. The 2026 Congressional App Challenge deadline is October 26 at 12:00 p.m. ET; the entrant still needs to verify district eligibility and prepare the required demonstration video and personally authored answers. See `SUBMISSION_GUIDE.md` for official rule links and the video checklist.

| Check | Result | Evidence |
| --- | --- | --- |
| Offline core suite | 36 passed, 0 failures | `swift test --package-path SayAgainChallenge.swiftpm` |
| iOS simulator build | Passed | `xcodebuild -project SayAgain.xcodeproj -scheme SayAgain -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet` |
| Full iPhone 17 Pro / iOS 26.5 simulator suite | 33 passed, 0 failures; reran with Xcode retry after one transient simulator SIGTERM | `Local Xcode DerivedData test-result path (not included)` |
| Focused updated paths | 4 passed, 0 failures: audio stall, route removal, detailed pain/emergency, large-text Home/Quick Needs | `/private/tmp/SayAgain-implementation-targeted-final.xcresult` |
| Full iPad Pro 13-inch M5 / iPadOS 26.5 simulator suite | 32 passed, 0 failures (prior run); new Challenge typed-message path then passed separately | `/private/tmp/SayAgain-implementation-ipad-final.xcresult`; `Local Xcode DerivedData test-result path (not included)` |
| Challenge typed-message flow | Passed on iPhone 17 Pro and iPad Pro 13-inch M5 simulators | Included in the full iPhone result and the focused iPad result above |
| Extracted submission package | Rebuilt and passed all 36 core tests from the extracted ZIP | `/private/tmp/SayAgainChallengeBundleCheck-20261011/SayAgainChallenge.swiftpm` |
| Submission ZIP | Refreshed; integrity passed; 52 KB, below the 25 MB limit; build/cache and Xcode user-data folders excluded | `Submission/SayAgainChallenge.zip` |

Earlier UI runs exposed incorrect automation assumptions about Home scroll position and switch hit targeting; the tests were corrected. One full iPhone run terminated the back-navigation UI test with SIGTERM, but that test passed immediately on its own and the retry-enabled complete suite then passed all 33 tests. Xcode emitted repeated nonfatal simulator debugger metadata warnings during UI tests. This update does **not** establish live microphone recognition, camera classification, or audible playback on physical hardware. The standalone `.swiftpm` iOS app product has not been opened/launched in Xcode’s app-playground UI; the command-line SwiftPM fallback and the shared demo inside the full iOS app are what were compiled and tested. The paired iPhone 14 Pro and connected iPad are not substitutes for a completed device test. VoiceOver, Switch Control, Apple Intelligence availability, and participant review also remain unverified in this update.

**Recorded:** 2026-10-04
**Environment:** Xcode 26.6, iOS/iPadOS SDK 26.5, Swift 6, strict concurrency

## Latest competition preparation update

Implemented one shared offline demo for the application and actual iOS app playground. It demonstrates ambiguity, an added example visual clue, explicit word/phrase confirmation, and system speech output; Back and Restart preserve/reset the correct state. Optional model updates remain pending until Update Suggestions. Learning/history commit after explicit Speak and successful playback setup, and Replay is deduplicated within a session. Withdrawn selections create no records. Added voice preview, system permission route, readable iPad widths, pinned speech/drawing actions, and single-column Quick Needs at accessibility text sizes.

### Final evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Final core suite | 32 passed, 0 failures | `/private/tmp/SayAgain-competition-core-final.log` |
| Final full iPad Air M4 / iPadOS 26.5 simulator suite | 28 passed, 0 failures: 13 app unit + 15 UI tests | `/private/tmp/SayAgain-competition-ipad.xcresult` |
| iPhone full suite before final switch-test targeting fix | 27 passed, 1 learning test failed because the preference was not enabled by the simulated tap | `/private/tmp/SayAgain-competition-iphone-final.xcresult` |
| iPhone learning and withdrawn-choice tests with switch-track targeting and verified enabled preferences | 2 passed, 0 failures | `/private/tmp/SayAgain-competition-learning-track.xcresult` |
| Final unsigned device Release build | Passed, no compiler warnings/errors; approximately 3.7 MB app | `/private/tmp/SayAgain-competition-release.log` |
| Release fixture/diagnostic string scan | No test capture/camera labels, launch arguments, or test storage identifier found | Release executable inspection |
| Independent app playground build | Passed using generated standalone Xcode workspace and SayAgainChallenge iOS scheme | `/private/tmp/SayAgain-submission-build-polished.log` |
| Independent app playground launch | Launched in iPhone 17 simulator; opening screen reviewed | `/private/tmp/SayAgain-submission-opening.png` |
| Submission ZIP | Approximately 44 KB; integrity checked; source bytes match working package; build caches/user data excluded | `Submission/SayAgainChallenge.zip` |

There are **60 distinct passing automated checks** in the final core and full iPad runs. The iPhone full run is not represented as a completely passing run; its affected learning tests passed separately after test automation was corrected. Initial iterations also exposed off-screen list/toggle selectors at large type sizes; those were corrected without padding candidates or fabricating model results.

Xcode emits a duplicate asset-catalog build-file warning for the standalone app playground; it skips the duplicate and builds the iOS app successfully. Xcode also prints nonfatal LLDB/tooling diagnostics during simulator tests. These are disclosed rather than described as warning-free package validation. The standalone package contains the focused offline demonstration, not the entire live application. Swift Playgrounds itself has not been tested.

The app playground declares an iOS application through the installed AppleProductTypes API and has no remote package dependencies. The demo explicitly identifies supplied speech/visual labels and performs no live recognition or learning. Shared UI automation exercises its selection, synthesis, Back, Restart, and largest-text controls in the app. This is not a fresh physical-device airplane-mode test of the ZIP.

### Outstanding submission checks

No new physical-device installation, live microphone/camera capture, audible hardware output, Apple Intelligence inference, manual VoiceOver/Switch Control review, or participant feedback was completed. A connected iPad was discovered, but live interaction requires an unlocked device and a participant. The entrant's motivation, competition year, required essays, individual contribution, eligibility, and final submission remain unverified. The repository includes public-facing build and implementation documentation. No competition outcome, clinical effectiveness, or bug-free operation is guaranteed.

## Earlier back navigation and clue retention update

- Added native back arrows: Suggestions → Review, phrase selection → Suggestions, and speech output → Phrases. Back does not start the microphone; editing returns to review before reuse. One Done action ends the communication flow; no additional Home button is introduced.
- Speech, photo, drawing, and typed clues are visible separately. Transient `VisualClues` ignores empty results and replaces only the same source after a useful new clue. Return to Suggestions no longer overwrites earlier photo labels.
- Camera capture commits a pending photo only after full-screen dismissal. Retake Cancel preserves the existing review. Permission progress does not insert a shifting footer row.
- Drawing renders padded stroke bounds onto a square white opaque 768-pixel image with black ink. Concrete plant, flower, and tree vocabulary was added. Edited drawings invalidate prior recognition; useful results require Use Drawing Clue. General Vision classification is not a validated arbitrary-sketch recognizer.
- Populated edit fields retain an explicit accessibility label and stable identifier; a native Clear Text action replaces a transcript without a selection gesture. Leaving speech output without having played an utterance avoids an unnecessary synchronous speech-framework query.

## Final validation for this update

| Check | Result | Evidence |
| --- | --- | --- |
| Offline core ranking, clue preservation, normalization, phrases, and constrained model output | 25 passed, 0 failures | `/private/tmp/SayAgain-back-core-final.log` |
| Final iPhone 17 Pro / iOS 26.5 simulator suite | 25 passed, 0 failures | `/private/tmp/SayAgain-back-iphone-complete.xcresult` |
| iPad Air M4 broad regression run | 24 passed; populated-edit test selector failed and was corrected | `/private/tmp/SayAgain-back-ipad-verified.xcresult` |
| iPad back-and-edit after stable input identifier | Passed separately | `/private/tmp/SayAgain-back-ipad-input.xcresult` |
| Final iPad back-and-edit with Clear Text | Passed separately, 0 failures | `/private/tmp/SayAgain-back-ipad-clear-complete.xcresult` |
| Final unsigned device Release build | Passed; no compiler warnings/errors | `/private/tmp/SayAgain-back-release-complete.log` |
| Release app size | Approximately 3.2 MB; not an archive/submission measurement | Device Release app |

There are 50 distinct passing automated checks in the final core and iPhone runs: 25 core tests, 13 app unit tests, and 12 app UI tests. Repeated destinations do not add distinct tests. New regressions cover back navigation, transcript replacement, drawing return without clue loss, canceled photo retake, cropped/opaque drawing rendering, empty recognition results preserving earlier photo/drawing labels, and concrete plant vocabulary retrieval.

Development iterations included a compiler type-check timeout in the new drawing test, populated SwiftUI input selector failures, and a replacement test that assumed the caret was at the end of the text on iPhone. These were resolved by simplifying the test expression, adding a stable input identifier, and providing a native Clear Text control. The final iPhone run passed the complete suite. Earlier failing runs are not described as passing validation.

Xcode printed nonfatal LLDB/tooling diagnostics and a speech-framework thread-priority warning during actual playback tests. The Release compiler produced no warnings/errors. Avoiding an unnecessary speech-state query when no utterance was played reduces one navigation path’s interaction with the speech framework; this is not a claim of measured real-device performance.

No new live microphone, physical camera, Apple Intelligence, arbitrary plant sketch recognition, VoiceOver, or Switch Control hardware validation was performed. Simulator camera/speech interaction tests use the explicitly labeled Debug fixtures described below. Drawing preprocessing and candidate retrieval tests do not prove that Vision will recognize every drawing.


## Previous visual clue and communication update

- Standalone actions use native bordered capsule buttons. Transcript review centers the recognized text above pinned Use This, Try Again, and Edit controls. Candidate rows retain native list selection and disclosure affordances.
- Visual clues have an explanation step, explicit Open Camera action, full-screen system camera, and a photo review step. Captured photos are retained in memory during review instead of disappearing immediately after classification.
- Photo review displays possible object labels or a clear no-object result. The person chooses Use Visual Clue, retake, a typed description, or Cancel. No photo is silently saved.
- Home omits idle microphone/camera text; feature screens still display capture state. Permission and active recording are different states. Existing permission preferences are retained.
- Listening distinguishes setup from actual audio arrival, offers a typed alternative during listening, and uses a decibel-scaled meter to show quieter sound. Digital silence remains flat.
- Added everyday object vocabulary, including keys, cups, chairs, phones, food, and household items. Existing deterministic Breakfast and confirmation tests remain valid.

## Earlier validation evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Core ranking, normalization, phrases, and model-output validation | 23 tests passed, 0 failures | `/private/tmp/SayAgain-clue-core-final.log` |
| iPhone 17 Pro / iOS 26.5 simulator | 20 app tests passed, 0 failures | `/private/tmp/SayAgain-clue-ui-final.xcresult` |
| Final iPad Air 11-inch M4 / iPadOS 26.5 simulator | 21 app tests passed, 0 failures | `/private/tmp/SayAgain-clue-ipad-final.xcresult` |
| Unsigned device Release build | Passed, no compiler warnings/errors | `/private/tmp/SayAgain-clue-device-final.log` |
| Release fixture exclusion | No camera/speech test fixture symbols, labels, or test-capture arguments found in executable strings | Release executable inspection |
| Release device app size | Approximately 3.1 MB | Not an archive or Challenge submission size |

There are 44 distinct passing tests: 23 core tests, 12 app unit tests, and 9 app UI tests. Repeated destination runs are not additional distinct tests.

The app suite covers recording permission denial, actual audio arrival, PCM ownership/conversion, Done/final/empty transcription, Cancel, startup cancellation, runtime failure, no-input fallback, permission decisions without a deadline, largest-text controls, typed retrieval, phrase selection, Speak/Replay/Stop, Quick Needs/pain, Personal Words and phrase Save/Cancel, onboarding, Settings, offline demo, full-screen visual clue transition, camera Cancel, retained photo review, and typed-photo-clue selection through to a phrase. The final iPad suite also includes a new quiet-sound/silence meter regression.

Screenshots of transcript review, photo review, full-screen presentation, and largest-text listening were exported to `/private/tmp/SayAgain-clue-ui-screens` and reviewed.

Camera UI tests use a clearly labeled Debug-only camera fixture and a blank test image. That image goes through the actual Vision processor; no labels are mocked. Speech UI tests use a clearly labeled Debug-only capture fixture with the microphone off. Normal launches and Release builds never select either fixture. Test storage is isolated from normal user data.

An initial new camera Cancel test failed because it selected among multiple Cancel controls; it was scoped to the intended controls and passed on rerun. An expanded-vocabulary test exposed a compound synonym promoting Bottle for “wa”; the synonym was corrected and all core tests passed. These failed iterations are not counted as passing validation.

Source review found no TODO/FIXME/fatalError/try!, remote-network client, API key, raw-media file write, or communication-content logging in application Swift sources. Xcode printed non-fatal LLDB/tooling and signed-test-framework stripping diagnostics; they are distinct from app compiler errors.

## Physical-device validation

Later device discovery reported a paired iPhone 14 Pro and iPad Air (5th generation) available. No physical-device installation or live microphone/camera capture was performed in this update. The target-device choice and a user-spoken test word are still needed to validate live recognition.

Remaining manual checks include live incomplete speech, real camera capture/use/retake, permission grants/denials, interruption/route changes, Apple Intelligence available/unavailable, VoiceOver/Switch Control, and fresh-install offline behavior. An unsigned device build verifies compilation, not hardware capture or audibility. No bug-free-program or clinical-effectiveness claim is made.
