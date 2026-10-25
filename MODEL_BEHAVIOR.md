# Model behavior

## Deterministic path first

Every live candidate list starts with `DeterministicCandidateEngine` using local vocabulary, personal words, the current clue(s), selected context, and enabled confirmed mappings. It does not need Foundation Models, a network, or a remote model. It returns a bounded list; the UI presents at most four plus **Something Else…**.

## Optional Foundation Models reranking

When `SystemLanguageModel.default.availability` is `.available`, the app may send a text prompt to the on-device Foundation Models framework containing the short transcript/typed fragment, selected context, local visual labels, and ID/label pairs from the bounded deterministic shortlist. It does not include audio, images, personal phrase history, relationships, or unrestricted vocabulary. The instruction prohibits adding candidates or deciding meaning. A constrained schema restricts output to IDs. SayAgain independently rejects unknown IDs, duplicates, empty lists, and lists longer than four. A valid revised order is held separately. Visible rows remain stationary until the person taps Update Suggestions. Results from an older clue request are ignored. Deterministic suggestions remain available.

Unavailable model, Apple Intelligence disabled, model-not-ready, generation failure, cancellation, or invalid output falls back to the deterministic order. The interface does not show model confidence or an inferred intent. In the fallback case, it may show **Using standard suggestions**.

## Vision and speech

SpeechAnalyzer and SpeechTranscriber return recognition text, not intent. Vision classification returns possible visible labels; labels are not converted into human needs, feelings, or diagnoses. The bundled Challenge fixture is explicitly labeled example data and does not pretend to be microphone or Vision output.

Foundation Models phrase generation and image-capable Foundation Models are not implemented in this MVP. Phrase choices use local deterministic templates, including the literal-word option.

## Visual clue scope

This release supports one intentional photo clue at a time. Vision may return concrete visible-object labels; it does not infer a person’s need, intention, or diagnosis. If no useful label is returned, existing suggestions remain available and the person can type a clue. Drawing clues are not included because the current local classifier is not a validated recognizer for arbitrary sketches.

## Correction and playback behavior

Speech playback uses the same local `AVSpeechSynthesizer` driver in the full app and the offline demo. A chosen phrase is not spoken automatically: the person must tap Speak. Playback setup has a bounded start wait; if the synthesizer does not begin, SayAgain stops that request and offers a retry message instead of leaving the interface in a permanent preparing state.

When **Learn From My Choices** is enabled, a word/fragment mapping is recorded only after playback begins. A memory-only receipt tracks the writes made by the current communication flow. If the person goes back, chooses a correction, and speaks it, the current flow’s earlier learning and recent-phrase writes are replaced; older records from other flows remain. Replaying the same selected phrase does not add another confirmation. This is correction-aware bookkeeping, not evidence that the original phrase was understood or heard by someone else.

Built-in term usage counts and timestamps are stored in the separate `TermUsage` SwiftData model only when learning is enabled. The migration from schema v1 adds this model without removing the existing Personal Words or phrase data. Reset Learned Patterns clears these counts together with learned mappings.
