import SwiftUI
import SwiftData
import AVFoundation
import UIKit
import OSLog
import SayAgainCore
import SayAgainAudio

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("learnFromChoices") private var learn = false
    @AppStorage("saveRecentPhrases") private var saveRecent = false
    @AppStorage("defaultContextID") private var defaultContext = "home"
    @AppStorage("speechRate") private var speechRate = 0.50
    @AppStorage("preferredVoiceID") private var preferredVoiceID = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Query private var terms: [PersonalTerm]
    @Query private var mappings: [ConfirmedMapping]
    @Query private var termUsages: [TermUsage]
    @Query private var recent: [RecentPhrase]
    @Query private var contexts: [SavedContext]
    @Query private var phrases: [PersonalPhrase]
    @State private var preview = SpeechOutputDriver()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var hasLoadedVoiceCatalog = false
    @State private var newContext = ""
    @State private var confirmReset = false
    @State private var confirmClearHistory = false
    @State private var confirmDeleteAll = false
    @State private var storageError = false
    @AppStorage("microphoneConsentGranted") private var microphoneConsentGranted = false

    var body: some View {
        Form {
            Section("Communication") {
                Picker("Preferred voice", selection: $preferredVoiceID) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { voice in Text(voice.name).tag(voice.identifier) }
                }
                VStack(alignment: .leading) {
                    Text("Speech rate")
                    Slider(value: $speechRate, in: 0.35...0.60)
                        .accessibilityLabel("Speech rate")
                }
                SpeechPlaybackButton(state: preview.playbackState, idleTitle: "Preview Voice",
                                     activeTitle: "Stop Preview", font: .body) {
                    if preview.playbackState.isActive { preview.stop() }
                    else { preview.voiceIdentifier = preferredVoiceID; preview.rate = Float(speechRate); preview.speak("Hello. This is SayAgain.") }
                }
                if let error = preview.playbackError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Picker("Default context", selection: $defaultContext) {
                    ForEach(ContextChoice.builtIns) { Text($0.name).tag($0.id) }
                    ForEach(contexts) { Text($0.name).tag($0.id) }
                }
                HStack {
                    TextField("New context", text: $newContext)
                    Button("Add") { addContext() }.buttonStyle(.bordered).disabled(newContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(contexts) { context in
                    HStack { Text(context.name); Spacer(); Button("Delete", systemImage: "trash", role: .destructive) { deleteContext(context) }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Delete \(context.name) context") }
                }
            }
            Section("Personalization") {
                Toggle("Learn From My Choices", isOn: $learn).accessibilityIdentifier("learnFromChoices")
                Text("When on, SayAgain stores a normalized version of the short speech fragment and the word you confirmed after playback begins. If you correct a spoken choice in the same session, the new choice replaces that session’s learning entry. Replay does not add another confirmation. Raw audio is never stored.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Reset Learned Patterns", role: .destructive) { confirmReset = true }
            }
            Section("Privacy") {
                Text("After you allow access, iOS remembers microphone and camera permission until you change it in Settings. SayAgain listens only while Help Me Say It is open and opens the camera only after you choose Open Camera.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open System Settings", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }.accessibilityHint("Change microphone and camera permissions for SayAgain")
                Toggle("Save recent phrases", isOn: $saveRecent).accessibilityLabel("Save recent phrases").accessibilityIdentifier("saveRecentPhrases")
                Text("When on, SayAgain saves phrases you choose to speak, including medical and basic-needs phrases. You can clear them here. App data may be included in your device’s encrypted backup.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Clear Recent Phrases", role: .destructive) { confirmClearHistory = true }
                Button("Delete All SayAgain Data", role: .destructive) { confirmDeleteAll = true }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                Section("Test storage") {
                    Text("Learned choices: \(mappings.reduce(0) { $0 + $1.confirmationCount })").accessibilityIdentifier("testLearnedCount")
                    Text("Recent phrases: \(recent.count)").accessibilityIdentifier("testHistoryCount")
                }
            }
            #endif
            Section("About") {
                NavigationLink("What SayAgain does") { SayAgainDoesView() }
                NavigationLink("Limitations") { AboutTextView(title: "Limitations", content: "SayAgain does not know your thoughts, diagnose aphasia or stroke, provide treatment, or replace medical care or a speech-language pathologist.") }
                NavigationLink("Privacy") { AboutTextView(title: "Privacy", content: "The microphone and camera turn on only when you choose. Raw audio and photos are not saved by default.") }
            }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .task { refreshVoiceCatalog() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            refreshVoiceCatalog()
        }
        .onDisappear { preview.stop() }
        .confirmationDialog("Reset learned patterns?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Patterns", role: .destructive) { resetLearned() }
        }
        .confirmationDialog("Clear recent phrases?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { recent.forEach(modelContext.delete); _ = commit() }
        }
        .confirmationDialog("Delete all SayAgain data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Data", role: .destructive) { deleteAll() }
        } message: { Text("This removes Personal Words, phrases, contexts, learned patterns, history, and preferences from SayAgain.") }
        .alert("Changes couldn’t be saved", isPresented: $storageError) { Button("OK", role: .cancel) {} } message: { Text("Please try again. Your saved data is still available.") }
    }

    private func commit() -> Bool {
        do { try modelContext.save(); return true }
        catch { modelContext.rollback(); storageError = true; return false }
    }

    private func refreshVoiceCatalog() {
        let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "Settings")
        let interval = signposter.beginInterval("VoiceCatalogRefresh")
        defer { signposter.endInterval("VoiceCatalogRefresh", interval) }
        guard !hasLoadedVoiceCatalog else {
            voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            return
        }
        voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        hasLoadedVoiceCatalog = true
    }

    private func addContext() {
        let name = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !(ContextChoice.builtIns.map(\.name) + contexts.map(\.name)).contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        modelContext.insert(SavedContext(name: name))
        if commit() { newContext = "" }
    }
    private func deleteContext(_ context: SavedContext) {
        for term in terms where term.contextIDs.contains(context.id) { term.contextIDs.removeAll { $0 == context.id } }
        for phrase in phrases where phrase.contextIDs.contains(context.id) { phrase.contextIDs.removeAll { $0 == context.id } }
        mappings.filter { $0.contextID == context.id }.forEach(modelContext.delete)
        for item in recent where item.contextID == context.id { item.contextID = nil }
        modelContext.delete(context)
        if commit(), defaultContext == context.id { defaultContext = "home" }
    }
    private func resetLearned() {
        mappings.forEach(modelContext.delete)
        termUsages.forEach(modelContext.delete)
        for term in terms { term.usageCount = 0; term.confirmationCount = 0; term.lastUsedAt = nil }
        for phrase in phrases { phrase.usageCount = 0; phrase.lastUsedAt = nil }
        _ = commit()
    }
    private func deleteAll() {
        terms.forEach(modelContext.delete); phrases.forEach(modelContext.delete); mappings.forEach(modelContext.delete)
        termUsages.forEach(modelContext.delete)
        contexts.forEach(modelContext.delete); recent.forEach(modelContext.delete)
        guard commit() else { return }
        microphoneConsentGranted = false
        learn = false; saveRecent = false; defaultContext = "home"; preferredVoiceID = ""; speechRate = 0.50
        hasCompletedOnboarding = false
    }
}

