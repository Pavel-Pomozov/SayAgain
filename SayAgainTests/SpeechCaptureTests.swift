import XCTest
import AVFoundation
import UIKit
import SwiftData
@testable import SayAgain
import SayAgainCore

private actor TestCaptureBackend: SpeechCaptureBackend {
    var continuation: AsyncStream<SpeechCaptureEvent>.Continuation?
    var starts = 0
    var stops = 0
    var startDelay: Duration = .zero
    var stopDelay: Duration = .zero
    var finalText: String?
    var activeSessionID: UUID?
    func configure(startDelay: Duration = .zero, stopDelay: Duration = .zero, finalText: String? = nil) {
        self.startDelay = startDelay; self.stopDelay = stopDelay; self.finalText = finalText
    }
    func start(sessionID: UUID) async throws -> AsyncStream<SpeechCaptureEvent> {
        starts += 1
        if startDelay > .zero { try await Task.sleep(for: startDelay) }
        let (stream, continuation) = AsyncStream<SpeechCaptureEvent>.makeStream()
        self.continuation = continuation
        activeSessionID = sessionID
        continuation.yield(.started)
        return stream
    }
    func emit(_ event: SpeechCaptureEvent) { continuation?.yield(event) }
    func isActive(_ sessionID: UUID) -> Bool { activeSessionID == sessionID }
    func currentSessionID() -> UUID? { activeSessionID }
    func stop(sessionID: UUID, discardResults: Bool) async {
        guard activeSessionID == sessionID else { return }
        stops += 1
        activeSessionID = nil
        let old = continuation
        continuation = nil
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
        if !discardResults, let finalText { old?.yield(.transcript(finalText, start: 0, isFinal: true)) }
        old?.yield(.stopped)
        old?.finish()
    }
    func installSupport() async throws {}
}

final class SpeechCaptureTests: XCTestCase {
    func testMeterThrottleLimitsPublishedAmplitudeToThirtyHertz() {
        var throttle = SpeechMeterThrottle(maximumFrequency: 30)
        XCTAssertTrue(throttle.shouldPublish(at: 10.000))
        XCTAssertFalse(throttle.shouldPublish(at: 10.010))
        XCTAssertFalse(throttle.shouldPublish(at: 10.030))
        XCTAssertTrue(throttle.shouldPublish(at: 10.034))
        XCTAssertFalse(throttle.shouldPublish(at: 10.040))
    }

    @MainActor private func settle() async { for _ in 0..<10 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }

