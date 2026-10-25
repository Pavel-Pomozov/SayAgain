import Foundation
import Observation
@preconcurrency import AVFoundation
import OSLog

/// Serializes the app-wide AVAudioSession configuration away from the UI actor.
/// Tokens prevent delayed cleanup from an older operation ending a newer one.
protocol PlaybackAudioSession: Sendable {
    func beginPlayback() async throws -> UUID
    func end(_ token: UUID?) async
}

public actor AudioSessionController: PlaybackAudioSession {
    public static let shared = AudioSessionController()
    private var owner: UUID?

    public func beginCapture() throws -> UUID {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        #endif
        let token = UUID()
        owner = token
        return token
    }

    public func beginPlayback() throws -> UUID {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        #endif
        let token = UUID()
        owner = token
        return token
    }

    public func end(_ token: UUID?) {
        guard let token, owner == token else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        owner = nil
    }
}

public enum SpeechPlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case speaking

    public var isActive: Bool { self != .idle }
}

@MainActor public protocol SpeechOutput: AnyObject {
    var playbackState: SpeechPlaybackState { get }
    var isSpeaking: Bool { get }
    var isPreparing: Bool { get }
    var playbackStartCount: Int { get }
    var playbackError: String? { get }
    var voiceIdentifier: String { get set }
    var rate: Float { get set }
    func speak(_ text: String)
    func stop()
}

@MainActor protocol SpeechSynthesizerBackend: AnyObject {
    var onStart: (@MainActor (ObjectIdentifier) -> Void)? { get set }
    var onFinish: (@MainActor (ObjectIdentifier) -> Void)? { get set }
    var onCancel: (@MainActor (ObjectIdentifier) -> Void)? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopImmediately()
}

@MainActor private final class SystemSpeechSynthesizerBackend: NSObject, SpeechSynthesizerBackend, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    var onStart: (@MainActor (ObjectIdentifier) -> Void)?
    var onFinish: (@MainActor (ObjectIdentifier) -> Void)?
    var onCancel: (@MainActor (ObjectIdentifier) -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        let synthesizer = synthesizerInstance()
        synthesizer.speak(utterance)
    }

    func stopImmediately() {
        synthesizer?.stopSpeaking(at: .immediate)
    }

    private func synthesizerInstance() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let value = AVSpeechSynthesizer()
        value.delegate = self
        synthesizer = value
        return value
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.onStart?(utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.onFinish?(utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.onCancel?(utteranceID) }
    }
}

