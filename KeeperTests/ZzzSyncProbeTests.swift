import XCTest

/// THROWAWAY (#98): exists only to prove the synchronized group picks up
/// a new file with no project-file edit. Reverted after CI shows 175 tests.
final class ZzzSyncProbeTests: XCTestCase {
    func testSynchronizedGroupPicksUpNewFiles() {
        XCTAssertTrue(true)
    }
}
