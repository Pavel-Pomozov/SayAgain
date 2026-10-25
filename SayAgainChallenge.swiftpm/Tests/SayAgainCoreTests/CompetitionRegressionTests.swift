import XCTest
import SwiftData
@testable import SayAgainCore

final class CompetitionRegressionTests: XCTestCase {
    func testDemoAmbiguityClueConfirmationAndLiteralOutput() throws {
        var demo = CommunicationDemo()
        demo.begin()
        XCTAssertEqual(demo.candidates.map(\.displayLabel), ["Want", "Wash", "Walk", "Water"])
        demo.addVisualClue()
        XCTAssertEqual(demo.candidates.map(\.displayLabel), ["Water", "Want", "Wash", "Walk"])
        let water = try XCTUnwrap(demo.candidates.first)
        demo.select(water.id)
        XCTAssertEqual(demo.step, .phrases)
        demo.selectPhrase("Invented phrase")
        XCTAssertEqual(demo.step, .phrases)
        demo.selectPhrase("Just say “Water.”")
        XCTAssertEqual(demo.phrase, "Water")
        XCTAssertEqual(demo.step, .speak)
        demo.finish()
        XCTAssertEqual(demo.step, .conclusion)
    }

    func testDemoBackAndRestartPreserveOnlyAppropriateClues() throws {
        var demo = CommunicationDemo()
        demo.begin()
        demo.addVisualClue()
        demo.select(try XCTUnwrap(demo.candidates.first).id)
        demo.selectPhrase("I want water.")
        demo.back()
        XCTAssertEqual(demo.step, .phrases)
        demo.back()
        XCTAssertEqual(demo.step, .suggestions)
        XCTAssertTrue(demo.hasVisualClue)
        demo.back()
        XCTAssertFalse(demo.hasVisualClue)
        XCTAssertEqual(demo.step, .suggestions)
        demo.restart()
        XCTAssertEqual(demo.step, .introduction)
        XCTAssertNil(demo.selectedTerm)
        XCTAssertEqual(demo.phrase, "")
    }

    func testSarahDemoUsesActualSelectedTermsPhrases() throws {
        var demo = CommunicationDemo()
        demo.begin(.personalWord)
        XCTAssertEqual(demo.candidates.first?.displayLabel, "Sarah")
        demo.select(try XCTUnwrap(demo.terms.first { $0.canonicalText == "Water" }).id)
        XCTAssertTrue(demo.phrases.contains("I want water."))
        XCTAssertFalse(demo.phrases.contains("Please call Water."))
        demo.selectPhrase("I want water.")
        XCTAssertEqual(demo.phrase, "I want water.")
    }

    func testModelOrderNeedsExplicitApplyAndRejectsUnknownIDs() {
        let ids = (0..<8).map { _ in UUID() }
        var order = SuggestionOrder()
        order.reset(ids)
        order.propose([ids[3], ids[0]])
        XCTAssertEqual(order.displayed, ids)
        XCTAssertEqual(order.pending?.prefix(2), [ids[3], ids[0]])
        order.apply()
        XCTAssertEqual(Array(order.displayed.prefix(2)), [ids[3], ids[0]])
        XCTAssertNil(order.pending)
        order.reset(ids)
        order.propose([UUID()])
        XCTAssertNil(order.pending)
        order.propose([ids[0], ids[0]])
        XCTAssertNil(order.pending)
        order.propose(Array(ids.prefix(5)))
        XCTAssertNil(order.pending)
        order.propose([ids[3]])
        order.reset(ids)
        XCTAssertNil(order.pending)
        XCTAssertEqual(order.displayed, ids)
    }

    @MainActor private func container() throws -> ModelContainer {
        let schema = Schema([PersonalTerm.self, PersonalPhrase.self, ConfirmedMapping.self, RecentPhrase.self, TermUsage.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @MainActor func testOnlyFinalSpokenChoiceIsLearnedAndReplayIsDeduplicated() throws {
        let container = try container()
        let context = container.mainContext
        let recorder = ConfirmedChoiceRecorder()
        let coffee = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Coffee" })
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)
        for _ in 0..<3 {
            try recorder.record(term: coffee, speech: " CO... ", phrase: "I want coffee.", contextID: "food",
                learn: true, saveHistory: true, in: context)
        }
        let mappings = try context.fetch(FetchDescriptor<ConfirmedMapping>())
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.confirmedTermID, coffee.id)
        XCTAssertEqual(mappings.first?.normalizedSpeechFragment, "co")
        XCTAssertEqual(mappings.first?.confirmationCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentPhrase>()).count, 1)
        try ConfirmedChoiceRecorder().record(term: coffee, speech: "co", phrase: "Coffee", contextID: "food",
            learn: true, saveHistory: false, in: context)
        XCTAssertEqual(mappings.first?.confirmationCount, 2)
    }

