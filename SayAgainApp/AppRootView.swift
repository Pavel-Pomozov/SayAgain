import SwiftUI
import SwiftData
import SayAgainCore
import SayAgainDemo
import SayAgainAudio
import Observation

struct AppRootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-playback-layout") {
            PlaybackButtonLayoutFixture()
        } else {
            rootContent
        }
        #else
        rootContent
        #endif
    }

    private var rootContent: some View {
        Group {
            if hasCompletedOnboarding { HomeView() }
            else { NavigationStack { OnboardingView { hasCompletedOnboarding = true } } }
        }
        .tint(.blue)
    }
}

#if DEBUG
private struct PlaybackButtonLayoutFixture: View {
    @State private var state: SpeechPlaybackState = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Playback control layout check")
                        .font(.title2).accessibilityAddTraits(.isHeader)
                    Button("Set Idle") { state = .idle }
                    Button("Set Preparing") { state = .preparing }
                    Button("Set Speaking") { state = .speaking }
                    if state == .preparing { ProgressView("Starting speech…") }
                }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    SpeechPlaybackButton(state: state, idleTitle: "Replay", activeTitle: "Stop") {}
                    Button("Done") {}.buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                    Label("Microphone Off · Camera Off", systemImage: "mic.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }.buttonBorderShape(.capsule).frame(maxWidth: 600).frame(maxWidth: .infinity)
                    .padding().background(.background)
            }
            .navigationTitle("Playback Layout")
        }
    }
}
#endif

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecentPhrase.createdAt, order: .reverse) private var recent: [RecentPhrase]
    @State private var showDemo = false
    @AppStorage("saveRecentPhrases") private var saveRecentPhrases = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CommunicationFlowView()
                    } label: {
                        Label("Help Me Say It", systemImage: "waveform")
                            .font(.title3.weight(.semibold)).padding(.vertical, 14)
                    }
                    .accessibilityHint("Start a short, intentional speech session")
                    NavigationLink { QuickNeedsView() } label: { Label("Quick Needs", systemImage: "hand.raised") }
                    NavigationLink { TypedMessageFlowView() } label: { Label("Say Typed Message", systemImage: "keyboard") }
                }
                if saveRecentPhrases, !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent.prefix(3)) { item in
                            NavigationLink { SpeakView(phrase: item.spokenText, termID: item.termID, contextID: item.contextID) } label: {
                                Text(item.spokenText).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink { PersonalWordsView() } label: { Label("Personal Words", systemImage: "text.book.closed") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                    Button { showDemo = true } label: { Label("Offline Demo", systemImage: "play.rectangle") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SayAgain")
            .sheet(isPresented: $showDemo) { ChallengeDemoScreen() }
        }
    }
}

/// Lets someone compose and review their own complete message without
/// converting it into a vocabulary search or rewriting it.
struct TypedMessageFlowView: View {
    private enum Step { case edit, review, speak }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveRecentPhrases") private var saveRecent = false
    @State private var message = ""
    var storageAvailable = true
    @State private var step: Step = .edit
    @State private var recorder = ConfirmedChoiceRecorder()
    @State private var storageMessage: String?

    var body: some View {
        Group {
            switch step {
            case .edit:
                Form {
                    Section("Your message") {
                        TextEditor(text: $message)
                            .frame(minHeight: 150)
                            .accessibilityLabel("Write the message you want to say")
                            .accessibilityIdentifier("typedMessageInput")
                    }
                    Section {
                        Text("SayAgain keeps your wording as you wrote it. You can review it before it is spoken.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Say Typed Message")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Review") { step = .review }
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            case .review:
                ScrollView {
                    VStack(spacing: 20) {
                        Text("Your message").font(.title2).accessibilityAddTraits(.isHeader)
                        Text(message).font(.largeTitle).multilineTextAlignment(.center).textSelection(.enabled)
                        Text("Check the wording before you choose to speak it.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 28)
                }
                .navigationTitle("Review Message").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 12) {
                        Button("Use This Message", systemImage: "arrow.right") { step = .speak }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 48)
                        Button("Edit Message", systemImage: "pencil") { step = .edit }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                    }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding().background(.background)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            case .speak:
                SpeakView(phrase: message, termID: nil, contextID: nil,
                    onBack: { step = .review }, backTitle: "Review",
                    onSpeak: { spoken in
                        guard storageAvailable else {
                            if saveRecent { storageMessage = "The message was spoken, but local storage is unavailable, so it wasn’t saved." }
                            return
                        }
                        do { try recorder.recordMessage(spoken, saveHistory: saveRecent, in: modelContext) }
                        catch { storageMessage = "Your message was spoken, but it couldn’t be saved to Recent." }
                    })
            }
        }
        .alert("Recent message couldn’t be saved", isPresented: Binding(
            get: { storageMessage != nil }, set: { if !$0 { storageMessage = nil } })) {
            Button("OK", role: .cancel) { storageMessage = nil }
        } message: { Text(storageMessage ?? "Try again if you want to save it.") }
    }
}

struct CommunicationFlowView: View {
    private enum Step { case listening, review, suggestions, phrases, speak, pain }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("learnFromChoices") private var learningEnabled = false
    @AppStorage("saveRecentPhrases") private var saveRecent = false
    @AppStorage("defaultContextID") private var defaultContextID = "home"
    @Query private var personalTerms: [PersonalTerm]
    @Query private var mappings: [ConfirmedMapping]
    @Query private var personalPhrases: [PersonalPhrase]
    @Query private var contexts: [SavedContext]
    @Query private var termUsages: [TermUsage]
    @State private var contextID: String
    @State private var transcript = ""
    @State private var microphoneActive = false
    @State private var candidates: [CommunicationCandidate] = []
    @State private var suggestionStatus: String?
    @State private var storageMessage: String?
    @State private var selectedTerm: VocabularyTerm?
    @State private var currentStep: Step = .listening
    @State private var visualClues = VisualClues()
    private var photoLabels: [String] { visualClues.photo }
    private var visualLabels: [String] { visualClues.combined }
    @State private var cachedVocabularyTerms: [VocabularyTerm]?
    @State private var preparedVocabulary: PreparedVocabulary?
    @State private var typedClue: String?
    @State private var showCamera = false
    @State private var showTyped = false
    @State private var editingTranscript = false
    @State private var showAllWords = false
    @State private var rerankTask: Task<Void, Never>?
    @State private var reranker = CandidateReranker()
    @State private var suggestionOrder = SuggestionOrder()
    @State private var suggestionRequestID = UUID()
    @State private var rankingRequestID = UUID()
    @State private var rankingTask: Task<[CommunicationCandidate], Never>?
    @State private var isRanking = false
    @State private var choiceRecorder = ConfirmedChoiceRecorder()
    @State private var lastSpokenReceipt: SpokenChoiceReceipt?

    init() { _contextID = State(initialValue: "home") }

    private var contextChoices: [ContextChoice] {
        ContextChoice.builtIns + contexts.map { ContextChoice(id: $0.id, name: $0.name, kind: .custom) }
    }
    private var chosenContext: ContextChoice { contextChoices.first(where: { $0.id == contextID }) ?? .home }
    private var allTerms: [VocabularyTerm] {
        var usageByID: [UUID: TermUsage] = [:]
        for usage in termUsages { usageByID[usage.termID] = usage }
        let builtIn = SeedVocabulary.terms.map { term -> VocabularyTerm in
            let usage = usageByID[term.id]
            return VocabularyTerm(id: term.id, canonicalText: term.canonicalText, displayText: term.displayText,
                category: term.category, contextIDs: term.contextIDs, symbolName: term.symbolName,
                synonyms: term.synonyms, usageCount: usage?.usageCount ?? 0,
                confirmationCount: term.confirmationCount, lastUsedAt: usage?.lastUsedAt,
                isPersonal: false, rankingPriority: term.rankingPriority)
        }
        let personal = personalTerms.filter(\.enabled).map { term in
            (term, TextNormalizer.normalize(term.displayText))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map { term, _ in
            VocabularyTerm(id: term.id, canonicalText: term.canonicalText, displayText: term.displayText,
                category: term.category, contextIDs: term.contextIDs, symbolName: term.symbolName,
                synonyms: term.synonyms, usageCount: term.usageCount, confirmationCount: term.confirmationCount,
                lastUsedAt: term.lastUsedAt, isPersonal: true, relationship: term.relationship)
        }
        return builtIn + personal
    }

    var body: some View {
        Group {
            switch currentStep {
            case .listening: listening
            case .review: transcriptReview
            case .suggestions: suggestions
            case .phrases: phraseSelection
            case .speak: SpeakView(phrase: selectedPhrase, termID: selectedTerm?.id, contextID: contextID,
                onBack: { goBack(to: .phrases) }, onSpeak: { recordSpokenChoice($0) }, onDone: { dismiss() })
            case .pain: PainFlowView(onBack: { goBack(to: .suggestions) },
                onSpeak: { recordSpokenChoice($0) }, onFinish: { dismiss() })
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let storageMessage { Text(storageMessage).font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .navigationBarBackButtonHidden(currentStep != .listening)
        .sheet(isPresented: $showTyped) { typedSheet }
        .sheet(isPresented: $showCamera) {
            VisualClueSheet(onLabels: { labels in visualClues.applyPhoto(labels); currentStep = .suggestions; recomputeCandidates() },
                onTyped: { value in typedClue = value; currentStep = .suggestions; recomputeCandidates() })
        }
        .sheet(isPresented: $showAllWords) { AllWordsSheet(terms: allTerms) { choose($0) } }
        .onAppear {
            if currentStep == .listening {
                contextID = contextChoices.contains(where: { $0.id == defaultContextID }) ? defaultContextID : ContextChoice.home.id
            }
        }
        .onDisappear { rankingTask?.cancel(); rerankTask?.cancel(); reranker.cancel() }
        .onChange(of: showTyped) { _, visible in if !visible { editingTranscript = false } }
        .onChange(of: defaultContextID) { _, new in if currentStep == .listening { contextID = new } }
    }

    private var listening: some View {
        ListeningView { transcript = $0; microphoneActive = false; currentStep = .review } onCancel: {
            dismiss()
        } onMicrophoneState: { microphoneActive = $0 }
    }

    private var transcriptReview: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: transcript.isEmpty ? "mic.slash" : "text.quote")
                    .font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(transcript.isEmpty ? "I didn’t catch that." : "I heard")
                    .font(.title2).accessibilityAddTraits(.isHeader)
                if !transcript.isEmpty {
                    Text("“\(transcript)”").font(.largeTitle).multilineTextAlignment(.center).textSelection(.enabled)
                    Text("Use this clue to find possible words, or edit what was heard.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Try speaking again, type any part of the word, or use Quick Needs.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 32)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if !transcript.isEmpty {
                    Button { currentStep = .suggestions; recomputeCandidates() } label: {
                        Text("Use This").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                }
                Button { currentStep = .listening } label: {
                    Label("Try Again", systemImage: "mic").frame(maxWidth: .infinity, minHeight: 40)
                }
                Button { editingTranscript = !transcript.isEmpty; showTyped = true } label: {
                    Label(transcript.isEmpty ? "Type a Clue" : "Edit", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                if transcript.isEmpty { NavigationLink("Use Quick Needs") { QuickNeedsView() }.buttonStyle(.bordered) }
                Text("Microphone Off · Camera Off").font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding().background(.background)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private var suggestions: some View {
        List {
            Section {
                if isRanking {
                    ProgressView("Updating suggestions…").frame(maxWidth: .infinity, minHeight: 48)
                } else if candidates.isEmpty {
                    Text("No matching words yet. Add another clue or browse Something Else.").foregroundStyle(.secondary)
                }
                ForEach(candidates.prefix(4)) { candidate in
                    Button { choose(candidate) } label: {
                        HStack {
                            Label(candidate.displayLabel, systemImage: candidate.icon ?? "text.quote")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.font(.body).frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button("Something Else…") { showAllWords = true }.font(.body).frame(minHeight: 52)
            } header: { Text("Did you mean?").font(.title2) }
            if suggestionOrder.pending != nil {
                Section {
                    Button("Update Suggestions", systemImage: "arrow.clockwise") { applySuggestionOrder() }
                        .accessibilityHint("Use an updated order for the same possible words")
                } footer: { Text("Your current choices stay in place until you update them.") }
            }
            if !transcript.isEmpty {
                Section("Speech clue") {
                    Text(transcript).foregroundStyle(.secondary)
                    Button("Edit Speech Clue", systemImage: "pencil") { currentStep = .review }
                    Button("Remove Speech Clue", systemImage: "minus.circle", role: .destructive) {
                        transcript = ""; recomputeCandidates()
                    }
                }
            }
            if !photoLabels.isEmpty {
                Section("Photo clue — not saved") {
                    Text(photoLabels.joined(separator: ", ")).foregroundStyle(.secondary)
                    Button("Remove Photo Clue", systemImage: "minus.circle", role: .destructive) {
                        visualClues.removePhoto(); recomputeCandidates()
                    }
                }
            }
            if let typedClue, !typedClue.isEmpty {
                Section("Typed clue") {
                    Text(typedClue).foregroundStyle(.secondary)
                    Button("Edit Typed Clue", systemImage: "pencil") { showTyped = true }
                    Button("Remove Typed Clue", systemImage: "minus.circle", role: .destructive) {
                        self.typedClue = nil; recomputeCandidates()
                    }
                }
            }
            Section("Context") { Text(chosenContext.name).foregroundStyle(.secondary) }
            if let suggestionStatus { Text(suggestionStatus).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Suggestions").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Review", systemImage: "chevron.backward") { goBack(to: .review) }.accessibilityIdentifier("backToReview") }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(contextChoices) { option in
                        Button { contextID = option.id; recomputeCandidates() } label: {
                            if option.id == contextID { Label(option.name, systemImage: "checkmark") }
                            else { Text(option.name) }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Communication context: \(chosenContext.name)")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { showCamera = true } label: { Image(systemName: "camera") }.buttonStyle(.bordered).accessibilityLabel("Add a visual clue")
                Button { showTyped = true } label: { Image(systemName: "keyboard") }.buttonStyle(.bordered).accessibilityLabel("Type a clue")
            }
        }
    }

    private var phraseSelection: some View {
        List {
            if let selectedTerm {
                ForEach(phraseOptions(for: selectedTerm)) { option in
                    Button(option.displayText) {
                        selectedPhrase = option.spokenText
                        currentStep = .speak
                    }.frame(minHeight: 50)
                }
            }
        }
        .navigationTitle(selectedTerm?.displayText ?? "Phrases")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Suggestions", systemImage: "chevron.backward") { goBack(to: .suggestions) }.accessibilityIdentifier("backToSuggestions") }
            ToolbarItem(placement: .topBarTrailing) { privacyLabel("Microphone Off · Camera Off") }
        }
    }

    @State private var selectedPhrase = ""
    @ViewBuilder private var typedSheet: some View {
        TypedClueSheet(initial: editingTranscript ? transcript : (typedClue ?? "")) { value in
            let wasEditingTranscript = editingTranscript
            if wasEditingTranscript { transcript = value }
            else { typedClue = value }
            editingTranscript = false
            currentStep = wasEditingTranscript ? .review : .suggestions
            if !wasEditingTranscript { recomputeCandidates() }
        }
    }

    private func goBack(to step: Step) {
        currentStep = step
    }

    private func privacyLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(text)
    }

    private func choose(_ candidate: CommunicationCandidate) {
        guard let term = allTerms.first(where: { $0.id == candidate.id }) else { return }
        choose(term)
    }

    private func choose(_ term: VocabularyTerm) {
        rerankTask?.cancel()
        reranker.cancel()
        selectedTerm = term
        let painTermID = SeedVocabulary.terms.first { $0.canonicalText == "Pain" }?.id
        currentStep = term.id == painTermID ? .pain : .phrases
    }

    private func recordSpokenChoice(_ phrase: String) {
        guard let selectedTerm else { return }
        do {
            lastSpokenReceipt = try choiceRecorder.record(term: selectedTerm, speech: transcript, phrase: phrase,
                contextID: contextID, learn: learningEnabled, saveHistory: saveRecent,
                replacing: lastSpokenReceipt, in: modelContext)
        } catch { storageMessage = "Your phrase can still be spoken, but this choice couldn’t be saved." }
    }

    private func phraseOptions(for term: VocabularyTerm) -> [PhraseOption] {
        let userAdded = personalPhrases.filter { $0.relatedTermIDs.contains(term.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { PhraseOption(displayText: $0.spokenText, spokenText: $0.spokenText, source: .personal) }
        var seen = Set<String>()
        return (userAdded + PhraseLibrary.options(for: term)).filter { seen.insert($0.displayText).inserted }
    }

    private func recomputeCandidates() {
        rerankTask?.cancel()
        reranker.cancel()
        rankingTask?.cancel()
        let mappingEvidence = mappings.map { MappingEvidence(normalizedFragment: $0.normalizedSpeechFragment,
            termID: $0.confirmedTermID, contextID: $0.contextID, confirmationCount: $0.confirmationCount) }
        let terms = allTerms
        let engine = DeterministicCandidateEngine()
        if cachedVocabularyTerms != terms {
            cachedVocabularyTerms = terms
            preparedVocabulary = engine.prepare(terms: terms)
        }
        guard let preparedVocabulary else { return }
        let input = RankingInput(speech: transcript, typed: typedClue, visualLabels: visualLabels,
            contextID: contextID, mappings: mappingEvidence, learningEnabled: learningEnabled)
        let requestID = UUID()
        rankingRequestID = requestID
        isRanking = true
        candidates = []
        suggestionOrder.reset([])
        suggestionStatus = nil
        let worker = Task.detached(priority: .userInitiated) {
            engine.rank(prepared: preparedVocabulary, input: input)
        }
        rankingTask = worker
        Task { @MainActor in
            let deterministic = await worker.value
            guard rankingRequestID == requestID else { return }
            rankingTask = nil
            isRanking = false
            candidates = deterministic
            suggestionOrder.reset(deterministic.map(\.id))
            startReranking(for: deterministic)
        }
    }

    private func startReranking(for deterministic: [CommunicationCandidate]) {
        rerankTask?.cancel()
        reranker.cancel()
        suggestionRequestID = UUID()
        let requestID = suggestionRequestID
        let fragment = [transcript, typedClue ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let context = chosenContext.name
        let labels = visualLabels
        rerankTask = Task {
            guard !Task.isCancelled, suggestionRequestID == requestID else { return }
            guard let order = await reranker.rerank(fragment: fragment, context: context,
                labels: labels, candidates: deterministic) else {
                guard !Task.isCancelled, suggestionRequestID == requestID else { return }
                suggestionStatus = "Using standard suggestions"
                return
            }
            guard !Task.isCancelled, suggestionRequestID == requestID else { return }
            suggestionOrder.propose(order)
        }
    }

    private func applySuggestionOrder() {
        suggestionOrder.apply()
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        candidates = suggestionOrder.displayed.compactMap { byID[$0] }
    }

}

struct TypedClueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var initial: String
    @State private var text = ""
    let onUse: (String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("Type any part you can.", text: $text, axis: .vertical)
                    .lineLimit(1...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Type any part you can.").accessibilityIdentifier("communicationClueInput")
                if !text.isEmpty { Button("Clear Text", systemImage: "xmark.circle") { text = "" } }
            }
                .navigationTitle("Type a Clue")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Use Clue") { onUse(text); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.onAppear { text = initial }
        }.presentationDetents([.medium, .large])
    }
}

struct AllWordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var savedTerms: [PersonalTerm]
    let terms: [VocabularyTerm]
    let onSelect: (VocabularyTerm) -> Void
    @State private var search = ""
    @State private var showingAdd = false
    var allWords: [VocabularyTerm] {
        let saved = savedTerms.filter(\.enabled).map { VocabularyTerm(id: $0.id, canonicalText: $0.canonicalText, displayText: $0.displayText,
            category: $0.category, contextIDs: $0.contextIDs, symbolName: $0.symbolName, synonyms: $0.synonyms,
            usageCount: $0.usageCount, confirmationCount: $0.confirmationCount, lastUsedAt: $0.lastUsedAt, isPersonal: true) }
        var seen = Set<UUID>()
        return (terms + saved).filter { seen.insert($0.id).inserted }
    }
    var filtered: [VocabularyTerm] { allWords.filter { search.isEmpty || $0.displayText.localizedCaseInsensitiveContains(search) || $0.synonyms.contains { $0.localizedCaseInsensitiveContains(search) } }.sorted { $0.displayText < $1.displayText } }
    var body: some View {
        NavigationStack {
            List(filtered) { term in Button(term.displayText) { onSelect(term); dismiss() } }
                .searchable(text: $search, prompt: "Search words")
                .navigationTitle("Something Else")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("Add Word", systemImage: "plus") { showingAdd = true } }
                }
                .sheet(isPresented: $showingAdd) { TermEditorSheet(term: nil) }
        }
    }
}

struct QuickNeedsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @AppStorage("saveRecentPhrases") private var saveRecent = false
    @State private var recorder = ConfirmedChoiceRecorder()
    @State private var storageMessage: String?
    var storageAvailable = true
    private let labels = ["YES", "NO", "WATER", "BATHROOM", "PAIN", "HELP"]
    @State private var route: QuickPhraseRoute?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(labels, id: \.self) { label in
                    Button {
                        recorder = ConfirmedChoiceRecorder()
                        route = label == "PAIN"
                            ? QuickPhraseRoute(phrase: nil, isPainFlow: true)
                            : QuickPhraseRoute(phrase: PhraseLibrary.quickNeedPhrase(label), canonicalText: label)
                    } label: {
                        Text(label).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 96)
                    }.buttonStyle(.bordered).accessibilityLabel(label)
                }
            }
        }
        .padding().navigationTitle("Quick Needs").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Label("Microphone Off · Camera Off", systemImage: "mic.slash")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .navigationDestination(item: $route) { route in
            if route.isPainFlow {
                PainFlowView(onSpeak: { record($0, word: "Pain") }, onFinish: { self.route = nil })
            } else {
                SpeakView(phrase: route.phrase ?? "", termID: nil, contextID: nil,
                    onSpeak: { record($0, word: route.canonicalText ?? "") }, onDone: { self.route = nil })
            }
        }
        .alert("Recent phrase couldn’t be saved", isPresented: Binding(get: { storageMessage != nil }, set: { if !$0 { storageMessage = nil } })) {
            Button("OK", role: .cancel) { storageMessage = nil }
        } message: { Text("Your phrase can still be spoken. Try again if you want to save it.") }
    }
    private func record(_ phrase: String, word: String) {
        guard storageAvailable else {
            if saveRecent { storageMessage = "The phrase was spoken, but local storage is unavailable, so it wasn’t saved." }
            return
        }
        guard let term = SeedVocabulary.terms.first(where: { $0.canonicalText.localizedCaseInsensitiveCompare(word) == .orderedSame }) else { return }
        do { try recorder.record(term: term, speech: "", phrase: phrase, contextID: word == "Pain" ? "medical" : nil,
            learn: false, saveHistory: saveRecent, in: modelContext) }
        catch { storageMessage = "save_failed" }
    }
}

private struct QuickPhraseRoute: Hashable, Identifiable {
    var phrase: String?
    var canonicalText: String? = nil
    var isPainFlow = false
    var id: String { isPainFlow ? "pain" : (phrase ?? "quick") }
}

struct PainFlowView: View {
    @Environment(\.dismiss) private var dismiss
    var onBack: (() -> Void)? = nil
    var onSpeak: ((String) -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    @State private var region: String?
    @State private var intensity: String?
    @State private var emergency = false
    @State private var addingDetails = false
    @State private var phrase = ""
    @State private var showSpeak = false
    private let regions = ["Head", "Chest", "Stomach", "Back", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Other"]
    private let levels = ["Mild", "Moderate", "Severe"]
    var body: some View {
        Form {
            if !addingDetails {
                Section("Pain") {
                    Text("You can say that you are in pain without adding details.")
                        .foregroundStyle(.secondary)
                    Button("Just say ‘I am in pain.’", systemImage: "speaker.wave.2") {
                        phrase = "I am in pain."
                        showSpeak = true
                    }
                    Button("Add details", systemImage: "plus") { addingDetails = true }
                }
            } else if region == nil {
                Section("Where does it hurt?") {
                    ForEach(regions, id: \.self) { item in Button(item) { region = item } }
                }
                Button("Just say ‘I am in pain.’") { phrase = "I am in pain."; showSpeak = true }
            } else if intensity == nil {
                Section("Where does it hurt?") { Text(region ?? "") }
                Section("How strong is the pain?") {
                    ForEach(levels, id: \.self) { item in Button(item) { intensity = item } }
                }
                Button("Change body area") { region = nil }
            } else if let region, let intensity {
                Section("Pain") {
                    Text(reviewedPainPhrase(region: region, intensity: intensity))
                    Button("Change body area") { self.region = nil; self.intensity = nil }
                    Button("Change intensity") { self.intensity = nil }
                }
                Section {
                    Toggle("This is an emergency", isOn: $emergency)
                    if emergency || region == "Chest" {
                        Text("If this is an emergency, contact your local emergency services.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Review Message") { phrase = reviewedPainPhrase(region: region, intensity: intensity); showSpeak = true }
                }
            }
        }
        .navigationTitle("Pain").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onBack {
                    Button("Suggestions", systemImage: "chevron.backward") { onBack() }
                } else { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Label("Microphone Off · Camera Off", systemImage: "mic.slash").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationDestination(isPresented: $showSpeak) {
            SpeakView(phrase: phrase, termID: nil, contextID: "medical", onSpeak: onSpeak,
                onDone: { if let onFinish { onFinish() } else { dismiss() } })
        }
    }

    private func reviewedPainPhrase(region: String, intensity: String) -> String {
        let detail = PhraseLibrary.painPhrase(region: region, intensity: intensity)
        return emergency ? "This is an emergency. \(detail)" : detail
    }
}

struct SpeakView: View {
    @Environment(\.dismiss) private var dismiss
    let phrase: String
    let termID: UUID?
    let contextID: String?
    var onBack: (() -> Void)? = nil
    var backTitle = "Phrases"
    var onSpeak: ((String) -> Void)? = nil
    var onDone: (() -> Void)? = nil
    @State private var speaker = SpeechOutputDriver()
    @State private var hasSpoken = false
    @AppStorage("preferredVoiceID") private var preferredVoiceID = ""
    @AppStorage("speechRate") private var speechRate = 0.50
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(phrase).font(.largeTitle).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if speaker.playbackState == .preparing {
                    ProgressView("Starting speech…").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = speaker.playbackError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 32)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                SpeechPlaybackButton(state: speaker.playbackState,
                    idleTitle: hasSpoken ? "Replay" : "Speak", activeTitle: "Stop") {
                    if speaker.playbackState.isActive { speaker.stop() }
                    else {
                        speaker.voiceIdentifier = preferredVoiceID
                        speaker.rate = Float(speechRate)
                        speaker.speak(phrase)
                    }
                }
                Button { speaker.stop(); finish() } label: { Text("Done").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered)
                Label("Microphone Off · Camera Off", systemImage: "mic.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }.buttonBorderShape(.capsule).frame(maxWidth: 600).frame(maxWidth: .infinity).padding().background(.background)
        }
        .navigationTitle("Your Phrase").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(backTitle, systemImage: "chevron.backward") { speaker.stop(); onBack() }
                        .accessibilityIdentifier("backToPhrases")
                }
            }
        }
        .onChange(of: speaker.playbackStartCount) { _, count in
            guard count > 0 else { return }
            hasSpoken = true
            onSpeak?(phrase)
        }
        .onDisappear { speaker.stop() }
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }
}

struct ChallengeDemoScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredVoiceID") private var preferredVoiceID = ""
    @AppStorage("speechRate") private var speechRate = 0.50
    @State private var speaker = SpeechOutputDriver()
    var body: some View {
        SayAgainDemoView(speaker: speaker, onClose: { dismiss() })
            .onAppear { speaker.voiceIdentifier = preferredVoiceID; speaker.rate = Float(speechRate) }
    }
}
