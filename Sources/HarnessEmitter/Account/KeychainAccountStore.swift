import Foundation
import Security
import CryptoKit
import KeychainAccess
import HarnessCore

@MainActor struct SystemOAuthClock: OAuthClock { func now() -> Date { Date() } }
@MainActor struct SecurityOAuthRandom: OAuthRandomGenerating {
    func bytes(count: Int) throws -> Data {
        guard (16...128).contains(count) else { throw ChatGPTAuthenticationError.malformedResponse }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ChatGPTAuthenticationError.transportFailure }
        return data
    }
}
@MainActor struct UserDefaultsChatGPTHost: ChatGPTHostIdentifying {
    private let preferences: any Preferences
    init(preferences: (any Preferences)? = nil) { self.preferences = preferences ?? UserDefaultsPreferences() }
    func hostID() throws -> String {
        if let value = preferences.object(forKey: "chatgptHostID") as? String, value.hasPrefix("urn:uuid:"), UUID(uuidString: String(value.dropFirst(9))) != nil { return value }
        let previous = preferences.object(forKey: "chatgptHostID")
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        preferences.set(value, forKey: "chatgptHostID")
        do { try preferences.flush() }
        catch {
            // A failed write must not be mistaken for an existing durable identity
            // by the next sign-in attempt in this process.
            if let previous { preferences.set(previous, forKey: "chatgptHostID") }
            else { preferences.removeObject(forKey: "chatgptHostID") }
            try? preferences.flush()
            throw ChatGPTAuthenticationError.storageFailure
        }
        return value
    }
}
@MainActor final class KeychainChatGPTAccountStore: ChatGPTAccountStore {
    private let keychain = Keychain(service: "org.harness.research.chatgpt").accessibility(.whenUnlockedThisDeviceOnly).authenticationUI(.fail)
    func read() throws -> ChatGPTStoredAccounts { try KeychainInteraction.withAllowed(false) { try Self.read(using: keychain) } }
    func readAuthorized() async throws -> ChatGPTStoredAccounts {
        try await NativeCallbackGate.query(timeoutSeconds:180, timeoutError:ChatGPTAuthenticationError.timedOut) { completion in
            DispatchQueue.global(qos:.userInitiated).async {
                completion(Result { try KeychainInteraction.withAllowed(true) {
                    try Self.read(using:Keychain(service:"org.harness.research.chatgpt").accessibility(.whenUnlockedThisDeviceOnly).authenticationUI(.allow))
                } })
            }
        }
    }
    private nonisolated static func read(using storage: Keychain) throws -> ChatGPTStoredAccounts {
        guard let data = try storage.getData("accounts") else { return ChatGPTStoredAccounts() }
        guard data.count <= 2_097_152 else { throw ChatGPTAuthenticationError.storageFailure }
        return try JSONDecoder().decode(ChatGPTStoredAccounts.self, from: data)
    }
    func replace(_ records: ChatGPTStoredAccounts) throws {
        let data = try JSONEncoder().encode(records)
        guard data.count <= 2_097_152 else { throw ChatGPTAuthenticationError.storageFailure }
        try KeychainInteraction.withAllowed(false) { try keychain.set(data, key: "accounts") }
    }
    private var refreshLocks: [String: AccountFileLock] = [:]
    func transaction(_ mutation: (inout ChatGPTStoredAccounts) throws -> Void) throws -> ChatGPTStoredAccounts {
        let mutex = try AccountFileLock(name: "accounts")
        defer { withExtendedLifetime(mutex) {} }
        var records = try read()
        try mutation(&records)
        try replace(records)
        return records
    }
    func acquireRefreshLock(clientID: String) throws {
        guard refreshLocks[clientID] == nil else { throw ChatGPTAuthenticationError.sessionInUse }
        refreshLocks[clientID] = try AccountFileLock(name: "refresh-" + SHA256.hash(data: Data(clientID.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    func releaseRefreshLock(clientID: String) { refreshLocks.removeValue(forKey: clientID) }
}
