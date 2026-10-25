import Foundation
import Observation
import OSLog
import SayAgainCore
import SayAgainAudio
@preconcurrency import AVFoundation
@preconcurrency import Speech

private let speechLogger = Logger(subsystem: "org.sayagain.communication", category: "Speech")

/// A delayed cleanup may only release the audio session it acquired. Capture
/// and playback share the system session, so an older operation must not turn
/// off a newer one.
enum SpeechCaptureEvent: Sendable {
    case started
    case audio(Float)
    case transcript(String, start: Double, isFinal: Bool)
    case resultsEnded
    case stopped
    case failed(String)
}

protocol SpeechCaptureBackend: Sendable {
    func start(sessionID: UUID) async throws -> AsyncStream<SpeechCaptureEvent>
    func stop(sessionID: UUID, discardResults: Bool) async
    func installSupport() async throws
}

enum CaptureError: Error {
    case unavailable(String)
    case noInput
    case conversion
    case overloaded
}

struct SpeechMeterThrottle: Sendable {
    private let minimumInterval: TimeInterval
    private var lastPublishedAt: TimeInterval?

    init(maximumFrequency: Double = 30) {
        minimumInterval = 1 / max(maximumFrequency, 1)
    }

    mutating func shouldPublish(at uptime: TimeInterval) -> Bool {
        guard let lastPublishedAt else {
            self.lastPublishedAt = uptime
            return true
        }
        guard uptime - lastPublishedAt >= minimumInterval else { return false }
        self.lastPublishedAt = uptime
        return true
    }
}

/// An independent copy of a tap buffer. The tap's original memory is reused by
/// Core Audio after its callback returns. This copy has one processing owner.
struct CapturedAudioFrame: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    static func copy(_ source: AVAudioPCMBuffer) throws -> CapturedAudioFrame {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            throw CaptureError.noInput
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { throw CaptureError.conversion }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffers[index].mData else {
                throw CaptureError.conversion
            }
            let byteCount = Int(sourceBuffer.mDataByteSize)
            guard byteCount <= Int(destinationBuffers[index].mDataByteSize) else { throw CaptureError.conversion }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return CapturedAudioFrame(buffer: copy)
    }
}

private final class ConverterInputSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false
    func next(_ buffer: AVAudioPCMBuffer, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

/// Used by one detached processing task, never by the audio render callback.
final class StreamingAudioConverter: @unchecked Sendable {
    private let destination: AVAudioFormat
    private let converter: AVAudioConverter?

    init(source: AVAudioFormat, destination: AVAudioFormat) throws {
        self.destination = destination
        if source == destination {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: destination) else { throw CaptureError.conversion }
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func convert(_ frame: CapturedAudioFrame) throws -> AVAudioPCMBuffer? {
        guard let converter else { return frame.buffer }
        let capacity = AVAudioFrameCount(ceil(Double(frame.buffer.frameLength) * destination.sampleRate / frame.buffer.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { throw CaptureError.conversion }
        let supply = ConverterInputSupply()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            supply.next(frame.buffer, status: inputStatus)
        }
        guard status != .error, error == nil else { throw CaptureError.conversion }
        return output.frameLength > 0 ? output : nil
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var tail: [AVAudioPCMBuffer] = []
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 4096) else {
                throw CaptureError.conversion
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { throw CaptureError.conversion }
            if output.frameLength > 0 { tail.append(output) }
            if status == .endOfStream { break }
        }
        return tail
    }

    static func meterLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var sum = 0.0
        var sampleCount = 0
        if let samples = buffer.floatChannelData {
            for index in 0..<count {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let value = buffer.format.isInterleaved ? samples.pointee[index * stride + channel] : samples[channel][index]
                    let sample = Double(value); sum += sample * sample; sampleCount += 1
                }
            }
        } else if let samples = buffer.int16ChannelData {
            for index in 0..<count {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let value = buffer.format.isInterleaved ? samples.pointee[index * stride + channel] : samples[channel][index]
                    let sample = Double(value) / Double(Int16.max); sum += sample * sample; sampleCount += 1
                }
            }
        } else if let samples = buffer.int32ChannelData {
            for index in 0..<count {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let value = buffer.format.isInterleaved ? samples.pointee[index * stride + channel] : samples[channel][index]
                    let sample = Double(value) / Double(Int32.max); sum += sample * sample; sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sum / Double(sampleCount))
        guard rms.isFinite else { return 0 }
        // A decibel scale makes quiet speech visible without inventing activity
        // for digital silence. The display is sound level, not intent/confidence.
        let decibels = 20 * log10(max(rms, 0.00000001))
        return Float(min(max((decibels + 60) / 35, 0), 1))
    }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func installTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        let cancelImmediately = finished
        if !finished { timeoutTask = task }
        lock.unlock()
        if cancelImmediately { task.cancel() }
    }

    @discardableResult func finish() -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let pending = continuation
        continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        pending?.resume()
        return true
    }
}

