# Accessibility

SayAgain uses standard SwiftUI navigation, lists, forms, sheets, menus, and buttons. Candidate and phrase choices are rows with text labels; Quick Needs has six large labeled targets. Critical actions do not require a swipe or color recognition. Speech output is optional; text remains visible and editable.

The app uses system text styles and semantic colors. It does not impose fixed text sizes on primary text. Listening bars reflect measured microphone amplitude and have no decorative animation. Camera and typed clues are available as separate routes.

## Automated checks and UI refinements

The iPhone and iPad simulator UI suites exercised listening Done/Cancel, typed clues, phrase selection, Quick Needs, Personal Words, onboarding, Settings, and the demo. Listening Done and Cancel remain tappable at the largest accessibility Dynamic Type size. This verifies those interactions; it does not establish VoiceOver or Switch Control conformance.

Listening controls are pinned outside a scrollable transcript. Its privacy status wraps in the content instead of truncating in the navigation bar. Onboarding and transcript review scroll at large sizes. Personal word deletion is available through a context menu and a named accessibility action; personal phrases have labeled fields and visible Delete controls.

## Manual validation still required

The current simulator build and package tests do not establish accessibility conformance. Before release, verify on real iPhone and iPad hardware:

- VoiceOver focus order, accessible labels and hints, state announcements, and candidate row selection.
- Switch Control, Voice Control, hardware keyboard navigation, and touch target size.
- Largest Dynamic Type sizes, Bold Text, Increase Contrast, Differentiate Without Color, and Reduce Motion.
- Portrait, landscape, iPad split layouts, light mode, and dark mode.
- Camera-denied and speech-denied flows retain usable typed and Quick Needs alternatives.

Do not claim these checks passed until they are performed and recorded in `BUILD_STATUS.md`.

## Visual clue and action clarity update

Standalone communication actions now use bordered system buttons with a capsule shape and an emphasized primary action. Selection lists retain native rows and disclosure affordances. The transcript is centered above pinned review actions. Visual clues open with an explanation, then a full-screen camera, then a visible photo review with explicit recognition results and a typed alternative. The input meter uses a decibel scale to make quieter sound visible while digital silence remains flat.

Design references: Apple’s [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), and [Camera Control](https://developer.apple.com/design/human-interface-guidelines/camera-control) guidance.

## Navigation and clue review update

- Review, Suggestions, and Phrases back controls have visible text with a native chevron. Back navigation does not require a gesture and does not restart recording.
- The populated clue edit field keeps an explicit spoken label and a stable accessibility identifier; its prompt is not the only way to identify it. Clear Text offers an alternative to selecting and deleting an entire transcript.
- Speech, photo, and typed clues appear in separate native list sections. An empty photo classification leaves earlier clues intact.
- The camera permission state updates one fixed-size button rather than inserting another row during presentation. Canceling a retake retains photo review.

Automated tests cover back navigation and editing, photo retake cancellation, photo clue retention, and largest-text listening controls. These do not replace manual VoiceOver and Switch Control validation.

## Competition refinements

Quick Needs becomes a single column at accessibility text sizes. Speech output actions are pinned outside scrollable content. Communication content has a readable maximum width on iPad. Candidate rows do not move when optional reranking finishes; Update Suggestions is explicit. Settings includes a named history toggle, voice preview, and a route to the app’s system permissions. Native list selection remains unchanged.

The Speak/Stop/Replay control keeps one accessibility identity and minimum target size while its title changes. Preparation and playback errors are announced in the scrollable phrase content, so neither inserts a row into the pinned action area.

Automated largest-text tests check demo speech controls and Quick Needs in addition to listening. They do not prove that every screen or hardware accessibility service has passed manual review.