/// One speech output implementation is shared by the live app and offline demo.
@MainActor @Observable public final class SpeechOutputDriver: NSObject, SpeechOutput {
    private let audioSession: any PlaybackAudioSession
    private let synthesizerFactory: @MainActor () -> any SpeechSynthesizerBackend
    private let startTimeout: Duration
    private let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "SpeechOutput")
    private var synthesizer: (any SpeechSynthesizerBackend)?
    private var activeRequestID: UUID?
    private var activeUtteranceID: ObjectIdentifier?
    private var audioSessionToken: UUID?
    private var activationTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var synthesisStartupInterval: OSSignpostIntervalState?
    public private(set) var playbackState: SpeechPlaybackState = .idle
    public var isSpeaking: Bool { playbackState == .speaking }
    public var isPreparing: Bool { playbackState == .preparing }
    public private(set) var playbackStartCount = 0
    public private(set) var playbackError: String?
    public var voiceIdentifier = ""
    public var rate: Float = 0.50

    public override convenience init() {
        self.init(audioSession: AudioSessionController.shared, synthesizerFactory: { SystemSpeechSynthesizerBackend() })
    }

    init(audioSession: any PlaybackAudioSession,
         startTimeout: Duration = .seconds(5),
         synthesizerFactory: @escaping @MainActor () -> any SpeechSynthesizerBackend) {
        self.audioSession = audioSession
        self.startTimeout = startTimeout
        self.synthesizerFactory = synthesizerFactory
        super.init()
    }

    public func speak(_ text: String) {
        stop()
        playbackError = nil
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        let requestID = UUID()
        activeRequestID = requestID
        playbackState = .preparing
        let startTimeout = self.startTimeout
        startWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: startTimeout) } catch { return }
            guard let self, self.activeRequestID == requestID, self.isPreparing else { return }
            self.playbackError = "Speech didn’t start. Check the device volume or audio connection, then try again."
            self.stop()
        }
        let audioSession = self.audioSession
        let signposter = self.signposter
        let activationInterval = signposter.beginInterval("AudioSessionActivation")
        activationTask = Task { [weak self, audioSession, signposter] in
            defer { signposter.endInterval("AudioSessionActivation", activationInterval) }
            do {
                try Task.checkCancellation()
                let token = try await audioSession.beginPlayback()
                guard let self, self.activeRequestID == requestID else {
                    await audioSession.end(token)
                    return
                }
                self.audioSessionToken = token
                self.enqueue(cleanText, requestID: requestID)
            } catch {
                guard let self, self.activeRequestID == requestID else { return }
                self.playbackError = "Speech couldn’t start. Check the device volume and try again."
                self.finishActiveRequest()
            }
        }
    }

    public func stop() {
        let shouldStopSynthesizer = activeUtteranceID != nil
        activationTask?.cancel()
        activationTask = nil
        if shouldStopSynthesizer { synthesizer?.stopImmediately() }
        finishActiveRequest()
    }

    private func enqueue(_ text: String, requestID: UUID) {
        guard activeRequestID == requestID else { return }
        let utterance = AVSpeechUtterance(string: text)
        let selectedVoice = voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = 1
        activeUtteranceID = ObjectIdentifier(utterance)
        synthesisStartupInterval = signposter.beginInterval("SynthesisEnqueueToStart")
        let synthesizer = synthesizer ?? synthesizerFactory()
        self.synthesizer = synthesizer
        synthesizer.onStart = { [weak self] utteranceID in self?.didStart(utteranceID) }
        synthesizer.onFinish = { [weak self] utteranceID in self?.didFinish(utteranceID) }
        synthesizer.onCancel = { [weak self] utteranceID in self?.didCancel(utteranceID) }
        synthesizer.speak(utterance)
    }

    private func finishActiveRequest() {
        activeRequestID = nil
        activeUtteranceID = nil
        activationTask = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        endSynthesisStartupInterval()
        playbackState = .idle
        let token = audioSessionToken
        audioSessionToken = nil
        Task { await audioSession.end(token) }
    }

    private func didStart(_ utteranceID: ObjectIdentifier) {
        guard activeUtteranceID == utteranceID, playbackState == .preparing else { return }
        startWatchdog?.cancel()
        startWatchdog = nil
        endSynthesisStartupInterval()
        playbackState = .speaking
        playbackStartCount += 1
    }

    private func didFinish(_ utteranceID: ObjectIdentifier) {
        finishCallback(utteranceID, countIfStartWasNotObserved: true)
    }

    private func didCancel(_ utteranceID: ObjectIdentifier) {
        finishCallback(utteranceID, countIfStartWasNotObserved: false)
    }

    private func finishCallback(_ utteranceID: ObjectIdentifier, countIfStartWasNotObserved: Bool) {
        guard activeUtteranceID == utteranceID else { return }
        if countIfStartWasNotObserved && playbackState == .preparing { playbackStartCount += 1 }
        finishActiveRequest()
    }

    private func endSynthesisStartupInterval() {
        guard let interval = synthesisStartupInterval else { return }
        signposter.endInterval("SynthesisEnqueueToStart", interval)
        synthesisStartupInterval = nil
    }
}

import SwiftUI

/// One persistent, native primary control for speech playback.
public struct SpeechPlaybackButton: View {
    private let state: SpeechPlaybackState
    private let idleTitle: String
    private let activeTitle: String
    private let font: Font
    private let action: () -> Void

    public init(state: SpeechPlaybackState, idleTitle: String, activeTitle: String,
                font: Font = .title3, action: @escaping () -> Void) {
        self.state = state
        self.idleTitle = idleTitle
        self.activeTitle = activeTitle
        self.font = font
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(state.isActive ? activeTitle : idleTitle,
                  systemImage: state.isActive ? "stop.fill" : "speaker.wave.2.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
        }
        .font(font)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("speechPlaybackControl")
    }
}
