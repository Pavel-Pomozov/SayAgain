import SwiftUI
import SwiftData
import SayAgainCore

struct PersonalWordsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersonalTerm.displayText) private var terms: [PersonalTerm]
    @Query private var mappings: [ConfirmedMapping]
    @Query private var phrases: [PersonalPhrase]
    @Query private var recent: [RecentPhrase]
    @State private var editor: TermEditorRoute?
    @State private var storageError = false

    var body: some View {
        List {
            ForEach(PersonalTermCategory.allCases) { category in
                let rows = terms.filter { $0.category == category }
                if !rows.isEmpty {
                    Section(category.rawValue) {
                        ForEach(rows) { term in
                            Button { editor = TermEditorRoute(term: term) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(term.displayText)
                                        if let relationship = term.relationship, !relationship.isEmpty {
                                            Text(relationship).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                                }.frame(minHeight: 52).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editor = TermEditorRoute(term: term) }
                                Button("Delete", systemImage: "trash", role: .destructive) { delete([term]) }
                            }
                            .accessibilityAction(named: "Delete Word") { delete([term]) }
                        }.onDelete { offsets in delete(offsets.map { rows[$0] }) }
                    }
                }
            }
        }
        .overlay {
            if terms.isEmpty {
                ContentUnavailableView("Personal Words", systemImage: "text.book.closed",
                    description: Text("Add names, places, and words that matter to you using the Add button."))
            }
        }
        .navigationTitle("Personal Words").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor = TermEditorRoute(term: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Add a personal word")
            }
        }
        .sheet(item: $editor) { route in TermEditorSheet(term: route.term) }
        .alert("Changes couldn’t be saved", isPresented: $storageError) { Button("OK", role: .cancel) {} } message: { Text("Please try again. Your words haven’t been deleted.") }
    }

    private func delete(_ selected: [PersonalTerm]) {
        for term in selected {
            mappings.filter { $0.confirmedTermID == term.id }.forEach(modelContext.delete)
            for phrase in phrases where phrase.relatedTermIDs.contains(term.id) {
                if phrase.unlink(termID: term.id) { modelContext.delete(phrase) }
            }
            for item in recent where item.termID == term.id { item.termID = nil }
            modelContext.delete(term)
        }
        do { try modelContext.save() }
        catch { modelContext.rollback(); storageError = true }
    }
}

private struct TermEditorRoute: Identifiable { let id = UUID(); let term: PersonalTerm? }
private struct PhraseDraft: Identifiable { let id: UUID; var text: String }