    @MainActor func testLearningAndHistoryPreferencesAreIndependent() throws {
        let container = try container()
        let context = container.mainContext
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let recorder = ConfirmedChoiceRecorder()
        try recorder.record(term: water, speech: "wa", phrase: "Water", contextID: nil,
            learn: false, saveHistory: false, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RecentPhrase>()).isEmpty)
        try recorder.record(term: water, speech: "wa", phrase: "Water", contextID: nil,
            learn: false, saveHistory: true, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentPhrase>()).count, 1)
        try recorder.record(term: water, speech: "wa", phrase: "Water", contextID: nil,
            learn: true, saveHistory: false, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ConfirmedMapping>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentPhrase>()).count, 1)
    }

    @MainActor func testTypedMessageHistoryDoesNotCreateVocabularyLearning() throws {
        let container = try container()
        let context = container.mainContext
        let recorder = ConfirmedChoiceRecorder()
        try recorder.recordMessage("Please call my sister.", saveHistory: false, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RecentPhrase>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)

        try recorder.recordMessage("Please call my sister.", saveHistory: true, in: context)
        try recorder.recordMessage("Please call my sister.", saveHistory: true, in: context)
        let history = try context.fetch(FetchDescriptor<RecentPhrase>())
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.spokenText, "Please call my sister.")
        XCTAssertNil(history.first?.termID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)
    }

    @MainActor func testEmptySpeechDoesNotCreateMappingAndPersonalUseCountsOnce() throws {
        let container = try container()
        let context = container.mainContext
        let stored = PersonalTerm(canonicalText: "Sarah", category: .people)
        context.insert(stored)
        let term = VocabularyTerm(id: stored.id, canonicalText: "Sarah", displayText: "Sarah", category: .people, isPersonal: true)
        let recorder = ConfirmedChoiceRecorder()
        for _ in 0..<2 {
            try recorder.record(term: term, speech: "", phrase: "Sarah", contextID: nil,
                learn: true, saveHistory: false, in: context)
        }
        XCTAssertEqual(stored.confirmationCount, 1)
        XCTAssertEqual(stored.usageCount, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConfirmedMapping>()).isEmpty)
    }

    @MainActor func testCorrectedSpokenChoiceReplacesOnlyItsOwnLearningAndRecentEntry() throws {
        let container = try container()
        let context = container.mainContext
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let sarahRecord = PersonalTerm(canonicalText: "Sarah", category: .people)
        context.insert(sarahRecord)
        let sarah = VocabularyTerm(id: sarahRecord.id, canonicalText: "Sarah", displayText: "Sarah",
            category: .people, isPersonal: true)
        let earlierMapping = ConfirmedMapping(normalizedSpeechFragment: "wa", confirmedTermID: water.id,
            contextID: "food", confirmationCount: 3)
        context.insert(earlierMapping)
        try context.save()

        let recorder = ConfirmedChoiceRecorder()
        let firstReceipt = try XCTUnwrap(recorder.record(term: water, speech: "wa", phrase: "I want water.",
            contextID: "food", learn: true, saveHistory: true, in: context))
        XCTAssertEqual(earlierMapping.confirmationCount, 4)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentPhrase>()).map(\.spokenText), ["I want water."])

        let correctedReceipt = try XCTUnwrap(recorder.record(term: sarah, speech: "sa", phrase: "Please call Sarah.",
            contextID: "conversation", learn: true, saveHistory: true, replacing: firstReceipt, in: context))
        XCTAssertEqual(earlierMapping.confirmationCount, 3, "The earlier confirmation must remain intact")
        XCTAssertEqual(sarahRecord.usageCount, 1)
        XCTAssertEqual(sarahRecord.confirmationCount, 1)
        let mappings = try context.fetch(FetchDescriptor<ConfirmedMapping>())
        XCTAssertEqual(mappings.count, 2)
        XCTAssertTrue(mappings.contains { $0.confirmedTermID == water.id && $0.confirmationCount == 3 })
        XCTAssertTrue(mappings.contains { $0.confirmedTermID == sarah.id && $0.normalizedSpeechFragment == "sa" })
        let recent = try context.fetch(FetchDescriptor<RecentPhrase>())
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.spokenText, "Please call Sarah.")

        _ = try recorder.record(term: sarah, speech: "sa", phrase: "Please call Sarah.",
            contextID: "conversation", learn: true, saveHistory: true, replacing: correctedReceipt, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ConfirmedMapping>()).first { $0.confirmedTermID == sarah.id }?.confirmationCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentPhrase>()).count, 1)
        XCTAssertEqual(sarahRecord.usageCount, 1)
    }
}