    @MainActor func testPermissionDenialNeverStartsHardware() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { false })
        await service.start()
        XCTAssertTrue(service.microphonePermissionDenied)
        XCTAssertFalse(service.microphoneActive)
        let starts = await backend.starts
        XCTAssertEqual(starts, 0)
        guard case .unavailable = service.state else { return XCTFail("Expected denied permission fallback") }
    }

    @MainActor func testEngineStartedIsNotEnoughToClaimAudioArrived() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start(); await settle()
        XCTAssertTrue(service.microphoneActive)
        XCTAssertFalse(service.hasReceivedAudio)
        XCTAssertEqual(service.state, .starting)
        await backend.emit(.audio(0.4)); await settle()
        XCTAssertTrue(service.hasReceivedAudio)
        XCTAssertEqual(service.state, .listening)
        XCTAssertEqual(service.signalLevel, 0.4)
        service.stopImmediately(); await settle()
        XCTAssertFalse(service.microphoneActive)
    }

    @MainActor func testDoneIncludesFinalResultDeliveredDuringStop() async {
        let backend = TestCaptureBackend()
        await backend.configure(finalText: "water")
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start()
        await backend.emit(.audio(0.5))
        await backend.emit(.transcript("wa", start: 0, isFinal: false))
        await settle()
        XCTAssertEqual(service.transcript, "wa")
        let result = await service.stop()
        XCTAssertEqual(result, "water")
        XCTAssertFalse(service.microphoneActive)
        XCTAssertEqual(service.state, .idle)
    }

    @MainActor func testCancelReturnsImmediatelyDespiteSlowHardwareShutdown() async {
        let backend = TestCaptureBackend()
        await backend.configure(stopDelay: .milliseconds(200))
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start(); await settle()
        let clock = ContinuousClock()
        let start = clock.now
        service.stopImmediately()
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(50))
        XCTAssertEqual(service.state, .idle)
        await backend.emit(.transcript("stale", start: 0, isFinal: true))
        await settle()
        XCTAssertEqual(service.transcript, "")
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(service.microphoneActive)
    }

    @MainActor func testCancelWhileStartingDoesNotReviveCapture() async {
        let backend = TestCaptureBackend()
        await backend.configure(startDelay: .milliseconds(100))
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        let start = Task { await service.start() }
        await settle()
        service.stopImmediately()
        await start.value; await settle()
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.microphoneActive)
        XCTAssertFalse(service.hasReceivedAudio)
    }

    @MainActor func testLateStopFromPreviousSessionCannotStopNewListeningSession() async {
        let backend = TestCaptureBackend()
        await backend.configure(stopDelay: .milliseconds(120))
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })

        await service.start()
        await settle()
        service.stopImmediately()
        await service.start()
        await backend.emit(.audio(0.25))
        await settle()

        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(service.microphoneActive)
        XCTAssertEqual(service.state, .listening)
        let currentSession = await backend.currentSessionID()
        XCTAssertNotNil(currentSession)
        if let currentSession {
            let stillActive = await backend.isActive(currentSession)
            XCTAssertTrue(stillActive)
        }
        service.stopImmediately()
        await settle()
    }

    @MainActor func testNoAudioWatchdogProvidesWorkingFallback() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true }, noAudioTimeout: .milliseconds(40))
        await service.start()
        try? await Task.sleep(for: .milliseconds(100))
        guard case .failed = service.state else { return XCTFail("No input must not remain in Listening forever") }
        XCTAssertFalse(service.microphoneActive)
        let stops = await backend.stops
        XCTAssertGreaterThan(stops, 0)
    }

    @MainActor func testAudioStallAfterCaptureStartsProvidesFallback() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true },
            noAudioTimeout: .seconds(1), audioStallTimeout: .milliseconds(40))
        await service.start()
        await backend.emit(.audio(0.2))
        await settle()
        XCTAssertEqual(service.state, .listening)
        try? await Task.sleep(for: .milliseconds(100))
        guard case .failed = service.state else { return XCTFail("An audio stream that stops must leave Listening") }
        XCTAssertFalse(service.microphoneActive)
    }

    @MainActor func testRemovedAudioInputRouteStopsCaptureWithRetryPath() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start()
        await backend.emit(.audio(0.2))
        await settle()
        service.audioInputRouteWasRemoved()
        await settle()
        guard case .failed(let message) = service.state else { return XCTFail("A removed input route must leave Listening") }
        XCTAssertTrue(message.contains("Try listening again"))
        XCTAssertFalse(service.microphoneActive)
    }

    @MainActor func testDoneWithNoRecognizedWordsStopsCleanly() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start()
        await backend.emit(.audio(0))
        await settle()
        let text = await service.stop()
        XCTAssertEqual(text, "")
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.microphoneActive)
    }

    @MainActor func testRecognitionFailureStopsCaptureAndRejectsLaterText() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: { true })
        await service.start()
        await backend.emit(.audio(0.4))
        await backend.emit(.failed("Speech couldn’t be processed. Try again or type a clue."))
        await settle()
        guard case .failed = service.state else { return XCTFail("Expected usable failure state") }
        XCTAssertFalse(service.microphoneActive)
        await backend.emit(.transcript("obsolete", start: 0, isFinal: true))
        await settle()
        XCTAssertEqual(service.transcript, "")
    }

    @MainActor func testPermissionDecisionHasNoStartupDeadline() async {
        let backend = TestCaptureBackend()
        let service = SpeechCaptureService(backend: backend, requestPermission: {
            try? await Task.sleep(for: .milliseconds(100))
            return true
        }, startupTimeout: .milliseconds(40))
        await service.start()
        await backend.emit(.audio(0.2))
        await settle()
        XCTAssertEqual(service.state, .listening)
        service.stopImmediately()
        await settle()
    }

    func testTapBufferCopyRemainsValidAfterOriginalIsReused() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        source.frameLength = 1024
        let samples = try XCTUnwrap(source.floatChannelData?.pointee)
        for i in 0..<1024 { samples[i] = 0.04 }
        let frame = try CapturedAudioFrame.copy(source)
        for i in 0..<1024 { samples[i] = 0 }
        XCTAssertEqual(frame.buffer.floatChannelData?.pointee[0], 0.04)
        XCTAssertGreaterThan(StreamingAudioConverter.meterLevel(frame.buffer), 0.5)
        XCTAssertEqual(StreamingAudioConverter.meterLevel(source), 0)
    }

    func testQuietSoundIsVisibleAndDigitalSilenceRemainsFlat() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<1024 { samples[index] = 0.003 }
        XCTAssertGreaterThan(StreamingAudioConverter.meterLevel(buffer), 0.2)
        for index in 0..<1024 { samples[index] = 0 }
        XCTAssertEqual(StreamingAudioConverter.meterLevel(buffer), 0)
    }

    func testLiveConversionDeliversNonzeroAudioAcrossSampleRates() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let targetFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try StreamingAudioConverter(source: sourceFormat, destination: targetFormat)
        var totalFrames = 0
        for _ in 0..<8 {
            let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1024))
            source.frameLength = 1024
            let samples = try XCTUnwrap(source.floatChannelData?.pointee)
            for i in 0..<1024 { samples[i] = 0.05 * sin(Float(i) * 0.1) }
            if let output = try converter.convert(CapturedAudioFrame.copy(source)) {
                XCTAssertEqual(output.format.sampleRate, 16_000)
                totalFrames += Int(output.frameLength)
                XCTAssertGreaterThan(StreamingAudioConverter.meterLevel(output), 0)
            }
        }
        XCTAssertGreaterThan(totalFrames, 2000)
    }

    @MainActor func testVersionOneStoreMigratesToTermUsageAndKeepsPersonalWords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("SayAgain.store")

        do {
            let oldSchema = Schema(versionedSchema: SayAgainSchemaV1.self)
            let oldConfiguration = ModelConfiguration("SayAgainMigrationTest", schema: oldSchema, url: storeURL)
            let oldContainer = try ModelContainer(for: oldSchema, configurations: [oldConfiguration])
            oldContainer.mainContext.insert(PersonalTerm(canonicalText: "Sarah", category: .people))
            try oldContainer.mainContext.save()
        }

        let currentSchema = Schema(versionedSchema: SayAgainSchemaV2.self)
        let currentConfiguration = ModelConfiguration("SayAgainMigrationTest", schema: currentSchema, url: storeURL)
        let migrated = try ModelContainer(for: currentSchema, migrationPlan: SayAgainMigrationPlan.self,
            configurations: [currentConfiguration])
        XCTAssertEqual(try migrated.mainContext.fetch(FetchDescriptor<PersonalTerm>()).map(\.canonicalText), ["Sarah"])
        XCTAssertTrue(try migrated.mainContext.fetch(FetchDescriptor<TermUsage>()).isEmpty)
    }
}
