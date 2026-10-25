import Foundation
import SwiftData

/// A receipt describes only writes this communication session made. It lets a
/// later, explicitly spoken correction replace those writes without erasing
/// earlier confirmations made in other sessions.
public struct SpokenChoiceReceipt: Equatable, Sendable {
    fileprivate struct UsageSnapshot: Equatable, Sendable {
        let usageCount: Int
        let confirmationCount: Int
        let lastUsedAt: Date?
    }
    fileprivate struct PhraseSnapshot: Equatable, Sendable {
        let usageCount: Int
        let lastUsedAt: Date?
    }
    fileprivate struct TermUsageSnapshot: Equatable, Sendable {
        let usageCount: Int
        let lastUsedAt: Date?
    }

    fileprivate let normalizedFragment: String
    fileprivate let termID: UUID
    fileprivate let contextID: String?
    fileprivate let phrase: String
    fileprivate let didLearn: Bool
    fileprivate let mappingID: UUID?
    fileprivate let mappingCountBefore: Int?
    fileprivate let personalUsageBefore: UsageSnapshot?
    fileprivate let builtInUsageBefore: TermUsageSnapshot?
    fileprivate let didSaveHistory: Bool
    fileprivate let historyID: UUID?
    fileprivate let personalPhraseID: UUID?
    fileprivate let personalPhraseUsageBefore: PhraseSnapshot?

    fileprivate init(normalizedFragment: String, termID: UUID, contextID: String?, phrase: String,
                     didLearn: Bool, mappingID: UUID?, mappingCountBefore: Int?,
                     personalUsageBefore: UsageSnapshot?, builtInUsageBefore: TermUsageSnapshot?,
                     didSaveHistory: Bool, historyID: UUID?,
                     personalPhraseID: UUID?, personalPhraseUsageBefore: PhraseSnapshot?) {
        self.normalizedFragment = normalizedFragment
        self.termID = termID
        self.contextID = contextID
        self.phrase = phrase
        self.didLearn = didLearn
        self.mappingID = mappingID
        self.mappingCountBefore = mappingCountBefore
        self.personalUsageBefore = personalUsageBefore
        self.builtInUsageBefore = builtInUsageBefore
        self.didSaveHistory = didSaveHistory
        self.historyID = historyID
        self.personalPhraseID = personalPhraseID
        self.personalPhraseUsageBefore = personalPhraseUsageBefore
    }
}

/// Owned by one communication session. It records choices only after speech
/// output starts, ignores Replay duplicates, and can atomically replace the
/// previous spoken choice when the person corrects it in the same session.
@MainActor public final class ConfirmedChoiceRecorder {
    private struct LearningKey: Hashable {
        let fragment: String
        let termID: UUID
        let contextID: String?
    }
    private struct HistoryKey: Hashable {
        let phrase: String
        let termID: UUID?
        let contextID: String?
    }

    private var learned = Set<LearningKey>()
    private var savedPhrases = Set<HistoryKey>()
    private var sessionReceipts: [LearningKey: SpokenChoiceReceipt] = [:]
    private var historyReceipts: [HistoryKey: UUID] = [:]
    private var personalPhraseReceipts: [UUID: SpokenChoiceReceipt] = [:]
    public init() {}

