import XCTest
@testable import Keepur

@MainActor
final class AsyncTimeoutTests: XCTestCase {
    func testValueAndImmediateNilDoNotWaitForLongDeadline() async {
        let finished = expectation(description: "both bodies finish")
        let task = Task { @MainActor in
            let value: Int? = await withTimeout(.seconds(30)) { 7 }
            XCTAssertEqual(value, 7)
            let nilValue: Int? = await withTimeout(.seconds(30)) { nil }
            XCTAssertNil(nilValue)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
    }
    func testTimeoutAndParentCancellationFinishSuspendedBody() async throws {
        for cancelParent in [false, true] {
            let entered = expectation(description: "body entered")
            let bodyFinished = expectation(description: "loser finished")
            let returned = expectation(description: "timeout returned")
            var sawCancellation = false
            let task = Task { @MainActor in
                let result: Int? = await withTimeout(cancelParent ? .seconds(30) : .milliseconds(50)) {
                    entered.fulfill()
                    defer { bodyFinished.fulfill() }
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { sawCancellation = Task.isCancelled }
                    return nil
                }
                XCTAssertNil(result)
                returned.fulfill()
            }
            await fulfillment(of: [entered], timeout: 1)
            if cancelParent { task.cancel() }
            await fulfillment(of: [bodyFinished, returned], timeout: 1)
            task.cancel()
            XCTAssertTrue(sawCancellation)
        }
    }
    func testNonpositiveAndAlreadyCanceledEntryDoNotInvokeBody() async {
        var calls = 0
        for duration in [Duration.zero, .milliseconds(-1)] {
            let result: Int? = await withTimeout(duration) { calls += 1; return 1 }
            XCTAssertNil(result)
        }
        let returned = expectation(description: "canceled parent returned")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let result: Int? = await withTimeout(.seconds(30)) { calls += 1; return 1 }
            XCTAssertNil(result)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        task.cancel()
        XCTAssertEqual(calls, 0)
    }
}
