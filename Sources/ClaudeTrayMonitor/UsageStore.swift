import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var isRefreshing = false
    var onChange: (() -> Void)?

    func setSnapshot(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        onChange?()
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
    }

    var orderedFields: [String] {
        var fields = UsageParser.preferredFieldOrder.filter { snapshot.windows[$0] != nil }
        for key in snapshot.windows.keys where !fields.contains(key) && key != "extra_usage" {
            fields.append(key)
        }
        return fields
    }
}