    @discardableResult
    public func record(term: VocabularyTerm, speech: String, phrase: String, contextID: String?,
                       learn: Bool, saveHistory: Bool, replacing previous: SpokenChoiceReceipt? = nil,
                       in context: ModelContext) throws -> SpokenChoiceReceipt? {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhrase.isEmpty else { return previous }
        let fragment = TextNormalizer.normalize(speech)
        let learningKey = LearningKey(fragment: fragment, termID: term.id, contextID: contextID)
        let historyKey = HistoryKey(phrase: cleanPhrase, termID: term.id, contextID: contextID)
        let replacingSameLearning = previous?.termID == term.id
            && previous?.normalizedFragment == fragment && previous?.contextID == contextID
        let replacingSameHistory = previous?.termID == term.id
            && previous?.phrase == cleanPhrase && previous?.contextID == contextID

        if let previous,
           previous.termID == term.id,
           previous.normalizedFragment == fragment,
           previous.contextID == contextID,
           previous.phrase == cleanPhrase {
            return previous
        }

        let cachedLearning = sessionReceipts[learningKey]
        let cachedHistoryID = historyReceipts[historyKey]
        let shouldLearn = learn && (!learned.contains(learningKey) || (previous?.didLearn == true && replacingSameLearning))
        let shouldSaveHistory = saveHistory && (!savedPhrases.contains(historyKey) || (previous?.didSaveHistory == true && replacingSameHistory))
        let phraseToUpdate: PersonalPhrase? = try context.fetch(FetchDescriptor<PersonalPhrase>())
            .filter { $0.spokenText == cleanPhrase && $0.relatedTermIDs.contains(term.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .first
        let cachedPersonalPhrase = phraseToUpdate.flatMap { personalPhraseReceipts[$0.id] }
        let replacingSamePersonalPhrase = previous?.personalPhraseID == phraseToUpdate?.id
        let shouldUpdatePersonalPhrase = learn && phraseToUpdate != nil
            && (cachedPersonalPhrase == nil || replacingSamePersonalPhrase)
        guard previous != nil || shouldLearn || shouldSaveHistory || shouldUpdatePersonalPhrase else {
            if let cachedLearning { return cachedLearning }
            if let cachedHistoryID {
                return SpokenChoiceReceipt(normalizedFragment: fragment, termID: term.id,
                    contextID: contextID, phrase: cleanPhrase, didLearn: false, mappingID: nil,
                    mappingCountBefore: nil, personalUsageBefore: nil, builtInUsageBefore: nil, didSaveHistory: true,
                    historyID: cachedHistoryID, personalPhraseID: nil, personalPhraseUsageBefore: nil)
            }
            return nil
        }

        var mappingID: UUID?
        var mappingCountBefore: Int?
        var personalUsageBefore: SpokenChoiceReceipt.UsageSnapshot?
        var builtInUsageBefore: SpokenChoiceReceipt.TermUsageSnapshot?
        var recentID: UUID?
        var personalPhraseID: UUID?
        var personalPhraseUsageBefore: SpokenChoiceReceipt.PhraseSnapshot?

        do {
            if let previous { try undo(previous, in: context) }

            if shouldLearn {
                let personalTerm = try context.fetch(FetchDescriptor<PersonalTerm>()).first(where: { $0.id == term.id })
                if let personal = personalTerm {
                    personalUsageBefore = .init(usageCount: personal.usageCount,
                        confirmationCount: personal.confirmationCount, lastUsedAt: personal.lastUsedAt)
                    personal.usageCount += 1
                    personal.confirmationCount += 1
                    personal.lastUsedAt = .now
                } else if !term.isPersonal {
                    let usages = try context.fetch(FetchDescriptor<TermUsage>())
                    if let usage = usages.first(where: { $0.termID == term.id }) {
                        builtInUsageBefore = .init(usageCount: usage.usageCount, lastUsedAt: usage.lastUsedAt)
                        usage.usageCount += 1
                        usage.lastUsedAt = .now
                    } else {
                        context.insert(TermUsage(termID: term.id, usageCount: 1, lastUsedAt: .now))
                    }
                }
                if !fragment.isEmpty {
                    let mappings = try context.fetch(FetchDescriptor<ConfirmedMapping>())
                    if let mapping = mappings.first(where: {
                        $0.normalizedSpeechFragment == fragment && $0.confirmedTermID == term.id && $0.contextID == contextID
                    }) {
                        mappingID = mapping.id
                        mappingCountBefore = mapping.confirmationCount
                        mapping.confirmationCount += 1
                    } else {
                        let mapping = ConfirmedMapping(normalizedSpeechFragment: fragment,
                            confirmedTermID: term.id, contextID: contextID)
                        context.insert(mapping)
                        mappingID = mapping.id
                    }
                }
            }

            if let phraseToUpdate {
                personalPhraseID = phraseToUpdate.id
                personalPhraseUsageBefore = .init(usageCount: phraseToUpdate.usageCount,
                    lastUsedAt: phraseToUpdate.lastUsedAt)
                phraseToUpdate.usageCount += 1
                phraseToUpdate.lastUsedAt = .now
            }

            if shouldSaveHistory {
                let recent = RecentPhrase(spokenText: cleanPhrase, termID: term.id, contextID: contextID)
                context.insert(recent)
                recentID = recent.id
            } else if let cachedHistoryID {
                recentID = cachedHistoryID
            }

            try context.save()
            if shouldLearn { learned.insert(learningKey) }
            if shouldSaveHistory { savedPhrases.insert(historyKey) }
            let receipt = SpokenChoiceReceipt(normalizedFragment: fragment, termID: term.id,
                contextID: contextID, phrase: cleanPhrase, didLearn: shouldLearn,
                mappingID: mappingID, mappingCountBefore: mappingCountBefore,
                personalUsageBefore: personalUsageBefore, builtInUsageBefore: builtInUsageBefore,
                didSaveHistory: shouldSaveHistory,
                historyID: recentID, personalPhraseID: personalPhraseID,
                personalPhraseUsageBefore: personalPhraseUsageBefore)
            if shouldLearn { sessionReceipts[learningKey] = receipt }
            if shouldSaveHistory, let recentID { historyReceipts[historyKey] = recentID }
            if let personalPhraseID { personalPhraseReceipts[personalPhraseID] = receipt }
            return receipt
        } catch {
            context.rollback()
            throw error
        }
    }

    private func undo(_ receipt: SpokenChoiceReceipt, in context: ModelContext) throws {
        if receipt.didLearn {
            if let mappingID = receipt.mappingID,
               let mapping = try context.fetch(FetchDescriptor<ConfirmedMapping>()).first(where: { $0.id == mappingID }) {
                if let count = receipt.mappingCountBefore { mapping.confirmationCount = count }
                else { context.delete(mapping) }
            }
            if let snapshot = receipt.personalUsageBefore,
               let personal = try context.fetch(FetchDescriptor<PersonalTerm>()).first(where: { $0.id == receipt.termID }) {
                personal.usageCount = snapshot.usageCount
                personal.confirmationCount = snapshot.confirmationCount
                personal.lastUsedAt = snapshot.lastUsedAt
            }
            if let usage = try context.fetch(FetchDescriptor<TermUsage>()).first(where: { $0.termID == receipt.termID }) {
                if let snapshot = receipt.builtInUsageBefore {
                    usage.usageCount = snapshot.usageCount
                    usage.lastUsedAt = snapshot.lastUsedAt
                } else {
                    context.delete(usage)
                }
            }
        }
        if let historyID = receipt.historyID, receipt.didSaveHistory,
           let recent = try context.fetch(FetchDescriptor<RecentPhrase>()).first(where: { $0.id == historyID }) {
            context.delete(recent)
        }
        if let personalPhraseID = receipt.personalPhraseID,
           let snapshot = receipt.personalPhraseUsageBefore,
           let personalPhrase = try context.fetch(FetchDescriptor<PersonalPhrase>()).first(where: { $0.id == personalPhraseID }) {
            personalPhrase.usageCount = snapshot.usageCount
            personalPhrase.lastUsedAt = snapshot.lastUsedAt
        }

        learned.remove(LearningKey(fragment: receipt.normalizedFragment, termID: receipt.termID, contextID: receipt.contextID))
        savedPhrases.remove(HistoryKey(phrase: receipt.phrase, termID: receipt.termID, contextID: receipt.contextID))
        sessionReceipts = sessionReceipts.filter { $0.value != receipt }
        historyReceipts = historyReceipts.filter { $0.value != receipt.historyID }
        personalPhraseReceipts = personalPhraseReceipts.filter { $0.value != receipt }
    }

    /// Records a user-authored message without creating a vocabulary learning
    /// event. The message is saved only when recent phrase history is enabled.
    public func recordMessage(_ phrase: String, contextID: String? = nil,
                              saveHistory: Bool, in context: ModelContext) throws {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard saveHistory, !cleanPhrase.isEmpty else { return }
        let key = HistoryKey(phrase: cleanPhrase, termID: nil, contextID: contextID)
        guard !savedPhrases.contains(key) else { return }
        do {
            let recent = RecentPhrase(spokenText: cleanPhrase, termID: nil, contextID: contextID)
            context.insert(recent)
            try context.save()
            savedPhrases.insert(key)
            historyReceipts[key] = recent.id
        } catch {
            context.rollback()
            throw error
        }
    }
}