struct TermEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allPhrases: [PersonalPhrase]
    @Query private var savedContexts: [SavedContext]
    let term: PersonalTerm?
    @State private var canonicalText: String
    @State private var relationship: String
    @State private var category: PersonalTermCategory
    @State private var synonyms: String
    @State private var enabled: Bool
    @State private var phraseText = ""
    @State private var contextIDs: Set<String>
    @State private var phraseDrafts: [PhraseDraft] = []
    @State private var loadedDrafts = false
    @State private var storageError = false
    @State private var confirmDelete = false

    init(term: PersonalTerm?) {
        self.term = term
        _canonicalText = State(initialValue: term?.displayText ?? "")
        _relationship = State(initialValue: term?.relationship ?? "")
        _category = State(initialValue: term?.category ?? .custom)
        _synonyms = State(initialValue: term?.synonyms.joined(separator: ", ") ?? "")
        _enabled = State(initialValue: term?.enabled ?? true)
        _contextIDs = State(initialValue: Set(term?.contextIDs ?? []))
    }

    private var linkedPhrases: [PersonalPhrase] {
        guard let term else { return [] }
        return allPhrases.filter { $0.relatedTermIDs.contains(term.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Word") {
                    TextField("Word or name", text: $canonicalText).autocorrectionDisabled()
                    Picker("Section", selection: $category) { ForEach(PersonalTermCategory.allCases) { Text($0.rawValue).tag($0) } }
                    if category == .people { TextField("Relationship (optional)", text: $relationship) }
                    TextField("Other ways to say it, separated by commas", text: $synonyms, axis: .vertical).lineLimit(2...4)
                    Toggle("Include in suggestions", isOn: $enabled)
                }
                Section("Contexts") {
                    ForEach(ContextChoice.builtIns + savedContexts.map { ContextChoice(id: $0.id, name: $0.name, kind: .custom) }) { choice in
                        Toggle(choice.name, isOn: Binding(get: { contextIDs.contains(choice.id) }, set: { value in
                            if value { contextIDs.insert(choice.id) } else { contextIDs.remove(choice.id) }
                        }))
                    }
                }
                Section("Personal Phrases") {
                    ForEach($phraseDrafts) { $phrase in
                        HStack {
                            TextField("Personal phrase", text: $phrase.text, axis: .vertical)
                                .accessibilityLabel("Personal phrase")
                                .accessibilityIdentifier("personalPhrase-\(phrase.id.uuidString)")
                            Button("Delete personal phrase", systemImage: "trash", role: .destructive) {
                                phraseDrafts.removeAll { $0.id == phrase.id }
                            }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                        }
                    }.onDelete { phraseDrafts.remove(atOffsets: $0) }
                    HStack {
                        TextField("Write a phrase", text: $phraseText)
                        Button("Add") {
                            let text = phraseText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { phraseDrafts.append(PhraseDraft(id: UUID(), text: text)); phraseText = "" }
                        }.buttonStyle(.bordered).disabled(phraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if term != nil {
                    Section {
                        Button("Delete Word", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(term == nil ? "New Word" : "Edit Word")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear {
                guard !loadedDrafts else { return }
                loadedDrafts = true
                phraseDrafts = linkedPhrases.map { PhraseDraft(id: $0.id, text: $0.spokenText) }
            }
            .alert("Changes couldn’t be saved", isPresented: $storageError) { Button("OK", role: .cancel) {} } message: { Text("Your edits are still here. Please try again.") }
            .confirmationDialog("Delete this personal word?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Word", role: .destructive) { deleteTerm() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This also removes its learned patterns. Shared phrases stay linked to other words.") }
        }
    }

    private func save() {
        let clean = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let oldPhrases = linkedPhrases
        var drafts = phraseDrafts
        let pendingPhrase = phraseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingPhrase.isEmpty { drafts.append(PhraseDraft(id: UUID(), text: pendingPhrase)) }
        let savedTerm = term ?? PersonalTerm(canonicalText: clean)
        if term == nil { modelContext.insert(savedTerm) }
        savedTerm.canonicalText = clean; savedTerm.displayText = clean; savedTerm.category = category
        savedTerm.contextIDs = contextIDs.sorted()
        savedTerm.enabled = enabled
        let relation = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        savedTerm.relationship = relation.isEmpty ? nil : relation
        savedTerm.synonyms = synonyms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let retained = Set(drafts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
        for phrase in oldPhrases where !retained.contains(phrase.id) {
            if phrase.unlink(termID: savedTerm.id) { modelContext.delete(phrase) }
        }
        for draft in drafts {
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let existing = oldPhrases.first(where: { $0.id == draft.id }) {
                if existing.relatedTermIDs.count > 1
                    && (existing.spokenText != text || existing.contextIDs != contextIDs.sorted()) {
                    existing.unlink(termID: savedTerm.id)
                    modelContext.insert(PersonalPhrase(spokenText: text,
                        relatedTermIDs: [savedTerm.id], contextIDs: contextIDs.sorted()))
                } else {
                    existing.spokenText = text
                    existing.contextIDs = contextIDs.sorted()
                }
            }
            else { modelContext.insert(PersonalPhrase(id: draft.id, spokenText: text, relatedTermIDs: [savedTerm.id], contextIDs: contextIDs.sorted())) }
        }
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); storageError = true }
    }

    private func deleteTerm() {
        guard let term else { return }
        do {
            for mapping in try modelContext.fetch(FetchDescriptor<ConfirmedMapping>()) where mapping.confirmedTermID == term.id {
                modelContext.delete(mapping)
            }
            for phrase in linkedPhrases where phrase.unlink(termID: term.id) {
                modelContext.delete(phrase)
            }
            for recent in try modelContext.fetch(FetchDescriptor<RecentPhrase>()) where recent.termID == term.id {
                recent.termID = nil
            }
            modelContext.delete(term)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            storageError = true
        }
    }
}
