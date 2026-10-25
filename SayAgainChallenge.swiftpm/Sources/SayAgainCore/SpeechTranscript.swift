import Foundation

/// Preserves incomplete text, replaces evolving segments, and removes revoked
/// volatile results. No transcript is stored outside the active session.
public struct SpeechTranscriptAccumulator: Sendable {
    private struct Segment: Sendable {
        let start: Double
        var text: String
        var isFinal: Bool
    }
    private var segments: [Segment] = []
    public init() {}
    public var text: String { segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") }

    public mutating func update(_ text: String, start: Double, isFinal: Bool) {
        guard start.isFinite else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = segments.firstIndex(where: { abs($0.start - start) < 0.01 }) {
            guard !segments[index].isFinal || isFinal else { return }
            if clean.isEmpty { segments.remove(at: index) }
            else { segments[index].text = clean; segments[index].isFinal = isFinal }
        } else if !clean.isEmpty {
            segments.append(Segment(start: start, text: clean, isFinal: isFinal))
        }
    }
}
