import NativeKeychain
import Foundation

/// The legacy policy is process-wide. Never block the UI behind an authorization dialog.
enum KeychainInteraction {
    private static let lock = NSRecursiveLock()
    static func withAllowed<Value>(_ allowed: Bool, _ operation: () throws -> Value) throws -> Value {
        guard lock.try() else { throw ChatGPTAuthenticationError.storageFailure }
        defer { lock.unlock() }
        var previous = false
        guard HarnessKeychainInteractionGet(&previous) == 0,
              HarnessKeychainInteractionSet(allowed) == 0 else { throw ChatGPTAuthenticationError.storageFailure }
        let result = Result(catching: operation)
        guard HarnessKeychainInteractionSet(previous) == 0 else { throw ChatGPTAuthenticationError.storageFailure }
        return try result.get()
    }
}
