import Foundation
import OSLog

public struct VocabularyTerm: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let canonicalText: String
    public let displayText: String
    public let category: PersonalTermCategory
    public let contextIDs: [String]
    public let symbolName: String?
    public let synonyms: [String]
    public let usageCount: Int
    public let confirmationCount: Int
    public let lastUsedAt: Date?
    public let isPersonal: Bool
    public let relationship: String?
    /// Stable tie breaker independent of the order terms arrive from SwiftData.
    /// Built-in vocabulary uses its curated order; personal terms sort after it.
    public let rankingPriority: Int

    public init(id: UUID, canonicalText: String, displayText: String, category: PersonalTermCategory,
                contextIDs: [String] = [], symbolName: String? = nil, synonyms: [String] = [],
                usageCount: Int = 0, confirmationCount: Int = 0, lastUsedAt: Date? = nil,
                isPersonal: Bool = false, relationship: String? = nil,
                rankingPriority: Int = Int.max) {
        self.id = id; self.canonicalText = canonicalText; self.displayText = displayText
        self.category = category; self.contextIDs = contextIDs; self.symbolName = symbolName
        self.synonyms = synonyms; self.usageCount = usageCount; self.confirmationCount = confirmationCount
        self.lastUsedAt = lastUsedAt; self.isPersonal = isPersonal
        self.relationship = relationship; self.rankingPriority = rankingPriority
    }
}

public struct RankingInput: Sendable {
    public var speech: String?
    public var typed: String?
    public var visualLabels: [String]
    public var contextID: String?
    public var mappings: [MappingEvidence]
    public var now: Date
    public var learningEnabled: Bool
    public init(speech: String? = nil, typed: String? = nil, visualLabels: [String] = [],
                contextID: String? = nil, mappings: [MappingEvidence] = [], now: Date = .now,
                learningEnabled: Bool = false) {
        self.speech = speech; self.typed = typed; self.visualLabels = visualLabels
        self.contextID = contextID; self.mappings = mappings; self.now = now; self.learningEnabled = learningEnabled
    }
}

public struct MappingEvidence: Sendable, Hashable {
    public let normalizedFragment: String
    public let termID: UUID
    public let contextID: String?
    public let confirmationCount: Int
    public init(normalizedFragment: String, termID: UUID, contextID: String?, confirmationCount: Int) {
        self.normalizedFragment = normalizedFragment; self.termID = termID
        self.contextID = contextID; self.confirmationCount = confirmationCount
    }
}

public enum TextNormalizer {
    public static func normalize(_ value: String) -> String {
        let lower = value.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        let allowed = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || (scalar == "'" || scalar == "’") ? Character(scalar == "’" ? "'" : String(scalar)) : " "
        }
        return String(allowed).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct CandidateScoringPolicy: Sendable {
    public var speech = 0.45
    public var visual = 0.20
    public var context = 0.15
    public var confirmedMapping = 0.10
    public var recencyUse = 0.10
    public var personalTieBreak = 0.05
    public var visualConfidenceThreshold = 0.25
    public init() {}
}

/// Immutable, pre-normalized vocabulary used by repeated deterministic
/// retrieval. Build it when vocabulary changes, then reuse it for clue edits.
public struct PreparedVocabulary: Sendable {
    fileprivate struct Entry: Sendable {
        let term: VocabularyTerm
        let aliases: [String]
        let displayLabel: String
        let normalizedDisplayLabel: String
        let sourceIndex: Int
    }

    fileprivate let entries: [Entry]

    public init(terms: [VocabularyTerm]) {
        var seen = Set<UUID>()
        entries = terms.enumerated().compactMap { index, term in
            guard seen.insert(term.id).inserted else { return nil }
            let aliases = ([term.canonicalText, term.displayText] + term.synonyms)
                .map { String(TextNormalizer.normalize($0).prefix(128)) }
                .filter { !$0.isEmpty }
            let displayLabel = term.relationship.map { "\(term.displayText) — \($0)" } ?? term.displayText
            return Entry(term: term, aliases: aliases, displayLabel: displayLabel,
                         normalizedDisplayLabel: TextNormalizer.normalize(displayLabel), sourceIndex: index)
        }
    }
}

public struct DeterministicCandidateEngine: Sendable {
    public let policy: CandidateScoringPolicy
    public init(policy: CandidateScoringPolicy = CandidateScoringPolicy()) { self.policy = policy }

