# Architecture

## Runtime flow

```text
SwiftUI Home
  ├─ Quick Needs ── deterministic phrase ── explicit Speak
  ├─ Say Typed Message ── exact text review ── explicit Speak
  ├─ Help Me Say It
  │    └─ SpeechCaptureService ── transcript review/edit
  │         └─ DeterministicCandidateEngine ── optional Foundation Models rerank
  │              └─ person confirms term ── PhraseLibrary ── person selects phrase
  │                   └─ AVSpeechSynthesizer after Speak tap
  ├─ Personal Words / Settings ── SwiftData
  └─ Offline demo ── same core candidate engine and phrase library
```

## Code ownership

- `SayAgainChallenge.swiftpm/Sources/SayAgainCore/CommunicationModels.swift`: shared SwiftData models and Sendable domain values.
- `CandidateEngine.swift`: pure deterministic text normalization, retrieval, scoring, stable ordering, and English seed vocabulary.
- `PhraseLibrary.swift`: deterministic phrase and pain templates.
- `SayAgainApp/AppRootView.swift`: app navigation and communication flow; makes the explicit confirmation transition and records only enabled preferences.
- `SpeechCaptureService.swift`: audio-session lifecycle, AVAudioEngine input, SDK-selected SpeechAnalyzer audio format, AVAudioConverter processing, SpeechTranscriber results, and cleanup.
- `SayAgainAudio/SpeechOutputDriver.swift`: lazy AVSpeechSynthesizer ownership, tokenized audio-session activation, one playback state, and the shared stable Speak/Stop/Replay control.
- `CommunicationViews.swift`: listening UI and optional Foundation Models bounded reranker. `AppRootView.swift` contains transcript review, phrase/speech presentation, and the shared demo wrapper.
- `VisualClueViews.swift`: user-triggered still camera UI, local Vision classification, and typed fallback.
- `PersonalWordsView.swift`, `SettingsView.swift`: local editing and privacy controls.
- `SayAgainChallenge.swiftpm/Sources/SayAgainChallenge/ChallengeApp.swift`: standalone local demo target.

The flow state currently lives in the SwiftUI `CommunicationFlowView`; services are kept small and stateful only when they own a system API. Do not move transient audio, image, or transcript data into SwiftData.

## Candidate policy

Normalize case and safe punctuation while retaining incomplete fragments. `PreparedVocabulary` holds normalized aliases and display sort keys so repeated clue edits do not repeat that work. Compare speech and typed clues to canonical text and synonyms using exact, prefix, substring, and normalized edit-distance similarity. Normalize and group confirmed mappings once per request. Combine active evidence with centrally defined weights: speech 0.45, visual label match 0.20, context 0.15, confirmed mapping 0.10, and recency/use 0.10. Missing evidence is removed and active weights are renormalized. Personal terms receive the agreed +0.05 tie-break boost. Context adds evidence but never excludes a term. Stable source order resolves ties.

The engine returns up to 12 candidates; the screen shows at most four and always offers **Something Else…**. The Foundation Models path sees only that deterministic shortlist and may return up to four IDs. IDs are validated; valid results are held until explicit Update Suggestions. The deterministic order remains the fallback.

## Concurrency

Swift 6 and complete strict concurrency diagnostics are enabled. SwiftUI state is on MainActor; `OnDeviceSpeechCapture` is an actor that owns AVAudioEngine and SpeechAnalyzer. The audio tap explicitly has a Sendable callback. It copies PCM into an independently owned buffer; conversion, metering, analyzer input, and transcription consumption run in detached tasks. Mutable SDK objects cross isolation only through narrowly scoped owners with documented synchronization.

Raw and converted input streams each retain at most 128 buffers. Overflow fails calmly rather than silently dropping syllables or allowing memory to grow indefinitely. Engine startup alone does not establish Listening: an actual audio-buffer event does. Startup after permission has a 15-second technical deadline; an engine delivering no initial buffers has a 3-second watchdog. Permission decisions and communication choices have no deadline.

Done stops hardware and deactivates capture before draining queued input and collecting final transcription, with a 1.5-second finalization deadline whose timer is canceled on success. Cancel returns to navigation immediately and schedules hardware shutdown independently of the UI actor. A second watchdog handles an input route that stops delivering buffers after capture begins. Session generations reject obsolete results. The shared audio-session owner uses tokens so delayed capture cleanup cannot deactivate new speech playback. Backgrounding and interruption-began stop capture; a temporary inactive state during a permission prompt does not cancel it.

Speech output uses one `idle`/`preparing`/`speaking` state until AVSpeechSynthesizer confirms that the utterance started or finishes a very short utterance. The synthesizer itself is created only when the first explicit speech request reaches enqueue and is retained for reuse. The shared playback button stays in the same footer with a stable frame while its label changes between Speak, Stop, and Replay; progress and error messages are in scrollable content. A five-second start watchdog offers a retry message if playback does not begin. Learning and history callbacks happen on the confirmed start event, with a finish callback as a fallback for very short utterances.