private struct SayAgainDoesView: View {
    var body: some View {
        List {
            Section {
                Text("SayAgain helps you express a word or phrase when you know what you want to say but have difficulty finding or producing it. It gathers clues you choose to share and offers possible words. You decide what you mean.")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 4)
            }

            Section("How it works") {
                explanationRow("Share a clue", detail: "Tap Help Me Say It to speak a short fragment, such as “wa…”. You can also type a clue or take a picture. You can review and remove clues from the suggestion screen. SayAgain does not listen or look around on its own.", symbol: "hand.tap")
                explanationRow("Review what was heard", detail: "Speech recognition shows the words it heard. You can use them, try again, or edit the text before seeing suggestions.", symbol: "text.quote")
                explanationRow("Explore possible words", detail: "SayAgain ranks words from its built-in vocabulary and your Personal Words. A selected context and any photo or typed clues can help order the list. Context and clues do not prove what you mean.", symbol: "list.bullet")
                explanationRow("Choose a phrase", detail: "After you select a word, SayAgain offers short phrase options, including a direct way to say the word. You choose the phrase that communicates what you mean.", symbol: "text.alignleft")
                explanationRow("Speak when you are ready", detail: "SayAgain displays your selected phrase. It speaks only after you tap Speak; you can replay it or stop playback.", symbol: "speaker.wave.2")
            }

            Section("Clues and privacy") {
                explanationRow("Speech", detail: "The microphone turns on only after you tap Help Me Say It. Raw audio is not saved by default. English speech support may need an Apple-managed download before recognition is available.", symbol: "mic")
                explanationRow("Photo", detail: "A photo is captured only when you add a visual clue. SayAgain looks for visible labels that may help rank words; it does not infer a need or intention. Photos are not saved by default.", symbol: "camera")
                explanationRow("Type a clue", detail: "Inside Help Me Say It, a short typed clue helps find possible words. It is used for suggestions, not as a conversation.", symbol: "keyboard")
                explanationRow("Say a typed message", detail: "Use Say Typed Message from Home to write a complete message in your own words. Review the exact text, then choose when to speak it. SayAgain does not add facts or change your wording.", symbol: "text.cursor")
            }

            Section("Suggestions are optional") {
                Text("SayAgain works without Foundation Models or an online AI service. When Apple’s on-device Foundation Models feature is available, it may offer a revised order for words already found by SayAgain. The visible choices stay in place until you tap Update Suggestions. It cannot add a new word to that list. If the feature is unavailable, standard suggestions continue to work.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What SayAgain does")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explanationRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct AboutTextView: View {
    let title: String; let content: String
    var body: some View { ScrollView { Text(content).font(.body).frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle(title) }
}
