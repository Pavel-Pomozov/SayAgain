import SwiftUI
import Observation
import SayAgainCore
import SayAgainAudio

public typealias DemoSpeechOutput = SayAgainAudio.SpeechOutput

/// The same intentionally labeled offline demonstration in both products.
@MainActor public struct SayAgainDemoView: View {
    @State private var demo = CommunicationDemo()
    @State private var speaker: any DemoSpeechOutput
    @State private var hasSpoken = false
    @State private var typedMessageStep: TypedMessageStep?
    @State private var typedMessage = ""
    @State private var typedMessageHasSpoken = false
    @State private var browsing = false
    @State private var search = ""
    private let onClose: (() -> Void)?

    public init(speaker: (any DemoSpeechOutput)? = nil, onClose: (() -> Void)? = nil) {
        _speaker = State(initialValue: speaker ?? SpeechOutputDriver())
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let typedMessageStep {
                    typedMessageContent(for: typedMessageStep)
                } else {
                    switch demo.step {
                    case .introduction: introduction
                    case .suggestions: suggestions
                    case .phrases: phrasePicker
                    case .speak: communication
                    case .conclusion: conclusion
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let typedMessageStep {
                    switch typedMessageStep {
                    case .edit:
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { speaker.stop(); self.typedMessageStep = nil }
                        }
                    case .review:
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Edit") { self.typedMessageStep = .edit }
                        }
                    case .speak:
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Review") { speaker.stop(); self.typedMessageStep = .review }
                        }
                    }
                } else if demo.step != .introduction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.backward") { speaker.stop(); demo.back() }
                            .accessibilityIdentifier("demoBack")
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { speaker.stop(); onClose() }.accessibilityIdentifier("closeDemo")
                    }
                }
            }
            .sheet(isPresented: $browsing) {
                NavigationStack {
                    List(demo.terms.filter { search.isEmpty || $0.displayText.localizedCaseInsensitiveContains(search) }
                        .sorted { $0.displayText < $1.displayText }) { term in
                        Button(term.displayText) { demo.select(term.id); browsing = false }
                    }
                    .searchable(text: $search, prompt: "Search example words")
                    .navigationTitle("Something Else")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { browsing = false } } }
                }
            }
        }
        .tint(.blue)
        .onChange(of: demo.step) { _, _ in speaker.stop(); hasSpoken = false }
        .onChange(of: speaker.playbackStartCount) { oldCount, count in
            guard count > oldCount else { return }
            if typedMessageStep != nil { typedMessageHasSpoken = true }
            else if demo.step == .speak { hasSpoken = true }
        }
        .onDisappear { speaker.stop() }
    }

    private var title: String {
        if let typedMessageStep {
            switch typedMessageStep {
            case .edit: return "Say Typed Message"
            case .review: return "Review Message"
            case .speak: return "Your Phrase"
            }
        }
        return switch demo.step {
        case .introduction: "SayAgain Demo"
        case .phrases: demo.selectedTerm?.displayText ?? "Phrases"
        case .speak: "Your Phrase"
        case .conclusion: "Your Choice"
        default: demo.example == .breakfast ? "Breakfast" : "Personal Words"
        }
    }

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Imagine knowing what you want to say but being unable to find the word.")
                    .font(.title2).accessibilityAddTraits(.isHeader)
                Text("Try a breakfast example. Start with an incomplete word, add a clue, and choose what to say.")
                    .foregroundStyle(.secondary)
                Text("This demo uses local example clues. No microphone or camera is active, and your choices aren’t saved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity).padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            footer {
                primary("Begin breakfast demo") { demo.begin() }
                secondary("Say Typed Message") {
                    typedMessage = ""
                    typedMessageHasSpoken = false
                    typedMessageStep = .edit
                }.accessibilityIdentifier("demoTypedMessageEntry")
            }
        }
    }

    @ViewBuilder private func typedMessageContent(for step: TypedMessageStep) -> some View {
        switch step {
        case .edit:
            Form {
                Section("Your message") {
                    TextEditor(text: $typedMessage)
                        .frame(minHeight: 150)
                        .accessibilityLabel("Write the message you want to say")
                        .accessibilityIdentifier("demoTypedMessageInput")
                }
                Section {
                    Text("Review your exact wording before choosing to speak it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer {
                    primary("Review Message") { speaker.stop(); typedMessageStep = .review }
                        .disabled(typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("demoReviewTypedMessage")
                    privacy
                }
            }
        case .review:
            ScrollView {
                VStack(spacing: 20) {
                    Text("Your message").font(.title2).accessibilityAddTraits(.isHeader)
                    Text(typedMessage).font(.largeTitle).multilineTextAlignment(.center).textSelection(.enabled)
                    Text("SayAgain will speak only this text, after you choose Speak.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 28)
            }
            .safeAreaInset(edge: .bottom) {
                footer {
                    primary("Continue to Speak") { typedMessageStep = .speak }
                        .accessibilityIdentifier("demoContinueTypedMessage")
                    privacy
                }
            }
        case .speak:
            ScrollView {
                VStack(spacing: 16) {
                    Text(typedMessage).font(.largeTitle).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if speaker.playbackState == .preparing { ProgressView("Starting speech…").font(.footnote).foregroundStyle(.secondary) }
                    if let error = speaker.playbackError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 32)
            }
            .safeAreaInset(edge: .bottom) {
                footer {
                    SpeechPlaybackButton(state: speaker.playbackState,
                        idleTitle: typedMessageHasSpoken ? "Replay" : "Speak", activeTitle: "Stop") {
                        if speaker.playbackState.isActive { speaker.stop() }
                        else { speaker.speak(typedMessage) }
                    }.buttonStyle(.borderedProminent)
                    privacy
                }
            }
        }
    }

    private var suggestions: some View {
        List {
            Section("I heard") {
                Text("“\(demo.speech)”").font(.title2)
                Text("Example speech clue · Microphone Off").font(.footnote).foregroundStyle(.secondary)
            }
            if demo.hasVisualClue {
                Section("Added clue") {
                    GlassIllustration().frame(maxWidth: .infinity).frame(height: 128)
                    Text("Example visual labels: glass, drink").foregroundStyle(.secondary)
                    Text("Bundled illustration and supplied labels. This is not live image recognition.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if demo.example == .personalWord {
                Section("Example Personal Word") {
                    Label("Sarah — Daughter", systemImage: "person")
                    Text("Sarah is part of this example only. No contacts were imported.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(demo.candidates) { candidate in
                    Button { demo.select(candidate.id) } label: {
                        HStack {
                            Text(candidate.displayLabel)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button("Something Else…") { browsing = true }
            } header: { Text("Did you mean?").font(.title2) }
        }
        .safeAreaInset(edge: .bottom) {
            if demo.example == .breakfast && !demo.hasVisualClue {
                footer { primary("Add a visual clue") { demo.addVisualClue() } }
            }
        }
    }

    private var phrasePicker: some View {
        List {
            Section {
                ForEach(demo.phrases, id: \.self) { option in
                    Button(option) { demo.selectPhrase(option) }.frame(minHeight: 52)
                }
            } header: { Text("Choose what to say") }
        }
    }

    private var communication: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(demo.phrase).font(.largeTitle).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if speaker.playbackState == .preparing { ProgressView("Starting speech…").font(.footnote).foregroundStyle(.secondary) }
                if let error = speaker.playbackError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding(24).padding(.top, 32)
        }
        .safeAreaInset(edge: .bottom) {
            footer {
                SpeechPlaybackButton(state: speaker.playbackState,
                    idleTitle: hasSpoken ? "Replay" : "Speak", activeTitle: "Stop") {
                    if speaker.playbackState.isActive { speaker.stop() }
                    else { speaker.speak(demo.phrase) }
                }.buttonStyle(.borderedProminent)
                secondary("Finish Example") { speaker.stop(); demo.finish() }
                privacy
            }
        }
    }

    private var conclusion: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("SayAgain didn’t decide what the person meant. It helped them express it.")
                    .font(.title2).accessibilityAddTraits(.isHeader)
                Text("You chose the word, then the phrase. Speech, photos, and text are clues you can control.")
                    .foregroundStyle(.secondary)
                Text("In the app, optional learning stores only confirmed choices you choose to speak. You can reset those patterns at any time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity).padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            footer {
                if demo.example == .breakfast {
                    primary("Try the Sarah example") { demo.begin(.personalWord) }
                }
                secondary("Restart Demo") { speaker.stop(); demo.restart() }
            }
        }
    }

    private var privacy: some View {
        Text("Local example · Microphone Off · Camera Off").font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
    }
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
    }
    private func footer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12, content: content).buttonBorderShape(.capsule)
            .frame(maxWidth: 600).frame(maxWidth: .infinity).padding().background(.background)
    }
}

private enum TypedMessageStep {
    case edit
    case review
    case speak
}

private struct GlassIllustration: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8).stroke(.secondary, lineWidth: 2).frame(width: 76, height: 112)
            Rectangle().fill(Color.blue.opacity(0.22)).frame(width: 70, height: 42).padding(.bottom, 3)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Example illustration of a drinking glass")
    }
}

