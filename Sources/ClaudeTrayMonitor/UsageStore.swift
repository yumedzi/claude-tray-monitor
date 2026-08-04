import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    var onChange: (() -> Void)?

    func setSnapshot(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        onChange?()
    }

    var orderedFields: [String] {
        var fields = UsageParser.preferredFieldOrder.filter { snapshot.windows[$0] != nil }
        for key in snapshot.windows.keys where !fields.contains(key) {
            fields.append(key)
        }
        return fields
    }
}