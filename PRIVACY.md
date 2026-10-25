# Privacy

## Capture controls

- The microphone is off at launch. After the person taps **Help Me Say It**, SayAgain explains the short session and asks whether to turn the microphone on. The iOS permission prompt appears only after they choose to continue. It stops on Done, Cancel, leaving the listening screen, backgrounding, and capture failure/interruption cleanup.
- The camera is off at launch. After the person chooses **Add a Visual Clue**, SayAgain shows an explanation. **Open Camera** requests iOS permission if needed and opens a full-screen system camera. One still is processed after the person chooses **Use Photo**; the camera closes before local image classification. The photo remains visible in a memory-only review until the person uses its labels, types a clue, retakes, or cancels. No continuous camera stream is sent to the candidate engine.
- A successful in-app choice and the system permission are remembered across app launches and are cleared if SayAgain is deleted. This remembers permission to use the feature; it does not leave either device active. The microphone is active only in a listening session, and the camera only while the full-screen camera is open. Opening the explanation or photo review does not activate it. iOS permission can be changed in Settings. **Delete All SayAgain Data** does not revoke iOS permissions.
- Typed clues are entered only after an explicit action. Drawing clues are not included in this release.
- Onboarding does not request microphone or camera access.

## Stored locally

SwiftData stores user-created Personal Words, Personal Phrases, saved context names, and preferences. **Learn From My Choices** defaults off; when enabled it stores the normalized short speech fragment, confirmed term ID, optional context, confirmation count, and creation date after the person selects a term and phrase and AVSpeechSynthesizer confirms playback has started. It never learns from a displayed or model-ranked suggestion alone, and direct typed messages do not create learned mappings. **Save recent phrases** defaults off; when enabled it stores the exact phrase after playback begins, associated term/context IDs when available, and timestamp. Direct typed messages are saved without a term ID. Recent history can include medical or basic-needs communication as the Settings copy explains.

Raw audio, live transcript, typed clue, and camera image are not stored in SwiftData or written by SayAgain to a media file. They are transient flow data and are released when the flow ends. App container data may be included in the device's encrypted backup. The app does not configure its own sync service or analytics backend.

## Controls

- Reset Learned Patterns deletes mappings and learning counters without deleting Personal Words.
- Clear Recent Phrases deletes selected phrase history.
- Delete All SayAgain Data removes personal terms, phrases, custom contexts, mappings, recent phrases, and SayAgain preferences.
- Turning a storage preference off stops future saving; use the corresponding clear/reset action to remove existing saved records.

Home omits capture-state text so an idle device is not mistaken for denied permission. Feature screens show active capture state. Permission means the app may use a device after an intentional action; it does not mean that device is currently recording. Permission strings explain the capture purpose. The iOS privacy indicators remain active system indicators; in-app state labels are also shown while capture screens are open.

## Diagnostics

OSLog records only generic lifecycle and fallback categories, such as permission denied, speech asset unavailable, or visual classification completed. Content-free signposts measure store initialization, voice-catalog refresh, vocabulary preparation, ranking, audio activation, synthesis startup, and photo classification. Diagnostics do not record transcript text, personal names, selected phrases, image labels, audio, image bytes, or model output.

## Corrections and replay

Going back, changing a choice, or ending a session before playback starts creates no mapping or history entry. One session records the same fragment/term/context only once; Replay does not increase that learning count. Different selected phrases can create distinct history entries. Quick Needs and direct typed messages can save explicitly spoken phrases when history is enabled, but create no speech-fragment mappings. If the person speaks a corrected choice later in the same flow, SayAgain removes the learning/history writes made for the prior choice in that flow and saves the replacement. Earlier confirmations from other flows remain unchanged. This correction behavior applies only to receipts held in memory for the active flow. Recording a playback-start event does not establish that another person heard or understood it.

## Reliability implementation update — 2026-10-13

The microphone and camera still require a fresh, explicit action for each capture session; remembered permission does not mean a sensor remains active. Shared audio-session ownership is token-based, so stopping an older task cannot end a newer capture or playback session. Captured images and audio buffers remain transient. The built-in vocabulary usage record stores only a built-in term ID, count, and last-used time, and **Reset Learned Patterns** clears it with the learned mappings.
