import Foundation
import SwiftData
import os

extension ModelContext {
    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString
    ) -> [T] {
        var failure: Error?
        return fetchOrEmpty(descriptor, what, failure: &failure)
    }

    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString,
        failure: inout Error?
    ) -> [T] {
        fetchOrEmpty(descriptor, what, failure: &failure, operation: { try self.fetch($0) })
    }

    func fetchOrEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: StaticString,
        failure: inout Error?, operation: (FetchDescriptor<T>) throws -> [T]
    ) -> [T] {
        attemptReporting(what, failure: &failure) { try operation(descriptor) } ?? []
    }

    @discardableResult
    func saveReporting(_ what: StaticString) -> Error? {
        saveReporting(what, operation: { try self.save() })
    }

    @discardableResult
    func saveReporting(_ what: StaticString, operation: () throws -> Void) -> Error? {
        var failure: Error?
        let _: Void? = attemptReporting(what, failure: &failure, operation: operation)
        return failure
    }

    private func attemptReporting<Value>(
        _ what: StaticString, failure: inout Error?, operation: () throws -> Value
    ) -> Value? {
        failure = nil
        do {
            return try operation()
        } catch {
            let label = String(describing: what)
            let errorType = String(reflecting: type(of: error))
            let code = (error as NSError).code
            Log.persistence.error("\(label, privacy: .public) failed: type=\(errorType, privacy: .public) code=\(code, privacy: .public)")
            failure = error
            return nil
        }
    }
}
