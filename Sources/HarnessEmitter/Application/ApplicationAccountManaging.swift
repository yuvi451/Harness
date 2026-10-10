import Foundation

/// Account operations are injected for lifecycle tests without credentials or network access.
@MainActor public protocol ApplicationAccountManaging: AnyObject {
    var accountStatus: String { get }
    var isConnected: Bool { get }
    var accountChoices: [ChatGPTAccountChoice] { get }
    var selectedAccountID: String? { get }
    var onStatusChanged: (() -> Void)? { get set }
    func signIn() async throws
    func signIn(newAccount:Bool) async throws
    func selectAccount(_ id:String) throws
    func cancelSignIn()
    func signOut() throws
    func accessToken() async throws -> String
}
public extension ApplicationAccountManaging {
    var accountChoices: [ChatGPTAccountChoice] { [] }
    var selectedAccountID: String? { nil }
    func signIn(newAccount:Bool) async throws { try await signIn() }
    func selectAccount(_ id:String) throws { throw ChatGPTAuthenticationError.notSignedIn }
}
extension ChatGPTAccountController: ApplicationAccountManaging {}
