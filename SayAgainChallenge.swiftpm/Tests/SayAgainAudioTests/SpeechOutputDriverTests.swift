import AVFoundation
import XCTest
@testable import SayAgainAudio

private actor ControlledAudioSession: PlaybackAudioSession {
    enum Mode: Sendable { case immediate, pending, failure }

    private let mode: Mode
    private var pending: CheckedContinuation<UUID, Error>?
    private var endedTokens: [UUID] = []

    init(mode: Mode = .immediate) { self.mode = mode }

    func beginPlayback() async throws -> UUID {
        switch mode {
        case .immediate: return UUID()
        case .failure: throw SessionFailure.unavailable
        case .pending:
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }

    func completePendingActivation() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: UUID())
    }

    func end(_ token: UUID?) async {
        if let token { endedTokens.append(token) }
    }

    func endedTokenCount() -> Int { endedTokens.count }
    func hasPendingActivation() -> Bool { pending != nil }

    enum SessionFailure: Error { case unavailable }
}

@MainActor private final class ControlledSynthesizer: SpeechSynthesizerBackend {
    var onStart: (@MainActor (ObjectIdentifier) -> Void)?
    var onFinish: (@MainActor (ObjectIdentifier) -> Void)?
    var onCancel: (@MainActor (ObjectIdentifier) -> Void)?
    private(set) var utterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0

    func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }
    func stopImmediately() { stopCount += 1 }
    func start(_ utterance: AVSpeechUtterance) { onStart?(ObjectIdentifier(utterance)) }
    func finish(_ utterance: AVSpeechUtterance) { onFinish?(ObjectIdentifier(utterance)) }
    func cancel(_ utterance: AVSpeechUtterance) { onCancel?(ObjectIdentifier(utterance)) }
}

@MainActor final class SpeechOutputDriverTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeDriver(audio: ControlledAudioSession = ControlledAudioSession(),
                            timeout: Duration = .seconds(5)) -> (SpeechOutputDriver, ControlledSynthesizer) {
        let synthesizer = ControlledSynthesizer()
        let driver = SpeechOutputDriver(audioSession: audio, startTimeout: timeout) { synthesizer }
        return (driver, synthesizer)
    }

    func testIdleStopDoesNotCreateSynthesizer() {
        var factoryCalls = 0
        let driver = SpeechOutputDriver(audioSession: ControlledAudioSession()) {
            factoryCalls += 1
            return ControlledSynthesizer()
        }

        driver.stop()

        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertEqual(factoryCalls, 0)
    }

    func testStopDuringPendingAudioActivationRejectsLateCompletion() async {
        let audio = ControlledAudioSession(mode: .pending)
        var factoryCalls = 0
        let driver = SpeechOutputDriver(audioSession: audio) {
            factoryCalls += 1
            return ControlledSynthesizer()
        }

        driver.speak("Hello")
        XCTAssertEqual(driver.playbackState, .preparing)
        for _ in 0..<100 {
            if await audio.hasPendingActivation() { break }
            await Task.yield()
        }
        let activationWasPending = await audio.hasPendingActivation()
        XCTAssertTrue(activationWasPending)
        driver.stop()
        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertEqual(factoryCalls, 0)

        await audio.completePendingActivation()
        for _ in 0..<100 {
            if await audio.endedTokenCount() == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(factoryCalls, 0)
        let endedCount = await audio.endedTokenCount()
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(driver.playbackState, .idle)
    }

    func testRapidReplayRejectsStaleCallbacksAndCountsEachStartOnce() async {
        let audio = ControlledAudioSession()
        let (driver, synthesizer) = makeDriver(audio: audio)

        driver.speak("First phrase")
        XCTAssertEqual(driver.playbackState, .preparing)
        await waitUntil { synthesizer.utterances.count == 1 }
        let first = synthesizer.utterances[0]
        synthesizer.start(first)
        XCTAssertEqual(driver.playbackState, .speaking)
        XCTAssertEqual(driver.playbackStartCount, 1)

        driver.speak("Replay phrase")
        XCTAssertEqual(driver.playbackState, .preparing)
        await waitUntil { synthesizer.utterances.count == 2 }
        let second = synthesizer.utterances[1]
        XCTAssertEqual(synthesizer.stopCount, 1)

        synthesizer.finish(first)
        XCTAssertEqual(driver.playbackState, .preparing)
        synthesizer.start(second)
        XCTAssertEqual(driver.playbackState, .speaking)
        XCTAssertEqual(driver.playbackStartCount, 2)
        driver.stop()
        synthesizer.finish(second)
        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertEqual(driver.playbackStartCount, 2)
    }

    func testFinishBeforeStartStillCountsOnlyOneSpokenChoice() async {
        let (driver, synthesizer) = makeDriver()
        driver.speak("A short word")
        await waitUntil { synthesizer.utterances.count == 1 }
        let utterance = synthesizer.utterances[0]

        synthesizer.finish(utterance)
        synthesizer.finish(utterance)

        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertEqual(driver.playbackStartCount, 1)
    }

    func testAudioSessionFailureReturnsToIdleWithoutCreatingSynthesizer() async {
        let audio = ControlledAudioSession(mode: .failure)
        var factoryCalls = 0
        let driver = SpeechOutputDriver(audioSession: audio) {
            factoryCalls += 1
            return ControlledSynthesizer()
        }
        driver.speak("Hello")

        await waitUntil { driver.playbackError != nil }

        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertNotNil(driver.playbackError)
        XCTAssertEqual(factoryCalls, 0)
    }

    func testMissingStartTimesOutAndStopsTheSynthesizer() async {
        let (driver, synthesizer) = makeDriver(timeout: .milliseconds(40))
        driver.speak("Hello")
        await waitUntil { synthesizer.utterances.count == 1 }
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(driver.playbackState, .idle)
        XCTAssertNotNil(driver.playbackError)
        XCTAssertEqual(synthesizer.stopCount, 1)
    }

    func testCancelCallbackEndsCurrentPlayback() async {
        let (driver, synthesizer) = makeDriver()
        driver.speak("Hello")
        await waitUntil { synthesizer.utterances.count == 1 }
        let utterance = synthesizer.utterances[0]
        synthesizer.start(utterance)
        XCTAssertEqual(driver.playbackState, .speaking)

        synthesizer.cancel(utterance)

        XCTAssertEqual(driver.playbackState, .idle)
    }
}
