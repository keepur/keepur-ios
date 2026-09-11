import Foundation

@MainActor
func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ body: @escaping @MainActor @Sendable () async -> T?
) async -> T? {
    guard duration > .zero, !Task.isCancelled else { return nil }
    let result: T? = await withTaskGroup(of: T?.self) { group in
        defer { group.cancelAll() }
        group.addTask { @MainActor in
            guard !Task.isCancelled else { return nil }
            return await body()
        }
        group.addTask {
            do { try await Task.sleep(for: duration) }
            catch { return nil }
            return nil
        }
        return await group.next() ?? nil
    }
    return Task.isCancelled ? nil : result
}