/// One actor owns engine configuration, tap installation, and hardware stop.
/// No AVAudioEngine operation or sample conversion runs on the UI actor.
actor OnDeviceSpeechCapture: SpeechCaptureBackend {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var rawInput: AsyncStream<CapturedAudioFrame>.Continuation?
    private var events: AsyncStream<SpeechCaptureEvent>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var generation = 0
    private var activeSessionID: UUID?
    private var tapInstalled = false
    private var audioSessionToken: UUID?

    func start(sessionID: UUID) async throws -> AsyncStream<SpeechCaptureEvent> {
        if let activeSessionID { await stop(sessionID: activeSessionID, discardResults: true) }
        generation += 1
        let request = generation
        activeSessionID = sessionID
        do {
            return try await startCapture(request: request)
        } catch {
            if activeSessionID == sessionID { await stop(sessionID: sessionID, discardResults: true) }
            throw error
        }
    }

    private func startCapture(request: Int) async throws -> AsyncStream<SpeechCaptureEvent> {
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError.unavailable("Speech recognition isn’t available on this device. You can type a clue or use Quick Needs.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw CaptureError.unavailable("English speech recognition isn’t supported here. You can type a clue or use Quick Needs.")
        }
        try checkRequest(request)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw CaptureError.unavailable("English speech support needs to be installed. You can install it, type a clue, or use Quick Needs.")
        }
        try checkRequest(request)
        audioSessionToken = try await AudioSessionController.shared.beginCapture()
        let engine = AVAudioEngine()
        self.engine = engine
        let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else { throw CaptureError.noInput }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: nativeFormat) else {
            throw CaptureError.conversion
        }
        try checkRequest(request)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try checkRequest(request)
        let converter = try StreamingAudioConverter(source: nativeFormat, destination: format)
        let (audio, rawInput) = AsyncStream<CapturedAudioFrame>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let (input, analyzerInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let (eventStream, events) = AsyncStream<SpeechCaptureEvent>.makeStream(bufferingPolicy: .unbounded)
        self.rawInput = rawInput
        self.events = events

        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    events.yield(.transcript(String(result.text.characters), start: result.range.start.seconds, isFinal: result.isFinal))
                }
                if !Task.isCancelled { events.yield(.resultsEnded) }
            } catch {
                if !Task.isCancelled { events.yield(.failed("Speech recognition ended. Try again or type a clue.")) }
            }
        }
        analysisTask = Task.detached {
            do { try await analyzer.start(inputSequence: input) }
            catch { if !Task.isCancelled { events.yield(.failed("Speech couldn’t be processed. Try again or type a clue.")) } }
        }
        processingTask = Task.detached {
            defer { analyzerInput.finish() }
            var lastMeter = ContinuousClock.now - .seconds(1)
            for await frame in audio {
                guard !Task.isCancelled else { break }
                if lastMeter.duration(to: .now) >= .milliseconds(80) {
                    events.yield(.audio(StreamingAudioConverter.meterLevel(frame.buffer)))
                    lastMeter = .now
                }
                do {
                    if let converted = try converter.convert(frame) {
                        if case .dropped = analyzerInput.yield(AnalyzerInput(buffer: converted)) { throw CaptureError.overloaded }
                    }
                } catch {
                    events.yield(.failed("Microphone audio couldn’t be processed. Try again or type a clue."))
                    break
                }
            }
            guard !Task.isCancelled else { return }
            do {
                for tail in try converter.finish() {
                    if case .dropped = analyzerInput.yield(AnalyzerInput(buffer: tail)) {
                        events.yield(.failed("Audio processing fell behind. Try again or type a clue."))
                        break
                    }
                }
            } catch {
                events.yield(.failed("Microphone audio couldn’t be finalized. Try again or type a clue."))
            }
        }
        // The render callback only copies owned PCM data and hands it to the
        // processing stream. It never converts audio or schedules a UI task.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { @Sendable buffer, _ in
            do {
                if case .dropped = rawInput.yield(try CapturedAudioFrame.copy(buffer)) {
                    events.yield(.failed("Audio processing fell behind. Try again or type a clue."))
                    rawInput.finish()
                }
            } catch {
                events.yield(.failed("Microphone audio wasn’t available. Try again or type a clue."))
                rawInput.finish()
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        events.yield(.started)
        speechLogger.info("speech_engine_started")
        return eventStream
    }

    func stop(sessionID: UUID, discardResults: Bool) async {
        guard activeSessionID == sessionID else { return }
        generation += 1
        activeSessionID = nil
        let engine = self.engine
        let analyzer = self.analyzer
        let processing = processingTask
        let analysis = analysisTask
        let results = resultsTask
        let events = self.events
        let hadTap = tapInstalled
        let sessionToken = audioSessionToken
        self.engine = nil
        self.analyzer = nil
        processingTask = nil
        analysisTask = nil
        resultsTask = nil
        self.events = nil
        tapInstalled = false
        audioSessionToken = nil
        // Shutdown stays on this actor, away from SwiftUI. Finish the source
        // after the tap stops so Done can drain the last queued microphone data.
        engine?.stop()
        if hadTap { engine?.inputNode.removeTap(onBus: 0) }
        rawInput?.finish()
        rawInput = nil
        await AudioSessionController.shared.end(sessionToken)
        events?.yield(.stopped)
        guard let analyzer else { events?.finish(); return }
        if discardResults {
            processing?.cancel(); results?.cancel(); analysis?.cancel()
            events?.finish()
            Task { await analyzer.cancelAndFinishNow() }
            return
        }
        // Finalization has a deadline. Its timeout cancels the underlying work,
        // rather than returning while old recognition tasks remain alive.
        await withCheckedContinuation { continuation in
            let completion = CompletionGate(continuation)
            let finishing = Task.detached {
                await processing?.value
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                analysis?.cancel()
                completion.finish()
            }
            let timeout = Task.detached {
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard !Task.isCancelled else { return }
                finishing.cancel(); processing?.cancel(); results?.cancel(); analysis?.cancel()
                if completion.finish() {
                    Task.detached { await analyzer.cancelAndFinishNow() }
                }
            }
            completion.installTimeout(timeout)
        }
        events?.finish()
        speechLogger.info("speech_capture_stopped")
    }

    func installSupport() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw CaptureError.unavailable("English speech recognition isn’t available on this device.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    private func checkRequest(_ request: Int) throws {
        guard request == generation, !Task.isCancelled else { throw CancellationError() }
    }
}

