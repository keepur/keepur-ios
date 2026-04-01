import SwiftUI
import SwiftData

@main
struct KeepurApp: App {
    let modelContainer: ModelContainer

    init() {
        KeychainManager.migrateAccessibility()
        do {
            let schema = Schema([Session.self, Message.self, Workspace.self])
            let config = ModelConfiguration(schema: schema)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            let url = URL.applicationSupportDirectory.appending(path: "default.store")
            try? FileManager.default.removeItem(at: url)
            do {
                let schema = Schema([Session.self, Message.self, Workspace.self])
                let config = ModelConfiguration(schema: schema)
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
