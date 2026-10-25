import SwiftUI
import SwiftData
import OSLog
import SayAgainCore

// The version/schema/migration values never change after launch. Static lets
// satisfy SwiftData's read-only protocol requirements under Swift 6 checking.
enum SayAgainSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    nonisolated(unsafe) static var models: [any PersistentModel.Type] {
        [PersonalTerm.self, PersonalPhrase.self, ConfirmedMapping.self, SavedContext.self, RecentPhrase.self]
    }
}

enum SayAgainSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    nonisolated(unsafe) static var models: [any PersistentModel.Type] {
        [PersonalTerm.self, PersonalPhrase.self, ConfirmedMapping.self, SavedContext.self, RecentPhrase.self, TermUsage.self]
    }
}

enum SayAgainMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [SayAgainSchemaV1.self, SayAgainSchemaV2.self]
    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: SayAgainSchemaV1.self, toVersion: SayAgainSchemaV2.self)
    ]
}

@main
struct SayAgainApp: App {
    @State private var container: ModelContainer?
    @State private var temporaryStorage = false
    private let preferences: UserDefaults

    init() {
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let defaults = testing ? (UserDefaults(suiteName: "org.sayagain.communication.uitests") ?? .standard) : .standard
        if testing {
            defaults.removePersistentDomain(forName: "org.sayagain.communication.uitests")
            defaults.set(ProcessInfo.processInfo.arguments.contains("--skip-onboarding"), forKey: "hasCompletedOnboarding")
            defaults.set(ProcessInfo.processInfo.arguments.contains("--ui-test-capture"), forKey: "microphoneConsentGranted")
        }
        #else
        let testing = false
        let defaults = UserDefaults.standard
        #endif
        preferences = defaults
        let schema = Schema(versionedSchema: SayAgainSchemaV2.self)
        let signposter = OSSignposter(subsystem: "org.sayagain.communication", category: "Startup")
        let storageInterval = signposter.beginInterval("ModelStoreInitialization")
        defer { signposter.endInterval("ModelStoreInitialization", storageInterval) }
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: testing)
            _container = State(initialValue: try ModelContainer(for: schema,
                migrationPlan: SayAgainMigrationPlan.self, configurations: [configuration]))
        } catch {
            // Keep essential communication tools usable if the on-device store
            // cannot open. This fallback is session-only and is never described
            // as saved storage.
            do {
                _temporaryStorage = State(initialValue: true)
                let memoryOnly = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                _container = State(initialValue: try ModelContainer(for: schema,
                    migrationPlan: SayAgainMigrationPlan.self, configurations: [memoryOnly]))
            } catch {
                _container = State(initialValue: nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                AppRootView().modelContainer(container).defaultAppStorage(preferences)
                    .safeAreaInset(edge: .top) {
                        if temporaryStorage {
                            Text("Local storage couldn’t open. Changes won’t be saved after closing SayAgain.")
                                .font(.footnote).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.background)
                        }
                    }
            } else {
                StorageUnavailableView()
            }
        }
    }
}

private struct StorageUnavailableView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Personal Words, learned patterns, and recent phrases can’t be saved right now. You can still choose a quick message or type one to speak.")
                        .foregroundStyle(.secondary)
                }
                Section("Communicate") {
                    NavigationLink { QuickNeedsView(storageAvailable: false) } label: {
                        Label("Quick Needs", systemImage: "hand.raised")
                    }
                    NavigationLink { TypedMessageFlowView(storageAvailable: false) } label: {
                        Label("Say Typed Message", systemImage: "keyboard")
                    }
                }
            }
            .navigationTitle("SayAgain")
            .listStyle(.insetGrouped)
        }
    }
}
