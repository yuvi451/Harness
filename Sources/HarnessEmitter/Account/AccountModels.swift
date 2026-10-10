import Foundation
import CryptoKit

public enum ChatGPTAuthenticationError: Error, Equatable, LocalizedError {
    case invalidCallback, stateMismatch, authorizationDenied, registrationIncomplete, invalidIdentity
    case missingPlanPermission, malformedResponse, transportFailure, storageFailure, timedOut
    case notSignedIn, requestInProgress, sessionInUse, browserUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidCallback, .stateMismatch: return "The sign-in callback was invalid. Start a new sign-in."
        case .authorizationDenied: return "ChatGPT authorization was declined."
        case .registrationIncomplete: return "ChatGPT registration did not return an issued client identity."
        case .invalidIdentity: return "The ChatGPT account identity could not be verified."
        case .missingPlanPermission: return "This account has not granted permission to use its ChatGPT plan."
        case .malformedResponse: return "ChatGPT returned an unsupported authentication response."
        case .transportFailure: return "The ChatGPT authentication connection failed. Try again manually."
        case .storageFailure: return "ChatGPT account storage is unavailable. Use Continue with ChatGPT in Settings to unlock or retry."
        case .timedOut: return "ChatGPT sign-in timed out. Start a new sign-in."
        case .notSignedIn: return "Continue with ChatGPT in Settings before submitting an image."
        case .requestInProgress: return "A ChatGPT account operation is already in progress."
        case .sessionInUse: return "Another process holds this ChatGPT session. Close other Harness instances and retry."
        case .browserUnavailable: return "The system browser could not open ChatGPT sign-in."
        }
    }
}

public struct OAuthHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
@MainActor public protocol OAuthHTTPClient { func send(_ request: URLRequest) async throws -> OAuthHTTPResponse }
@MainActor public protocol OAuthBrowserAuthenticating {
    func prepareCallback() async throws -> URL
    func authenticate(authorizationURL: URL, redirectURI: URL) async throws -> URL
    func cancel()
}
@MainActor public protocol OAuthClock { func now() -> Date }
@MainActor public protocol OAuthRandomGenerating { func bytes(count: Int) throws -> Data }
@MainActor public protocol ChatGPTHostIdentifying { func hostID() throws -> String }

public struct ChatGPTIdentity: Codable, Equatable, Sendable {
    public let issuer: String
    public let subject: String
    public let email: String?
}
public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let scopes: [String]
    public let expiresAt: Date
}
public struct ChatGPTAccountRegistration: Codable, Equatable, Sendable {
    public let clientID: String
    public let identity: ChatGPTIdentity
    public var tokens: ChatGPTTokens?
    /// Changes even when disconnecting an already disconnected registration.
    /// Optional for compatibility with existing protected account records.
    public var credentialGeneration: UUID? = nil
}
public struct ChatGPTStoredAccounts: Codable, Equatable, Sendable {
    public var accounts: [ChatGPTAccountRegistration] = []
    public var activeClientID: String?
    public init() {}
}
public struct ChatGPTAccountChoice: Equatable, Sendable {
    public let id: String
    public let label: String
    public init(id:String,label:String) { self.id = id; self.label = label }
}
@MainActor public protocol ChatGPTAccountStore {
    func read() throws -> ChatGPTStoredAccounts
    /// Only an explicit Settings action may permit the OS authorization dialog.
    func readAuthorized() async throws -> ChatGPTStoredAccounts
    /// Replace the entire token set and expiry together in one protected record.
    func replace(_ records: ChatGPTStoredAccounts) throws
    /// Synchronous read-modify-write, serialized across every client in this store.
    /// The mutation must not suspend or perform network operations.
    func transaction(_ mutation: (inout ChatGPTStoredAccounts) throws -> Void) throws -> ChatGPTStoredAccounts
    func acquireRefreshLock(clientID: String) throws
    func releaseRefreshLock(clientID: String)
}
public extension ChatGPTAccountStore {
    func readAuthorized() async throws -> ChatGPTStoredAccounts { try read() }
    // MainActor serializes hermetic stores. Native stores also serialize across processes.
    func transaction(_ mutation: (inout ChatGPTStoredAccounts) throws -> Void) throws -> ChatGPTStoredAccounts {
        var records = try read()
        try mutation(&records)
        try replace(records)
        return records
    }
    func acquireRefreshLock(clientID: String) throws {}
    func releaseRefreshLock(clientID: String) {}
}

public enum OAuthPKCE {
    public static func challenge(verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).oauthBase64URL }
}

enum OpenAIAuth {
    static let issuer = "https://auth.openai.com"
    static let discovery = URL(string: issuer + "/.well-known/openid-configuration")!
    static let authorize = URL(string: issuer + "/api/accounts/authorize")!
    static let token = URL(string: issuer + "/api/accounts/oauth/token")!
    static let jwks = URL(string: issuer + "/.well-known/jwks.json")!
    static let revoke = URL(string: issuer + "/api/accounts/oauth/revoke")!
    static let resource = "https://api.openai.com/v1"
    static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    static func validClient(_ value: String) -> Bool {
        value.hasPrefix("oaiapp_") && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func request(_ url: URL, fields: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let fields { request.httpMethod = "POST"; request.httpBody = form(fields); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
