import Foundation

public struct PhraseOption: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable { case builtIn, personal }
    public let id: String
    public let displayText: String
    public let spokenText: String
    public let source: Source

    public init(displayText: String, spokenText: String, source: Source = .builtIn) {
        self.id = displayText
        self.displayText = displayText
        self.spokenText = spokenText
        self.source = source
    }
}

public enum PhraseLibrary {
    /// Keeps the visible instruction for literal phrases separate from the
    /// exact text sent to speech synthesis. User-authored phrases are passed
    /// through unchanged and are never parsed as template syntax.
    public static func options(for term: VocabularyTerm) -> [PhraseOption] {
        phrases(for: term).map { display in
            PhraseOption(displayText: display, spokenText: spokenText(for: display, term: term))
        }
    }

    public static func phrases(for term: VocabularyTerm) -> [String] {
        if term.category == .people {
            return ["Please call \(term.displayText).", "I want to talk to \(term.displayText).", "Where is \(term.displayText)?", "Just say “\(term.displayText).”"]
        }
        switch term.canonicalText.lowercased() {
        case "water": return ["I want water.", "More water, please.", "Where is my water?", "Just say “Water.”"]
        case "coffee": return ["I want coffee.", "More coffee, please.", "Where is my coffee?", "Just say “Coffee.”"]
        case "help": return ["I need help.", "Please help me.", "Just say “Help.”"]
        case "pain": return ["I am in pain.", "Please help with my pain.", "Just say “Pain.”"]
        case "bathroom": return ["I need the bathroom.", "Where is the bathroom?", "Just say “Bathroom.”"]
        case "medication": return ["I need my medication.", "Please help me with my medication.", "Just say “Medication.”"]
        case "yes": return ["Yes."]
        case "no": return ["No."]
        case "agree": return ["I agree.", "Just say “Agree.”"]
        case "do not agree": return ["I do not agree.", "Just say “Do not agree.”"]
        case "emergency": return ["This is an emergency.", "Just say “Emergency.”"]
        case "call": return ["Please call someone.", "I want to make a call.", "Just say “Call.”"]
        case "want": return ["I want…", "Just say “Want.”"]
        case "doctor": return ["I need to see the doctor.", "Please call my doctor.", "Just say “Doctor.”"]
        default:
            if term.category == .foodAndDrink {
                return ["I want \(term.displayText).", "More \(term.displayText), please.", "Just say “\(term.displayText).”"]
            }
            return ["Just say “\(term.displayText).”"]
        }
    }

    public static func spokenText(for option: String, term: VocabularyTerm) -> String {
        let literal = "Just say “\(term.displayText).”"
        if option == literal { return term.displayText }
        if option.hasPrefix("Just say “"), option.hasSuffix(".”") {
            let quoted = String(option.dropFirst("Just say “".count).dropLast(2))
            if TextNormalizer.normalize(quoted) == TextNormalizer.normalize(term.canonicalText) { return term.displayText }
        }
        return option
    }

    public static func quickNeedPhrase(_ label: String) -> String {
        switch label.uppercased() {
        case "YES": return "Yes."
        case "NO": return "No."
        case "WATER": return "I want water."
        case "BATHROOM": return "I need the bathroom."
        case "PAIN": return "I am in pain."
        case "HELP": return "I need help."
        default: return label
        }
    }

    public static func painPhrase(region: String, intensity: String) -> String {
        if region == "Other" { return "I have \(intensity.lowercased()) pain in another part of my body." }
        return "I have \(intensity.lowercased()) pain in my \(region.lowercased())."
    }
}
