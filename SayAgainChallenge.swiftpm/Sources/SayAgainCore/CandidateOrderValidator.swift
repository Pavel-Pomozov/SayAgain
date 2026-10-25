import Foundation

public enum CandidateOrderValidator {
    public static func orderedIDs(_ generated: [UUID], shortlist: [UUID]) -> [UUID]? {
        guard !generated.isEmpty, generated.count <= 4, Set(generated).count == generated.count,
              generated.allSatisfy(Set(shortlist).contains) else { return nil }
        let selected = Set(generated)
        return generated + shortlist.filter { !selected.contains($0) }
    }
}
