import XCTest
import SwiftUI
import SwiftData
@testable import Keepur

final class SessionRowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Session.self, Message.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    private func makeSession(
        id: String = "s1",
        path: String = "/Users/dev/project",
        name: String? = nil,
        isStale: Bool = false
    ) -> Session {
        let s = Session(id: id, path: path, name: name, isStale: isStale)
        context.insert(s)
        return s
    }

    func testRowActiveNotStale() {
        let s = makeSession()
        let row = SessionRow(session: s, isActive: true, modelContext: context)
        _ = row.body
    }

    func testRowStaleNotActive() {
        let s = makeSession(isStale: true)
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowActiveAndStale() {
        let s = makeSession(isStale: true)
        let row = SessionRow(session: s, isActive: true, modelContext: context)
        _ = row.body
    }

    func testRowNeitherActiveNorStale() {
        let s = makeSession()
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowLongPath() {
        let s = makeSession(path: "/very/long/path/that/should/truncate/in/the/ui/projectname")
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }

    func testRowNoPreviewMessage() {
        let s = makeSession()
        let row = SessionRow(session: s, isActive: false, modelContext: context)
        _ = row.body
    }
}