    public func prepare(terms: [VocabularyTerm]) -> PreparedVocabulary {
        let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "CandidateEngine")
        let interval = signposter.beginInterval("VocabularyPreparation")
        defer { signposter.endInterval("VocabularyPreparation", interval) }
        return PreparedVocabulary(terms: terms)
    }

    public func rank(terms: [VocabularyTerm], input: RankingInput, limit: Int = 12) -> [CommunicationCandidate] {
        rank(prepared: prepare(terms: terms), input: input, limit: limit)
    }

    public func rank(prepared: PreparedVocabulary, input: RankingInput, limit: Int = 12) -> [CommunicationCandidate] {
        let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "CandidateEngine")
        let interval = signposter.beginInterval("DeterministicRanking")
        defer { signposter.endInterval("DeterministicRanking", interval) }
        let speech = TextNormalizer.normalize(input.speech ?? "")
        let typed = TextNormalizer.normalize(input.typed ?? "")
        // Keep fuzzy matching bounded even when a user pastes a long message.
        // Long-form messages belong in the exact-message flow, not edit distance.
        let clues = [speech, typed].map { String($0.prefix(64)) }.filter { !$0.isEmpty }
        let labels = input.visualLabels.map { String(TextNormalizer.normalize($0).prefix(64)) }.filter { !$0.isEmpty }
        var ranked: [(CommunicationCandidate, Bool, Int, Int, String)] = []
        let clueSet = Set(clues)
        var mappingsByTermID: [UUID: [MappingEvidence]] = [:]
        if input.learningEnabled && !clueSet.isEmpty {
            var matchingMappings: [MappingEvidence] = []
            matchingMappings.reserveCapacity(input.mappings.count)
            for (index, mapping) in input.mappings.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return [] }
                if clueSet.contains(TextNormalizer.normalize(mapping.normalizedFragment)) {
                    matchingMappings.append(mapping)
                }
            }
            mappingsByTermID = Dictionary(grouping: matchingMappings, by: \.termID)
        }

        for (sourceIndex, entry) in prepared.entries.enumerated() {
            if sourceIndex.isMultiple(of: 32), Task.isCancelled { break }
            let term = entry.term
            guard !term.displayText.isEmpty else { continue }
            let aliases = entry.aliases
            let speechScore = clues.map { clue in aliases.map { similarity(clue, $0) }.max() ?? 0 }.max() ?? 0
            let visualScore = labels.flatMap { label in
                aliases.map { alias in
                    if label == alias { return 1.0 }
                    if label.count >= 3, alias.count >= 3,
                       label.contains(alias) || alias.contains(label) { return 0.72 }
                    return 0.0
                }
            }.max() ?? 0
            let contextScore = input.contextID.map { term.contextIDs.contains($0) ? 1.0 : 0.0 } ?? 0
            let matchedMapping: MappingEvidence? = input.learningEnabled
                ? (mappingsByTermID[term.id] ?? [])
                    .filter { mapping in
                        (mapping.contextID == nil || mapping.contextID == input.contextID)
                    }
                    .sorted { lhs, rhs in
                        let lhsContextMatch = lhs.contextID == input.contextID && lhs.contextID != nil
                        let rhsContextMatch = rhs.contextID == input.contextID && rhs.contextID != nil
                        if lhsContextMatch != rhsContextMatch { return lhsContextMatch }
                        if lhs.confirmationCount != rhs.confirmationCount { return lhs.confirmationCount > rhs.confirmationCount }
                        return (lhs.contextID ?? "").localizedCompare(rhs.contextID ?? "") == .orderedAscending
                    }
                    .first
                : nil
            let mappingScore = matchedMapping.map { min(Double(max($0.confirmationCount, 0)) / 3.0, 1.0) } ?? 0
            let recent = input.learningEnabled ? recencyUse(term, now: input.now) : 0
            let active = [
                (policy.speech, clues.isEmpty ? nil : speechScore),
                (policy.visual, labels.isEmpty ? nil : visualScore),
                (policy.context, input.contextID == nil ? nil : contextScore),
                (policy.confirmedMapping, input.learningEnabled && clues.isEmpty == false ? mappingScore : nil),
                (policy.recencyUse, input.learningEnabled ? recent : nil)
            ].compactMap { weight, score in score.map { (weight, $0) } }
            let totalWeight = active.reduce(0) { $0 + $1.0 }
            let weighted = totalWeight > 0 ? active.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight : 0
            let personalBoost = term.isPersonal ? policy.personalTieBreak : 0
            let score = weighted + personalBoost

            var evidence: CommunicationCandidate.Evidence = []
            if speechScore > 0 || (typed.isEmpty == false && aliases.contains(where: { $0.hasPrefix(typed) })) { evidence.insert(.speechMatch) }
            if term.isPersonal { evidence.insert(.personalVocabulary) }
            if visualScore > 0 { evidence.insert(.visualClue) }
            if contextScore > 0 { evidence.insert(.contextMatch) }
            if matchedMapping != nil { evidence.insert(.confirmedMapping) }
            if recent > 0 { evidence.insert(.recentUsage) }
            let candidate = CommunicationCandidate(id: term.id, displayLabel: entry.displayLabel,
                icon: term.symbolName, evidence: evidence, deterministicScore: score)
            let searchable = clues.isEmpty == false || labels.isEmpty == false || input.contextID != nil || recent > 0
            let sparse = clues.allSatisfy { $0.count <= 2 }
            let supported = speechScore > 0 || visualScore > 0 || mappingScore > 0
                || ((clues.isEmpty || sparse) && contextScore > 0) || (clues.isEmpty && labels.isEmpty && recent > 0)
            if searchable && supported {
                ranked.append((candidate, term.isPersonal, entry.sourceIndex, term.rankingPriority, entry.normalizedDisplayLabel))
            }
        }

        return ranked.sorted {
            if $0.0.deterministicScore != $1.0.deterministicScore {
                return $0.0.deterministicScore > $1.0.deterministicScore
            }
            if $0.1 != $1.1 { return $0.1 }
            let lhsPriority = $0.3
            let rhsPriority = $1.3
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let lhsName = $0.4
            let rhsName = $1.4
            if lhsName != rhsName { return lhsName < rhsName }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.prefix(max(0, limit)).map(\.0)
    }

    private func similarity(_ clue: String, _ candidate: String) -> Double {
        if clue == candidate { return 1.0 }
        if candidate.hasPrefix(clue) { return clue.count == 1 ? 0.65 : 0.90 }
        guard clue.count >= 2 else { return 0 }
        if candidate.contains(clue) { return 0.72 }
        let distance = levenshtein(Array(clue), Array(candidate))
        let score = 1.0 - Double(distance) / Double(max(clue.count, candidate.count))
        return score >= 0.45 ? score : 0
    }

    private func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private func recencyUse(_ term: VocabularyTerm, now: Date) -> Double {
        let count = min(Double(max(term.usageCount, 0)) / 10.0, 1.0)
        guard let last = term.lastUsedAt else { return count * 0.5 }
        let days = max(now.timeIntervalSince(last) / 86_400, 0)
        let decay = pow(0.5, days / 30.0)
        return (count * 0.5) + (decay * 0.5)
    }
}