@MainActor @Observable final class SpeechCaptureService {
    enum CaptureState: Equatable { case idle, starting, listening, finishing, unavailable(String), failed(String) }
    private(set) var state: CaptureState = .idle
    private(set) var transcript = ""
    private(set) var signalLevel: Float = 0
    private(set) var microphoneActive = false
    private(set) var hasReceivedAudio = false
    private(set) var microphonePermissionDenied = false
    private(set) var microphonePermissionGranted = false
    private let backend: any SpeechCaptureBackend
    private let requestPermission: @Sendable () async -> Bool
    private let startupTimeout: Duration
    private let noAudioTimeout: Duration
    private let audioStallTimeout: Duration
    private var accumulator = SpeechTranscriptAccumulator()
    private var generation = 0
    private var backendSessionID: UUID?
    private var eventsTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var meterThrottle = SpeechMeterThrottle()

    init(backend: any SpeechCaptureBackend = OnDeviceSpeechCapture(),
         requestPermission: @escaping @Sendable () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         startupTimeout: Duration = .seconds(15), noAudioTimeout: Duration = .seconds(3),
         audioStallTimeout: Duration = .seconds(5)) {
        self.backend = backend
        self.requestPermission = requestPermission
        self.startupTimeout = startupTimeout
        self.noAudioTimeout = noAudioTimeout
        self.audioStallTimeout = audioStallTimeout
    }