Vision runs in a detached task with cancellation forwarded from its sheet. Foundation Models runs asynchronously after deterministic suggestions are already visible. Its result is constrained and independently validated. Leaving the candidate screen or choosing a word cancels pending reranking.

## Persistence

SwiftData stores user-created words, phrases, contexts, opt-in confirmed mappings, and opt-in recent explicitly spoken phrase text. `CommunicationSession` is a transient value. Stored recent phrases intentionally contain no transcript or raw media. Delete/reset operations remove dependent records. See `PRIVACY.md` for retention and backups.

OSLog entries use fixed, generic event strings for capture, capability, and fallback lifecycle. Content-free signposts measure store initialization, vocabulary preparation, deterministic ranking, audio activation, synthesis startup, voice-catalog refresh, and photo classification. They exclude communication content.

## API references

Capture follows the installed SDK interfaces and Apple’s [SpeechAnalyzer documentation](https://developer.apple.com/documentation/Speech/SpeechAnalyzer): select a supported PCM format, feed the asynchronous input sequence, terminate input, and finalize pending results. The tap uses the native [AVAudioNode audio callback API](https://developer.apple.com/documentation/AVFAudio/AVAudioNode). Compilation and tests verify this implementation against SDK 26.5; hardware capability is checked at runtime.

## Returning to earlier steps and clue ownership

Suggestions has a native Review back arrow; phrase selection returns to Suggestions; speech output returns to Phrases and stops any active playback. Back navigation does not start the microphone. Editing a transcript returns to review before it is used again. Done on speech output deliberately ends the communication flow; there is no extra Home action.

`VisualClues` stores only locally derived photo labels in transient state. Applying an empty recognition result does nothing; the person can explicitly remove the photo, typed, or speech clue, and each removal recomputes suggestions. Previously accepted clues remain available until the person removes them or the session ends. A successful new photo replaces the previous photo labels.

Camera capture writes a pending in-memory still. The review commits it only after the full-screen camera has dismissed. Opening or canceling a retake does not clear the existing photo or change the underlying review layout. The permission state changes the fixed-size camera button label rather than inserting an extra footer row.

Drawing clues are not part of this release because general image classification is not a validated recognizer for arbitrary sketches. Vision photo labels remain clues about visible objects only; they do not assert a person’s need or intended meaning. Plant, flower, and tree labels remain useful vocabulary for photo and typed clues.

## Competition refinement

`SayAgainDemo` supplies one shared native SwiftUI demonstration to the app and the standalone app playground. `CommunicationDemo` implements the fixture state machine and calls the production deterministic engine and phrase library. Bundled visual labels are declared example data, not simulated live inference. The app injects its existing speech output service so capture/playback ownership remains coordinated.

`SuggestionOrder` holds optional model results until explicit Update Suggestions. Session request IDs reject late results. `ConfirmedChoiceRecorder` writes only after a playback-start callback. Direct typed messages use a history-only recorder path with a nil term ID and never create learned mappings. It deduplicates learning and history within the session; SwiftData save failures roll back and permit retry. Choosing a term or navigating back alone performs no persistence mutation. Debug-only UI diagnostics read the isolated test store; Release omits them.

## Reliability update — 2026-10-13

The live app and demo now share `SayAgainAudio.SpeechOutputDriver` and its token-based `AudioSessionController`. Capture/playback activation and cleanup are serialized by one actor. An older operation can end only its own token, so delayed stop cleanup cannot deactivate newer speech playback. Playback exposes preparing/speaking/error states, stops after a five-second start timeout, and ignores callbacks for an obsolete utterance.

Speech capture start/stop is scoped by a session UUID. A delayed stop from a previous listening attempt is ignored after a newer attempt starts. Startup and teardown cleanup also run after partial failure. `SpeechCaptureService` observes an ended results stream as a failure instead of leaving Listening displayed indefinitely. The input meter accounts for interleaved and planar channel data; the converter drains its end-of-stream tail before final results are collected.

Candidate computation runs off the UI actor with cancellation and request IDs. Deterministic suggestions are produced first; optional reranking cannot block that list. Returning from a later step keeps the current candidate set and clue state. Personal display labels include the saved relationship, while phrase output uses the term’s canonical display text.

`ConfirmedChoiceRecorder` returns a receipt describing the exact database writes made by the current flow. If the person speaks a corrected choice in that same flow, the recorder reverses only those writes and records the replacement in one save. It leaves older sessions’ confirmation counts intact. Replay of the same phrase in the same flow is deduplicated. Stored session receipts are memory-only.

SwiftData schema v2 adds `TermUsage` for built-in vocabulary recency. `SayAgainSchemaV1` preserves the prior five-model schema and the migration plan adds the new model with a lightweight migration. A simulator unit test creates a v1 store, inserts a Personal Word, migrates it, then verifies the word remains and the new usage table is empty.