public enum SeedVocabulary {
    public static let terms: [VocabularyTerm] = [
        term("Want", .needs, ["want", "need"], nil, contexts: ["home", "conversation"]),
        term("Wash", .activities, ["wash", "washing"], "hands.sparkles", contexts: ["home"]),
        term("Walk", .activities, ["walk", "walking"], "figure.walk", contexts: ["home"]),
        term("Water", .foodAndDrink, ["water", "drink", "glass", "cup"], "drop", contexts: ["food", "home"]),
        term("Coffee", .foodAndDrink, ["coffee", "caffeine"], "cup.and.saucer", contexts: ["food", "home"]),
        term("Bathroom", .needs, ["bathroom", "toilet", "restroom"], "figure.stand", contexts: ["home"]),
        term("Help", .needs, ["help", "assist"], "hand.raised", contexts: ["home", "medical", "conversation"]),
        term("Yes", .needs, ["yes", "okay"], "checkmark", contexts: ["conversation"]),
        term("No", .needs, ["no", "not"], "xmark", contexts: ["conversation"]),
        term("Agree", .custom, ["agree", "consent", "yes I agree"], nil, contexts: ["conversation", "medical"]),
        term("Do Not Agree", .custom, ["do not agree", "don't agree", "refuse", "no consent"], nil, contexts: ["conversation", "medical"]),
        term("Pain", .medicalBody, ["pain", "hurt"], "cross.case", contexts: ["medical"]),
        term("Medication", .medicalBody, ["medication", "medicine", "pills"], "pills", contexts: ["medical"]),
        term("Emergency", .medicalBody, ["emergency"], "phone.badge.exclamationmark", contexts: ["medical"]),
        term("Call", .custom, ["call", "phone"], "phone", contexts: ["conversation"]),
        term("Food", .foodAndDrink, ["food", "eat", "meal"], "fork.knife", contexts: ["food"]),
        term("More", .needs, ["more", "again"], "plus", contexts: ["food", "home"]),
        term("Stop", .needs, ["stop", "enough"], "stop", contexts: ["conversation"]),
        term("Please", .custom, ["please"], nil, contexts: ["conversation"]),
        term("Thank you", .custom, ["thank you", "thanks"], nil, contexts: ["conversation"]),
        term("Doctor", .medicalBody, ["doctor", "physician"], "cross.case", contexts: ["medical"]),
        term("Cup", .custom, ["cup", "mug", "drinking glass", "glass"], "cup.and.saucer", contexts: ["food", "home"]),
        term("Bottle", .custom, ["bottle", "flask"], nil, contexts: ["food", "home"]),
        term("Key", .custom, ["key", "keys"], "key", contexts: ["home"]),
        term("Chair", .custom, ["chair", "seat"], "chair", contexts: ["home"]),
        term("Table", .custom, ["table", "desk"], nil, contexts: ["home", "food"]),
        term("Door", .custom, ["door", "entrance"], "door.left.hand.closed", contexts: ["home"]),
        term("Phone", .custom, ["phone", "telephone", "mobile"], "phone", contexts: ["home", "conversation"]),
        term("Plate", .custom, ["plate", "dish"], nil, contexts: ["food", "home"]),
        term("Fork", .custom, ["fork"], "fork.knife", contexts: ["food"]),
        term("Spoon", .custom, ["spoon"], nil, contexts: ["food"]),
        term("Bread", .foodAndDrink, ["bread", "toast"], nil, contexts: ["food"]),
        term("Apple", .foodAndDrink, ["apple"], nil, contexts: ["food"]),
        term("Banana", .foodAndDrink, ["banana"], nil, contexts: ["food"]),
        term("Milk", .foodAndDrink, ["milk"], nil, contexts: ["food"]),
        term("Tea", .foodAndDrink, ["tea"], "cup.and.saucer", contexts: ["food"]),
        term("Juice", .foodAndDrink, ["juice"], nil, contexts: ["food"]),
        term("Sleep", .activities, ["sleep", "bed", "rest"], "bed.double", contexts: ["home"]),
        term("Outside", .places, ["outside", "outdoors", "garden"], nil, contexts: ["home"]),
        term("Home", .places, ["home", "house"], "house", contexts: ["home"]),
        term("Hungry", .needs, ["hungry"], nil, contexts: ["food"]),
        term("Plant", .custom, ["plant", "potted plant", "houseplant", "flowerpot", "flower pot"], "leaf", contexts: ["home"]),
        term("Flower", .custom, ["flower", "flowers"], nil, contexts: ["home"]),
        term("Tree", .custom, ["tree"], nil, contexts: ["home"]),
        term("Cold", .needs, ["cold"], nil, contexts: ["home"]),
        term("Hot", .needs, ["hot", "warm"], nil, contexts: ["home"]),
        // Body regions belong to the explicit Pain flow, not generic retrieval.
    ].enumerated().map { index, term in
        VocabularyTerm(id: term.id, canonicalText: term.canonicalText, displayText: term.displayText,
            category: term.category, contextIDs: term.contextIDs, symbolName: term.symbolName,
            synonyms: term.synonyms, usageCount: term.usageCount, confirmationCount: term.confirmationCount,
            lastUsedAt: term.lastUsedAt, isPersonal: term.isPersonal, relationship: term.relationship,
            rankingPriority: index)
    }

    private static func term(_ name: String, _ category: PersonalTermCategory, _ synonyms: [String], _ symbol: String?, contexts: [String]) -> VocabularyTerm {
        VocabularyTerm(id: UUID(uuidString: uuidFor(name)) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), canonicalText: name, displayText: name, category: category,
                       contextIDs: contexts, symbolName: symbol, synonyms: synonyms, isPersonal: false)
    }
    private static func uuidFor(_ value: String) -> String {
        var bytes = Array(value.utf8.prefix(16))
        while bytes.count < 16 { bytes.append(0) }
        var hex = Array(bytes.map { String(format: "%02x", $0) }.joined())
        hex[12] = "4"; hex[16] = "a"
        let source = String(hex)
        return "\(source.prefix(8))-\(source.dropFirst(8).prefix(4))-\(source.dropFirst(12).prefix(4))-\(source.dropFirst(16).prefix(4))-\(source.dropFirst(20).prefix(12))"
    }
}
