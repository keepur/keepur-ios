import Foundation
import Combine
import SwiftUI
import os

@MainActor
final class CapabilityManager: ObservableObject {
    @Published private(set) var hives: [String] = []
    @Published private(set) var role: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    var onAuthFailure: (() -> Void)?

    private static let selectedHiveKey = "selectedHive"
    private var inFlightTask: Task<Void, Never>?

    var selectedHive: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedHiveKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.selectedHiveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedHiveKey)
            }
            objectWillChange.send()
        }
    }

    func refresh() async {
        if let inFlightTask {
            await inFlightTask.value
            return
        }
        let task = Task { await performRefresh() }
        inFlightTask = task
        await task.value
        inFlightTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let capsTask = APIManager.fetchCapabilities()
            async let meTask = APIManager.fetchMe()
            let (all, me) = try await (capsTask, meTask)

            Log.capabilities.debug("capabilities: \(all.count, privacy: .public) entries")
            let filtered = all.filter { $0 != "beekeeper" }.sorted()
            // Guard each assignment so identical-value writes from a re-fetch
            // don't republish through the SwiftUI view graph. KPR-186 follow-up:
            // an unchanged role still triggered Tab-structure invalidation that
            // contributed to scene-update watchdog kills.
            if hives != filtered { hives = filtered }
            if role != me.role { role = me.role }
            if KeychainManager.deviceName != me.name {
                KeychainManager.deviceName = me.name
            }
            if lastError != nil { lastError = nil }
            reconcileSelectedHive()
        } catch APIManager.APIError.unauthorized {
            lastError = "unauthorized"
            onAuthFailure?()
        } catch {
            lastError = "refresh failed"
        }
    }

    private func reconcileSelectedHive() {
        if hives.count == 1 {
            selectedHive = hives[0]
            return
        }
        if let current = selectedHive, !hives.contains(current) {
            selectedHive = nil
        }
    }

    /// Test seam: inject a pre-built list without hitting the network.
    func _setHivesForTesting(_ values: [String]) {
        hives = values.filter { $0 != "beekeeper" }.sorted()
        reconcileSelectedHive()
    }

    /// Test seam: inject role without hitting the network.
    func _setRoleForTesting(_ value: String?) {
        role = value
    }
}
