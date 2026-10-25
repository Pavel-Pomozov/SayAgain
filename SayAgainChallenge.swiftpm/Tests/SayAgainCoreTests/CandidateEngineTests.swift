import XCTest
@testable import SayAgainCore

final class CandidateEngineTests: XCTestCase {
    func testBreakfastClueRanksWaterFirst() {
        let engine = DeterministicCandidateEngine()
        let result = engine.rank(terms: SeedVocabulary.terms, input: RankingInput(speech: "wa", visualLabels: ["glass", "drink"], contextID: "food"), limit: 4)
        XCTAssertEqual(result.first?.displayLabel, "Water")
        XCTAssertEqual(result.map(\.displayLabel), ["Water", "Want", "Wash", "Walk"])
    }

    func testBreakfastTieOrderDoesNotDependOnIncomingTermOrder() {
        let reversed = Array(SeedVocabulary.terms.reversed())
        let result = DeterministicCandidateEngine().rank(terms: reversed,
            input: RankingInput(speech: "wa", contextID: "home"), limit: 4)
        XCTAssertEqual(result.map(\.displayLabel), ["Want", "Wash", "Walk", "Water"])
    }

    func testPreparedRankingMatchesCompatibilityRanking() throws {
        let engine = DeterministicCandidateEngine()
        let terms = SeedVocabulary.terms
        let coffee = try XCTUnwrap(terms.first { $0.canonicalText == "Coffee" })
        let mapping = MappingEvidence(normalizedFragment: "co", termID: coffee.id,
            contextID: "food", confirmationCount: 2)
        let input = RankingInput(speech: "co", visualLabels: ["cup"], contextID: "food",
            mappings: [mapping], now: Date(timeIntervalSince1970: 1_800_000_000), learningEnabled: true)

        let direct = engine.rank(terms: terms, input: input, limit: 12)
        let prepared = engine.rank(prepared: engine.prepare(terms: terms), input: input, limit: 12)

        XCTAssertEqual(prepared, direct)
    }

    func testPreparedRankingRemainsBoundedWithLargeVocabularyAndMappingSets() {
        let terms = (0..<1_000).map { index in
            VocabularyTerm(id: UUID(), canonicalText: "Word \(index)", displayText: "Word \(index)",
                category: .custom, contextIDs: ["home"], synonyms: ["word \(index)"])
        }
        let mappings = terms.map {
            MappingEvidence(normalizedFragment: "wo", termID: $0.id, contextID: nil, confirmationCount: 1)
        }
        let engine = DeterministicCandidateEngine()
        let prepared = engine.prepare(terms: terms)
        let input = RankingInput(speech: "wo", contextID: "home", mappings: mappings, learningEnabled: true)

        measure {
            XCTAssertEqual(engine.rank(prepared: prepared, input: input, limit: 12).count, 12)
        }
    }

    func testPersonalVocabularyGetsSmallTieBreakBoost() {
        let common = VocabularyTerm(id: UUID(), canonicalText: "Wave", displayText: "Wave",
            category: .custom, synonyms: ["wa"])
        let personal = VocabularyTerm(id: UUID(), canonicalText: "Wake", displayText: "Wake",
            category: .custom, synonyms: ["wa"], isPersonal: true)
        let result = DeterministicCandidateEngine().rank(terms: [common, personal],
            input: RankingInput(speech: "wa"), limit: 2)
        XCTAssertEqual(result.first?.id, personal.id)
        XCTAssertTrue(result.first?.evidence.contains(.personalVocabulary) == true)
    }

    func testVisualLabelBoostsMatchingAlias() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let other = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Coffee" })
        let result = DeterministicCandidateEngine().rank(terms: [other, water],
            input: RankingInput(visualLabels: ["glass"]), limit: 2)
        XCTAssertEqual(result.first?.id, water.id)
        XCTAssertTrue(result.first?.evidence.contains(.visualClue) == true)
    }

    func testVisualLabelCanContainTheTerm() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let coffee = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Coffee" })
        let result = DeterministicCandidateEngine().rank(terms: [coffee, water],
            input: RankingInput(visualLabels: ["bottle of water"]), limit: 2)
        XCTAssertEqual(result.first?.id, water.id)
        XCTAssertTrue(result.first?.evidence.contains(.visualClue) == true)
    }

    func testOneCharacterVisualLabelDoesNotMatchEveryWord() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let coffee = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Coffee" })
        let result = DeterministicCandidateEngine().rank(terms: [coffee, water],
            input: RankingInput(visualLabels: ["a"]), limit: 2)
        XCTAssertTrue(result.isEmpty)
    }

    func testConfirmedMappingOnlyAppliesWhenLearningIsEnabled() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        let want = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Want" })
        let mapping = MappingEvidence(normalizedFragment: "wa", termID: want.id,
            contextID: nil, confirmationCount: 3)
        let engine = DeterministicCandidateEngine()
        let learned = engine.rank(terms: [water, want], input: RankingInput(speech: "wa",
            mappings: [mapping], learningEnabled: true), limit: 2)
        let disabled = engine.rank(terms: [water, want], input: RankingInput(speech: "wa",
            mappings: [mapping], learningEnabled: false), limit: 2)
        XCTAssertEqual(learned.first?.id, want.id)
        XCTAssertTrue(learned.first?.evidence.contains(.confirmedMapping) == true)
        XCTAssertFalse(disabled.first?.evidence.contains(.confirmedMapping) == true)
    }

    func testSparseFragmentDoesNotReturnMoreThanFourWhenLimited() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(speech: "w"), limit: 4)
        XCTAssertLessThanOrEqual(result.count, 4)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
    }

    func testNoCluesAndNoContextReturnsNothing() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(), limit: 12)
        XCTAssertTrue(result.isEmpty)
    }

    func testNormalizationKeepsIncompleteFragment() {
        XCTAssertEqual(TextNormalizer.normalize("  WA...  "), "wa")
    }

    func testContextIsBoostNotFilter() {
        let result = DeterministicCandidateEngine().rank(terms: SeedVocabulary.terms,
            input: RankingInput(speech: "water", contextID: "medical"), limit: 12)
        XCTAssertTrue(result.contains { $0.displayLabel == "Water" })
    }

    func testLiteralPhraseExists() throws {
        let water = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Water" })
        XCTAssertTrue(PhraseLibrary.phrases(for: water).contains("Just say “Water.”"))
        let literal = try XCTUnwrap(PhraseLibrary.options(for: water).first { $0.displayText == "Just say “Water.”" })
        XCTAssertEqual(literal.spokenText, "Water")
    }

    func testConsentAndNegationPhrasesKeepTheirMeaning() throws {
        let agree = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Agree" })
        let doNotAgree = try XCTUnwrap(SeedVocabulary.terms.first { $0.canonicalText == "Do Not Agree" })
        XCTAssertTrue(PhraseLibrary.phrases(for: agree).contains("I agree."))
        XCTAssertTrue(PhraseLibrary.phrases(for: doNotAgree).contains("I do not agree."))
        XCTAssertFalse(PhraseLibrary.phrases(for: doNotAgree).contains("I agree."))
    }
}