    func start() async {
        guard state != .starting, state != .listening, state != .finishing else { return }
        generation += 1
        let request = generation
        let sessionID = UUID()
        backendSessionID = sessionID
        state = .starting
        transcript = ""; accumulator = SpeechTranscriptAccumulator(); signalLevel = 0; hasReceivedAudio = false
        meterThrottle = SpeechMeterThrottle()
        watchdogTask?.cancel()
        let allowed = await requestPermission()
        guard generation == request, !Task.isCancelled else { return }
        microphonePermissionDenied = !allowed
        microphonePermissionGranted = allowed
        guard allowed else {
            watchdogTask?.cancel()
            backendSessionID = nil
            state = .unavailable("Microphone access is off. You can allow it in Settings, type a clue, or use Quick Needs.")
            return
        }
        // Permission dialogs belong to the person: they have no deadline.
        // Only time out device/model setup after access has been granted.
        watchdogTask = Task { [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, self.generation == request, self.state == .starting else { return }
            self.fail("Listening couldn’t start. Try again or type a clue.", request: request)
        }
        do {
            let events = try await backend.start(sessionID: sessionID)
            guard generation == request, !Task.isCancelled else { return }
            eventsTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, self.generation == request else { break }
                    switch event {
                    case .started: self.microphoneActive = true
                    case .audio(let level):
                        self.hasReceivedAudio = true
                        if self.meterThrottle.shouldPublish(at: ProcessInfo.processInfo.systemUptime) {
                            self.signalLevel = level
                        }
                        if self.state == .starting { self.state = .listening }
                        self.scheduleAudioWatchdog(request: request)
                    case .transcript(let text, let start, let isFinal):
                        self.accumulator.update(text, start: start, isFinal: isFinal)
                        self.transcript = self.accumulator.text
                    case .resultsEnded:
                        if self.state != .finishing {
                            self.fail("Speech recognition stopped. Try again or type a clue.", request: request)
                        }
                    case .stopped: self.microphoneActive = false; self.signalLevel = 0
                    case .failed(let message): self.fail(message, request: request)
                    }
                }
            }
            // An engine can report running while its input route delivers no
            // buffers. Do not leave a misleading, indefinitely frozen screen.
            scheduleAudioWatchdog(request: request)
        } catch {
            guard generation == request else { return }
            watchdogTask?.cancel()
            await backend.stop(sessionID: sessionID, discardResults: true)
            guard generation == request else { return }
            backendSessionID = nil
            microphoneActive = false
            if case CaptureError.unavailable(let message) = error { state = .unavailable(message) }
            else if error is CancellationError { state = .idle }
            else { state = .failed("I couldn’t start listening. Try again or type a clue.") }
            speechLogger.notice("speech_start_failed")
        }
    }

    func stop(waitForResults: Bool = true) async -> String {
        let request = generation
        guard let sessionID = backendSessionID else {
            state = .idle
            microphoneActive = false
            signalLevel = 0
            return transcript
        }
        state = .finishing
        watchdogTask?.cancel()
        await backend.stop(sessionID: sessionID, discardResults: !waitForResults)
        // Let buffered final transcript events finish before freezing the review.
        if waitForResults { await eventsTask?.value }
        guard generation == request else { return transcript }
        eventsTask?.cancel(); eventsTask = nil
        backendSessionID = nil
        generation += 1
        microphoneActive = false; signalLevel = 0; state = .idle
        return transcript
    }

    /// UI cancellation never waits for hardware or recognition completion.
    @discardableResult func stopImmediately() -> String {
        generation += 1
        watchdogTask?.cancel(); eventsTask?.cancel(); eventsTask = nil
        signalLevel = 0; state = .idle
        let backend = backend
        let request = generation
        let sessionID = backendSessionID
        backendSessionID = nil
        Task { [weak self] in
            if let sessionID { await backend.stop(sessionID: sessionID, discardResults: true) }
            guard let self, self.generation == request else { return }
            self.microphoneActive = false
        }
        return transcript
    }

    func installSpeechSupport() async {
        do { try await backend.installSupport(); state = .idle }
        catch { state = .unavailable("Speech support wasn’t installed. You can type a clue or use Quick Needs.") }
    }

    func audioInputRouteWasRemoved() {
        guard state == .starting || state == .listening else { return }
        fail("The microphone connection changed. Try listening again, or type a clue.", request: generation)
    }

    private func fail(_ message: String, request: Int) {
        guard generation == request else { return }
        stopImmediately()
        state = .failed(message)
        speechLogger.notice("speech_capture_failed")
    }

    private func scheduleAudioWatchdog(request: Int) {
        watchdogTask?.cancel()
        let timeout = hasReceivedAudio ? audioStallTimeout : noAudioTimeout
        watchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == request else { return }
            if self.hasReceivedAudio {
                self.fail("Microphone audio stopped arriving. Check the audio connection, try again, or type a clue.", request: request)
            } else {
                self.fail("No microphone audio arrived. Check your microphone connection, try again, or type a clue.", request: request)
            }
        }
    }
}

#if DEBUG
/// XCUITest-only backend. Never selected by a normal launch or a Release build.
/// Its screen carries an explicit fixture label and its microphone stays off.
private actor UITestCaptureBackend: SpeechCaptureBackend {
    private var events: AsyncStream<SpeechCaptureEvent>.Continuation?
    private var activeSessionID: UUID?
    func start(sessionID: UUID) async throws -> AsyncStream<SpeechCaptureEvent> {
        let (stream, events) = AsyncStream<SpeechCaptureEvent>.makeStream()
        self.events = events
        activeSessionID = sessionID
        events.yield(.audio(0.5))
        events.yield(.transcript("wa", start: 0, isFinal: false))
        return stream
    }
    func stop(sessionID: UUID, discardResults: Bool) async {
        guard activeSessionID == sessionID else { return }
        if !discardResults { events?.yield(.transcript("water", start: 0, isFinal: true)) }
        events?.yield(.stopped)
        events?.finish()
        events = nil
        activeSessionID = nil
    }
    func installSupport() async throws {}
}
#endif

extension SpeechCaptureService {
    static func forListeningScreen() -> SpeechCaptureService {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-capture") {
            return SpeechCaptureService(backend: UITestCaptureBackend(), requestPermission: { true })
        }
        #endif
        return SpeechCaptureService()
    }
}
