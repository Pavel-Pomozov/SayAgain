import Foundation
import SwiftData

public enum CommunicationContextKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case home, food, medical, conversation, custom
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct ContextChoice: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: CommunicationContextKind

    public init(id: String, name: String, kind: CommunicationContextKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public static let home = ContextChoice(id: "home", name: "Home", kind: .home)
    public static let food = ContextChoice(id: "food", name: "Food", kind: .food)
    public static let medical = ContextChoice(id: "medical", name: "Medical", kind: .medical)
    public static let conversation = ContextChoice(id: "conversation", name: "Conversation", kind: .conversation)
    public static let builtIns: [ContextChoice] = [.home, .food, .medical, .conversation]
}

public enum PersonalTermCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case people = "People"
    case places = "Places"
    case foodAndDrink = "Food & Drink"
    case needs = "Needs"
    case medicalBody = "Medical / Body"
    case activities = "Activities"
    case custom = "Custom"
    public var id: String { rawValue }
}

@Model public final class PersonalTerm {
    @Attribute(.unique) public var id: UUID
    public var canonicalText: String
    public var displayText: String
    public var categoryRawValue: String
    public var contextIDs: [String]
    public var symbolName: String?
    public var relationship: String?
    public var synonyms: [String]
    public var usageCount: Int
    public var confirmationCount: Int
    public var lastUsedAt: Date?
    public var enabled: Bool

    public var category: PersonalTermCategory {
        get { PersonalTermCategory(rawValue: categoryRawValue) ?? .custom }
        set { categoryRawValue = newValue.rawValue }
    }

    public init(id: UUID = UUID(), canonicalText: String, displayText: String? = nil,
                category: PersonalTermCategory = .custom, contextIDs: [String] = [],
                symbolName: String? = nil, relationship: String? = nil, synonyms: [String] = [],
                usageCount: Int = 0, confirmationCount: Int = 0, lastUsedAt: Date? = nil,
                enabled: Bool = true) {
        self.id = id
        self.canonicalText = canonicalText
        self.displayText = displayText ?? canonicalText
        self.categoryRawValue = category.rawValue
        self.contextIDs = contextIDs
        self.symbolName = symbolName
        self.relationship = relationship
        self.synonyms = synonyms
        self.usageCount = usageCount
        self.confirmationCount = confirmationCount
        self.lastUsedAt = lastUsedAt
        self.enabled = enabled
    }
}

@Model public final class PersonalPhrase {
    @Attribute(.unique) public var id: UUID
    public var spokenText: String
    public var relatedTermIDs: [UUID]
    public var contextIDs: [String]
    public var usageCount: Int
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), spokenText: String, relatedTermIDs: [UUID] = [],
                contextIDs: [String] = [], usageCount: Int = 0, lastUsedAt: Date? = nil) {
        self.id = id
        self.spokenText = spokenText
        self.relatedTermIDs = relatedTermIDs
        self.contextIDs = contextIDs
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
    }

    /// Removes one vocabulary link. Returns true when the phrase has no
    /// remaining term associations and can be deleted with that term.
    @discardableResult public func unlink(termID: UUID) -> Bool {
        relatedTermIDs.removeAll { $0 == termID }
        return relatedTermIDs.isEmpty
    }
}

@Model public final class ConfirmedMapping {
    @Attribute(.unique) public var id: UUID
    public var normalizedSpeechFragment: String
    public var confirmedTermID: UUID
    public var contextID: String?
    public var confirmationCount: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), normalizedSpeechFragment: String, confirmedTermID: UUID,
                contextID: String? = nil, confirmationCount: Int = 1, createdAt: Date = .now) {
        self.id = id
        self.normalizedSpeechFragment = normalizedSpeechFragment
        self.confirmedTermID = confirmedTermID
        self.contextID = contextID
        self.confirmationCount = confirmationCount
        self.createdAt = createdAt
    }
}

@Model public final class SavedContext {
    @Attribute(.unique) public var id: String
    public var name: String
    public init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }
}

@Model public final class RecentPhrase {
    @Attribute(.unique) public var id: UUID
    public var spokenText: String
    public var termID: UUID?
    public var contextID: String?
    public var createdAt: Date
    public init(id: UUID = UUID(), spokenText: String, termID: UUID?, contextID: String?, createdAt: Date = .now) {
        self.id = id; self.spokenText = spokenText; self.termID = termID; self.contextID = contextID; self.createdAt = createdAt
    }
}

/// Local recency data for bundled terms. It is written only from a user
/// confirmed spoken choice when learned patterns are enabled.
@Model public final class TermUsage {
    @Attribute(.unique) public var termID: UUID
    public var usageCount: Int
    public var lastUsedAt: Date?

    public init(termID: UUID, usageCount: Int = 0, lastUsedAt: Date? = nil) {
        self.termID = termID
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
    }
}

public struct CommunicationSession: Sendable {
    public let id: UUID
    public let startedAt: Date
    public var context: ContextChoice
    public var rawTranscript: String?
    public var normalizedTranscript: String?
    public var typedClue: String?
    public var visualLabels: [String]
    public var candidates: [CommunicationCandidate]
    public var confirmedTermID: UUID?
    public var selectedPhrase: String?
    public var endedAt: Date?

    public init(context: ContextChoice = .home) {
        id = UUID(); startedAt = .now; self.context = context
        rawTranscript = nil; normalizedTranscript = nil; typedClue = nil
        visualLabels = []; candidates = []; confirmedTermID = nil; selectedPhrase = nil; endedAt = nil
    }
}

public struct CommunicationCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayLabel: String
    public let icon: String?
    public let evidence: Evidence
    public let deterministicScore: Double
    public var rerankedPosition: Int?

    public init(id: UUID, displayLabel: String, icon: String?, evidence: Evidence,
                deterministicScore: Double, rerankedPosition: Int? = nil) {
        self.id = id; self.displayLabel = displayLabel; self.icon = icon
        self.evidence = evidence; self.deterministicScore = deterministicScore; self.rerankedPosition = rerankedPosition
    }

    public struct Evidence: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let speechMatch = Evidence(rawValue: 1 << 0)
        public static let personalVocabulary = Evidence(rawValue: 1 << 1)
        public static let visualClue = Evidence(rawValue: 1 << 2)
        public static let contextMatch = Evidence(rawValue: 1 << 3)
        public static let confirmedMapping = Evidence(rawValue: 1 << 4)
        public static let recentUsage = Evidence(rawValue: 1 << 5)
    }
}

/// Temporary labels from intentional photo clues. An unsuccessful clue never
/// erases earlier evidence; raw images are not stored here.
public struct VisualClues: Sendable, Equatable {
    public private(set) var photo: [String] = []
    public init() {}
    public var combined: [String] { photo }
    public mutating func applyPhoto(_ labels: [String]) {
        let useful = Array(Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !useful.isEmpty else { return }
        photo = useful
    }

    /// An empty classifier result is deliberately not treated as a removal;
    /// the person must ask to remove the photo clue.
    public mutating func removePhoto() { photo = [] }
}
