import XCTest
@testable import SayAgainCore

final class RegressionTests: XCTestCase {
    func testEmptyPhotoResultPreservesEarlierClueAndSuccessfulPhotoReplacesIt() {
        var clues = VisualClues()
        clues.applyPhoto(["glass", "glass"])
        clues.applyPhoto([])
        clues.applyPhoto(["  "])
        XCTAssertEqual(clues.photo, ["glass"])
        XCTAssertEqual(clues.combined, ["glass"])
        clues.applyPhoto(["cup", "glass"])
        XCTAssertEqual(clues.photo, ["cup", "glass"])
    }
    func testPersonCanRemovePhotoClueAfterReview() {
        var clues = VisualClues()
        clues.applyPhoto(["glass"])
        clues.removePhoto()
        XCTAssertTrue(clues.combined.isEmpty)
    }
    func testRemovingVocabularyUnlinksSharedPhraseInsteadOfDeletingIt() {
        let first = UUID()
        let second = UUID()
        let phrase = PersonalPhrase(spokenText: "Please call them.", relatedTermIDs: [first, second])
        XCTAssertFalse(phrase.unlink(termID: first))
        XCTAssertEqual(phrase.relatedTermIDs, [second])
        XCTAssertTrue(phrase.unlink(termID: second))
        XCTAssertTrue(phrase.relatedTermIDs.isEmpty)
    }
    func testPlantVisualCluesRetrieveConcreteVocabulary() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(visualLabels: ["potted plant"], contextID: "home"))
        XCTAssertEqual(result.first?.displayLabel, "Plant")
    }

    func testTranscriptRevisionsDoNotDuplicateWords() {
        var accumulator = SpeechTranscriptAccumulator()
        accumulator.update("wa", start: 0, isFinal: false)
        accumulator.update("water", start: 0, isFinal: true)
        accumulator.update("wa", start: 0, isFinal: false)
        accumulator.update("please", start: 1, isFinal: true)
        XCTAssertEqual(accumulator.text, "water please")
    }
    func testEmptyVolatileResultRevokesOnlyThatSegment() {
        var accumulator = SpeechTranscriptAccumulator()
        accumulator.update("water", start: 0, isFinal: true)
        accumulator.update("walk", start: 1, isFinal: false)
        accumulator.update("", start: 1, isFinal: false)
        accumulator.update("bad timestamp", start: .nan, isFinal: true)
        XCTAssertEqual(accumulator.text, "water")
    }
    func testLiteralLabelIsNotSpokenAsAnInstruction() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        XCTAssertEqual(PhraseLibrary.spokenText(for: "Just say “Water.”", term: water), "Water")
        XCTAssertEqual(PhraseLibrary.spokenText(for: "I want water.", term: water), "I want water.")
    }
    func testPersonalNamesRetainSpellingAndCase() {
        let name = VocabularyTerm(id: UUID(), canonicalText: "Dr. McDonald", displayText: "Dr. McDonald", category: .people)
        XCTAssertTrue(PhraseLibrary.phrases(for: name).contains("Please call Dr. McDonald."))
        XCTAssertFalse(PhraseLibrary.phrases(for: name).contains("More dr. mcdonald, please."))
    }
    func testUnknownMedicalTermOffersOnlyLiteralMeaning() {
        let term = VocabularyTerm(id: UUID(), canonicalText: "Insulin", displayText: "Insulin", category: .medicalBody)
        XCTAssertEqual(PhraseLibrary.phrases(for: term), ["Just say “Insulin.”"])
    }
    func testOtherPainLocationProducesGrammaticalPhrase() {
        XCTAssertEqual(PhraseLibrary.painPhrase(region: "Other", intensity: "Severe"), "I have severe pain in another part of my body.")
    }
    func testUnmatchedSpecificClueIsNotPaddedWithContextGuesses() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms, input: RankingInput(speech: "zxqvv", contextID: "home"))
        XCTAssertTrue(result.isEmpty)
    }
    func testNormalizationPreservesNegationAndApostrophes() {
        XCTAssertEqual(TextNormalizer.normalize("  DON’T   agree! "), "don't agree")
    }
    func testRerankingRejectsInventedDuplicateEmptyAndExcessIDs() {
        let valid = (0..<8).map { _ in UUID() }
        XCTAssertNil(CandidateOrderValidator.orderedIDs([UUID()], shortlist: valid))
        XCTAssertNil(CandidateOrderValidator.orderedIDs([valid[0],valid[0]], shortlist: valid))
        XCTAssertNil(CandidateOrderValidator.orderedIDs([], shortlist: valid))
        XCTAssertNil(CandidateOrderValidator.orderedIDs(Array(valid.prefix(5)), shortlist: valid))
        XCTAssertEqual(CandidateOrderValidator.orderedIDs([valid[3]], shortlist: valid), [valid[3]] + valid.filter { $0 != valid[3] })
    }
    func testOneCharacterClueDoesNotPreferIncidentalSubstring() {
        let prefix = VocabularyTerm(id: UUID(), canonicalText: "Water", displayText: "Water", category: .custom)
        let incidental = VocabularyTerm(id: UUID(), canonicalText: "Shower", displayText: "Shower", category: .custom)
        let result = DeterministicCandidateEngine().rank(terms: [incidental, prefix], input: RankingInput(speech: "w"))
        XCTAssertEqual(result.map(\.id), [prefix.id])
    }
    func testMappingSelectionDoesNotDependOnFetchOrder() throws {
        let coffee = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Coffee" })
        let general = MappingEvidence(normalizedFragment: "co", termID: coffee.id, contextID: nil, confirmationCount: 1)
        let food = MappingEvidence(normalizedFragment: "co", termID: coffee.id, contextID: "food", confirmationCount: 3)
        let engine = DeterministicCandidateEngine()
        let forward = engine.rank(terms: [coffee], input: RankingInput(speech: "co", contextID: "food",
            mappings: [general, food], learningEnabled: true)).first
        let reversed = engine.rank(terms: [coffee], input: RankingInput(speech: "co", contextID: "food",
            mappings: [food, general], learningEnabled: true)).first
        let generalOnly = engine.rank(terms: [coffee], input: RankingInput(speech: "co", contextID: "food",
            mappings: [general], learningEnabled: true)).first
        XCTAssertEqual(forward?.deterministicScore, reversed?.deterministicScore)
        XCTAssertGreaterThan(forward?.deterministicScore ?? 0, generalOnly?.deterministicScore ?? 0)
    }
    func testEverydayObjectCluesProduceConcreteChoices() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(typed: "key", contextID: "home"))
        XCTAssertEqual(result.first?.displayLabel, "Key")
        let photo = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(visualLabels: ["cup"], contextID: "food"))
        XCTAssertTrue(photo.contains { $0.displayLabel == "Cup" })
        XCTAssertTrue(photo.contains { $0.displayLabel == "Water" })
    }
    func testSeedIDsAreUniqueAndRepeatable() {
        XCTAssertEqual(Set(SeedVocabulary.terms.map(\.id)).count, SeedVocabulary.terms.count)
        XCTAssertEqual(SeedVocabulary.terms.map(\.id), SeedVocabulary.terms.map(\.id))
    }
}
