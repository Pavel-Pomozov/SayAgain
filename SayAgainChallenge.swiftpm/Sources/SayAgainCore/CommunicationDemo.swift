import Foundation

/// Local example inputs, never live microphone or camera recognition.
public struct CommunicationDemo: Sendable {
    public enum Example: Sendable { case breakfast, personalWord }
    public enum Step: Sendable { case introduction, suggestions, phrases, speak, conclusion }
    public private(set) var example: Example = .breakfast
    public private(set) var step: Step = .introduction
    public private(set) var hasVisualClue = false
    public private(set) var selectedTerm: VocabularyTerm?
    public private(set) var phrase = ""
    public init() {}

    public var speech: String { example == .breakfast ? "wa..." : "Sa..." }
    public var visualLabels: [String] { hasVisualClue ? ["glass", "drink"] : [] }
    public var terms: [VocabularyTerm] {
        guard example == .personalWord else { return SeedVocabulary.terms }
        let sarah = VocabularyTerm(id: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1)),
            canonicalText: "Sarah", displayText: "Sarah", category: .people,
            contextIDs: ["conversation"], synonyms: ["Sa"], isPersonal: true)
        return SeedVocabulary.terms + [sarah]
    }
    public var candidates: [CommunicationCandidate] {
        DeterministicCandidateEngine().rank(terms: terms,
            input: RankingInput(speech: speech, visualLabels: visualLabels,
                contextID: example == .personalWord ? "conversation" : nil), limit: 4)
    }
    public var phrases: [String] { selectedTerm.map(PhraseLibrary.phrases(for:)) ?? [] }
    public mutating func begin(_ example: Example = .breakfast) {
        self = CommunicationDemo()
        self.example = example
        step = .suggestions
    }
    public mutating func addVisualClue() {
        guard example == .breakfast, step == .suggestions else { return }
        hasVisualClue = true
    }
    public mutating func select(_ id: UUID) {
        guard step == .suggestions, let term = terms.first(where: { $0.id == id }) else { return }
        selectedTerm = term
        phrase = ""
        step = .phrases
    }
    public mutating func selectPhrase(_ option: String) {
        guard step == .phrases, let selectedTerm, phrases.contains(option) else { return }
        phrase = PhraseLibrary.spokenText(for: option, term: selectedTerm)
        step = .speak
    }
    public mutating func finish() { if step == .speak { step = .conclusion } }
    public mutating func back() {
        switch step {
        case .introduction: break
        case .suggestions:
            if hasVisualClue { hasVisualClue = false }
            else { step = .introduction }
        case .phrases: step = .suggestions
        case .speak: step = .phrases
        case .conclusion: step = .speak
        }
    }
    public mutating func restart() { self = CommunicationDemo() }
}

/// A delayed model result never changes displayed rows automatically.
public struct SuggestionOrder: Sendable {
    public private(set) var displayed: [UUID] = []
    public private(set) var pending: [UUID]?
    public init() {}
    public mutating func reset(_ ids: [UUID]) { displayed = ids; pending = nil }
    public mutating func propose(_ ids: [UUID]) {
        guard let validated = CandidateOrderValidator.orderedIDs(ids, shortlist: displayed), validated != displayed else { return }
        pending = validated
    }
    public mutating func apply() { if let pending { displayed = pending }; pending = nil }
}
