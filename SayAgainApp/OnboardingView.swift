import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pages: [(String, String, String)] = [
        ("Say what you mean, your way.", "SayAgain combines the clues you choose to give it — speech, a picture, or text — and offers possible words.", "waveform"),
        ("You’re always in control.", "SayAgain suggests possibilities. You choose the final meaning.", "hand.tap"),
        ("Private by design.", "The microphone and camera turn on only when you choose. Raw audio and visual clues aren’t saved by default.", "lock.shield"),
        ("Optional setup", "Add Personal Words or choose a voice now. You can do either later in Settings.", "slider.horizontal.3")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: pages[page].2).font(.system(size: 40, weight: .regular)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(pages[page].0).font(.largeTitle).multilineTextAlignment(.center)
                Text(pages[page].1).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if page == 3 {
                    NavigationLink("Add Personal Words") { PersonalWordsView() }.buttonStyle(.bordered)
                    NavigationLink("Choose Voice") { SettingsView() }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 40)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if page > 0 { Button("Back") { page -= 1 }.buttonStyle(.bordered).frame(minHeight: 44) }
                Spacer()
                Button(page == pages.count - 1 ? "Get Started" : "Continue") {
                    if page == pages.count - 1 { onFinish() } else { page += 1 }
                }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            }.padding().background(.background)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip") { onFinish() }.accessibilityHint("Go to SayAgain Home") } }
        .navigationBarBackButtonHidden(true)
    }
}
