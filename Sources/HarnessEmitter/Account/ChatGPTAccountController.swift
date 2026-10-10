import Foundation

/// OAuth account management is separate from screenshot capture and submission consent.
@MainActor public final class ChatGPTAccountController {
    private let http: any OAuthHTTPClient
    private let browser: any OAuthBrowserAuthenticating
    private let store: any ChatGPTAccountStore
    private let host: any ChatGPTHostIdentifying
    private let random: any OAuthRandomGenerating
    private let clock: any OAuthClock
    private var records = ChatGPTStoredAccounts()
    private var signingIn = false
    private var generation: UInt64 = 0
    private var signInTask: Task<Void, Error>?
    private var refreshTask: Task<String, Error>?
    private var revocationTask: Task<Void, Never>?
    private var storageBlocked = false
    public private(set) var accountStatus = "Signed out"
    public var onStatusChanged: (() -> Void)?
    public var hasAccount: Bool { !storageBlocked && activeRegistration?.tokens != nil }
    public var isConnected: Bool {
        !storageBlocked && activeRegistration?.tokens.map(Self.hasPlanPermission) == true
    }
    private var activeRegistration: ChatGPTAccountRegistration? { records.accounts.first { $0.clientID == records.activeClientID } }
    public var accountChoices: [ChatGPTAccountChoice] {
        guard !storageBlocked else { return [] }
        return records.accounts.map { .init(id:$0.clientID,label:String(($0.identity.email ?? "ChatGPT account").prefix(96)) + " · " + $0.clientID) }
    }
    public var selectedAccountID: String? { records.activeClientID }
    public func selectAccount(_ id:String) throws {
        guard !signingIn, refreshTask == nil else { throw ChatGPTAuthenticationError.requestInProgress }
        try mutateStored(selectingUpdatedAccount:true) { candidate in
            guard candidate.accounts.contains(where:{ $0.clientID == id }) else { throw ChatGPTAuthenticationError.notSignedIn }
            candidate.activeClientID = id
        }
        generation &+= 1; updateStatus()
    }

    public init(http: any OAuthHTTPClient, browser: any OAuthBrowserAuthenticating, store: any ChatGPTAccountStore,
                host: any ChatGPTHostIdentifying, random: any OAuthRandomGenerating, clock: any OAuthClock) {
        self.http = http; self.browser = browser; self.store = store; self.host = host; self.random = random; self.clock = clock
        do { records = try store.read(); try validateStored(records); updateStatus() }
        catch { storageBlocked = true; accountStatus = "Saved account unavailable; use Continue with ChatGPT to unlock or retry" }
    }
    public convenience init() {
        self.init(http: EphemeralOAuthHTTPClient(), browser: LoopbackOAuthBrowser(), store: KeychainChatGPTAccountStore(),
                  host: UserDefaultsChatGPTHost(), random: SecurityOAuthRandom(), clock: SystemOAuthClock())
    }

    public func signIn() async throws { try await signIn(newAccount: false) }
    /// Additional registrations remain separate even when they have the same email.
    public func signIn(newAccount: Bool) async throws {
        guard !signingIn, refreshTask == nil else { throw ChatGPTAuthenticationError.requestInProgress }
        signingIn = true
        generation &+= 1
        let attempt = generation
        defer { signInTask = nil; signingIn = false; browser.cancel(); if generation == attempt { updateStatus() } }
        if storageBlocked {
            setStatus("Unlock your saved ChatGPT account in the macOS dialog")
            let latest: ChatGPTStoredAccounts
            do { latest = try await store.readAuthorized(); try ensureCurrent(attempt); try validateStored(latest) }
            catch is CancellationError { throw CancellationError() }
            catch { storageBlocked = true; updateStatus(); throw ChatGPTAuthenticationError.storageFailure }
            records = latest
            storageBlocked = false
            updateStatus()
            if !newAccount && isConnected { return }
        } else { try reloadSelectedRecords() }
        let selected = newAccount ? nil : activeRegistration
        setStatus("Signing in with ChatGPT")
        let task = Task { @MainActor in try await self.performSignIn(selected: selected, attempt: attempt) }
        signInTask = task
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func performSignIn(selected: ChatGPTAccountRegistration?, attempt: UInt64) async throws {
        do {
            try Task.checkCancellation()
            try await verifyDiscovery()
            try ensureCurrent(attempt)
            let redirect = try await browser.prepareCallback()
            guard Self.validRedirect(redirect) else { throw ChatGPTAuthenticationError.invalidCallback }
            let state = try random.bytes(count: 32).oauthBase64URL
            let nonce = try random.bytes(count: 32).oauthBase64URL
            let verifier = try random.bytes(count: 64).oauthBase64URL
            guard state.count >= 43, nonce.count >= 43, (43...128).contains(verifier.count) else { throw ChatGPTAuthenticationError.malformedResponse }
            let start = clock.now()
            var query = ["client_id": selected?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": try host.hostID(),
                "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": OpenAIAuth.scopes.joined(separator: " "),
                "resource": OpenAIAuth.resource, "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": OAuthPKCE.challenge(verifier: verifier)]
            if selected == nil { query["agent_name_hint"] = "Harness" }
            if let hint = selected?.tokens?.idToken { query["id_token_hint"] = hint }
            if let tokens = selected?.tokens, !Self.hasPlanPermission(tokens) { query["prompt"] = "consent" }
            var authorization = URLComponents(url: OpenAIAuth.authorize, resolvingAgainstBaseURL: false)!
            authorization.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
            let callback = try await browser.authenticate(authorizationURL: authorization.url!, redirectURI: redirect)
            try ensureCurrent(attempt)
            guard clock.now().timeIntervalSince(start) >= 0, clock.now().timeIntervalSince(start) <= 180 else { throw ChatGPTAuthenticationError.timedOut }
            let parameters = try Self.callbackParameters(callback, redirect: redirect)
            guard Self.equal(parameters["state"] ?? "", state) else { throw ChatGPTAuthenticationError.stateMismatch }
            if parameters["error"] != nil { throw ChatGPTAuthenticationError.authorizationDenied }
            guard let code = parameters["code"], !code.isEmpty, code.utf8.count <= 4096 else { throw ChatGPTAuthenticationError.invalidCallback }
            let client = parameters["client_id"] ?? selected?.clientID ?? ""
            guard OpenAIAuth.validClient(client) else { throw ChatGPTAuthenticationError.registrationIncomplete }
            if let selected, client != selected.clientID { throw ChatGPTAuthenticationError.invalidCallback }
            let response = try await http.send(OpenAIAuth.request(OpenAIAuth.token, fields: ["grant_type": "authorization_code",
                "client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": OpenAIAuth.resource]))
            try ensureCurrent(attempt)
            let tokens = try parseTokens(response, retainedID: nil)
            let keys = try await fetchKeys()
            try ensureCurrent(attempt)
            let identity = try OpenAIIDTokenValidator().validate(tokens.idToken, jwks: keys, clientID: client, nonce: nonce, now: clock.now())
            if let selected, selected.identity.subject != identity.subject || selected.identity.issuer != identity.issuer { throw ChatGPTAuthenticationError.invalidIdentity }
            try ensureCurrent(attempt)
            try mutateStored(selectingUpdatedAccount: true) { candidate in
                if let selected {
                    guard candidate.accounts.first(where: { $0.clientID == client }) == selected else {
                        throw ChatGPTAuthenticationError.notSignedIn
                    }
                }
                var registration = ChatGPTAccountRegistration(clientID: client, identity: identity, tokens: tokens)
                registration.credentialGeneration = UUID()
                if let index = candidate.accounts.firstIndex(where: { $0.clientID == client }) {
                    guard candidate.accounts[index].identity.subject == identity.subject,
                          candidate.accounts[index].identity.issuer == identity.issuer else { throw ChatGPTAuthenticationError.invalidIdentity }
                    candidate.accounts[index] = registration
                } else {
                    guard candidate.accounts.count < 8 else { throw ChatGPTAuthenticationError.storageFailure }
                    candidate.accounts.append(registration)
                }
                candidate.activeClientID = client
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTAuthenticationError { throw error }
        catch { throw ChatGPTAuthenticationError.transportFailure }
    }

    public func cancelSignIn() { generation &+= 1; signInTask?.cancel(); browser.cancel(); updateStatus() }

    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard !storageBlocked else { throw ChatGPTAuthenticationError.storageFailure }
        guard !signingIn else { throw ChatGPTAuthenticationError.requestInProgress }
        if let refreshTask {
            let token = try await refreshTask.value
            try Task.checkCancellation()
            return token
        }
        // A different controller may have disconnected or rotated this session.
        try reloadSelectedRecords()
        guard let registration = activeRegistration, let tokens = registration.tokens else { throw ChatGPTAuthenticationError.notSignedIn }
        guard Self.hasPlanPermission(tokens) else { throw ChatGPTAuthenticationError.missingPlanPermission }
        if tokens.expiresAt.timeIntervalSince(clock.now()) > 60 { return tokens.accessToken }
        let attempt = generation
        let task = Task { @MainActor in try await self.refresh(registration, attempt: attempt) }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return token
    }

    public func signOut() throws {
        generation &+= 1
        signInTask?.cancel(); browser.cancel(); refreshTask?.cancel()
        let selectedClientID = records.activeClientID
        var old: ChatGPTAccountRegistration?
        try mutateStored { candidate in
            if let index = candidate.accounts.firstIndex(where: { $0.clientID == selectedClientID }) {
                old = candidate.accounts[index]
                candidate.accounts[index].tokens = nil
                candidate.accounts[index].credentialGeneration = UUID()
            }
        }
        updateStatus()
        guard let registration = old, let refresh = registration.tokens?.refreshToken else { return }
        setStatus("Signed out; remote revocation pending")
        let signoutGeneration = generation
        revocationTask?.cancel()
        revocationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var confirmed = false
            for attempt in 0..<2 {
                if Task.isCancelled { break }
                do {
                    try await self.verifyDiscovery()
                    let response = try await self.http.send(OpenAIAuth.request(OpenAIAuth.revoke,
                        fields: ["token": refresh, "token_type_hint": "refresh_token", "client_id": registration.clientID]))
                    if response.status == 200 { confirmed = true; break }
                    if response.status < 500 { break }
                } catch is CancellationError { break } catch {}
                if attempt == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            if self.generation == signoutGeneration {
                self.setStatus(confirmed ? "Signed out" : "Signed out; remote revocation was not confirmed. Disconnect Harness in ChatGPT Settings.")
            }
            if self.generation == signoutGeneration { self.revocationTask = nil }
        }
    }

    private func refresh(_ registration: ChatGPTAccountRegistration, attempt: UInt64) async throws -> String {
        guard let previous = registration.tokens else { throw ChatGPTAuthenticationError.notSignedIn }
        try await verifyDiscovery()
        try ensureCurrent(attempt)
        try store.acquireRefreshLock(clientID: registration.clientID)
        defer { store.releaseRefreshLock(clientID: registration.clientID) }
        // Re-read under the cross-process lock; another instance may have refreshed.
        let latest: ChatGPTStoredAccounts
        latest = try readStored()
        if let saved = latest.accounts.first(where: { $0.clientID == registration.clientID }), let tokens = saved.tokens,
           tokens.refreshToken != previous.refreshToken, tokens.expiresAt.timeIntervalSince(clock.now()) > 60 {
            adopt(latest, selectedClientID: registration.clientID); updateStatus()
            guard Self.hasPlanPermission(tokens) else { throw ChatGPTAuthenticationError.missingPlanPermission }
            return tokens.accessToken
        }
        guard latest.accounts.first(where: { $0.clientID == registration.clientID }) == registration else {
            adopt(latest, selectedClientID: registration.clientID); updateStatus()
            throw ChatGPTAuthenticationError.notSignedIn
        }
        let response: OAuthHTTPResponse
        do { response = try await http.send(OpenAIAuth.request(OpenAIAuth.token, fields: ["grant_type": "refresh_token", "client_id": registration.clientID,
            "refresh_token": previous.refreshToken, "resource": OpenAIAuth.resource])) }
        catch is CancellationError { throw CancellationError() } catch { throw ChatGPTAuthenticationError.transportFailure }
        try ensureCurrent(attempt)
        if Self.isTerminalRefreshFailure(response) {
            try mutateStored { candidate in
                guard let index = candidate.accounts.firstIndex(where: { $0.clientID == registration.clientID }),
                      candidate.accounts[index] == registration else { throw ChatGPTAuthenticationError.notSignedIn }
                candidate.accounts[index].tokens = nil
                candidate.accounts[index].credentialGeneration = UUID()
            }
            updateStatus()
            throw ChatGPTAuthenticationError.notSignedIn
        }
        if response.status >= 500 || response.status == 408 || response.status == 429 { throw ChatGPTAuthenticationError.transportFailure }
        let tokens = try parseTokens(response, retainedID: previous.idToken)
        if tokens.idToken != previous.idToken {
            let keys = try await fetchKeys()
            let identity = try OpenAIIDTokenValidator().validate(tokens.idToken, jwks: keys, clientID: registration.clientID, nonce: nil, now: clock.now())
            guard identity.subject == registration.identity.subject else { throw ChatGPTAuthenticationError.invalidIdentity }
        }
        try ensureCurrent(attempt)
        try mutateStored { candidate in
            guard let index = candidate.accounts.firstIndex(where: { $0.clientID == registration.clientID }),
                  candidate.accounts[index] == registration else { throw ChatGPTAuthenticationError.notSignedIn }
            candidate.accounts[index].tokens = tokens
            candidate.accounts[index].credentialGeneration = UUID()
        }
        updateStatus()
        guard Self.hasPlanPermission(tokens) else { throw ChatGPTAuthenticationError.missingPlanPermission }
        return tokens.accessToken
    }

    private static func hasPlanPermission(_ tokens: ChatGPTTokens) -> Bool {
        Set(["resource.invoke", "chatgpt.tokens.use.direct"]).isSubset(of: Set(tokens.scopes))
    }
    private static func isTerminalRefreshFailure(_ response: OAuthHTTPResponse) -> Bool {
        guard (400...499).contains(response.status), response.data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let error = object["error"] as? String else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(error)
    }

    private func parseTokens(_ response: OAuthHTTPResponse, retainedID: String?) throws -> ChatGPTTokens {
        guard response.status == 200, response.data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let access = object["access_token"] as? String, Self.validToken(access),
              let refresh = object["refresh_token"] as? String, Self.validToken(refresh),
              let id = (object["id_token"] as? String) ?? retainedID, Self.validToken(id),
              object["token_type"] as? String == "Bearer", let lifetime = object["expires_in"] as? NSNumber,
              CFGetTypeID(lifetime) != CFBooleanGetTypeID(), lifetime.doubleValue.isFinite,
              (1...86_400).contains(lifetime.doubleValue), let scope = object["scope"] as? String, scope.utf8.count <= 4096 else {
            throw ChatGPTAuthenticationError.malformedResponse
        }
        let scopes = Set(scope.split(separator: " ").map(String.init))
        guard scopes.count <= 128, scopes.allSatisfy({ Self.validScope($0) }) else { throw ChatGPTAuthenticationError.malformedResponse }
        return ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: id, scopes: scopes.sorted(), expiresAt: clock.now().addingTimeInterval(lifetime.doubleValue))
    }
    private static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    private func verifyDiscovery() async throws {
        let response: OAuthHTTPResponse
        do { response = try await http.send(OpenAIAuth.request(OpenAIAuth.discovery)) }
        catch is CancellationError { throw CancellationError() } catch { throw ChatGPTAuthenticationError.transportFailure }
        guard response.status == 200, response.data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              object["issuer"] as? String == OpenAIAuth.issuer,
              object["authorization_endpoint"] as? String == OpenAIAuth.authorize.absoluteString,
              object["token_endpoint"] as? String == OpenAIAuth.token.absoluteString,
              object["jwks_uri"] as? String == OpenAIAuth.jwks.absoluteString,
              object["revocation_endpoint"] as? String == OpenAIAuth.revoke.absoluteString else { throw ChatGPTAuthenticationError.malformedResponse }
    }
    private func fetchKeys() async throws -> Data {
        let response = try await http.send(OpenAIAuth.request(OpenAIAuth.jwks))
        guard response.status == 200, response.data.count <= 262_144 else { throw ChatGPTAuthenticationError.invalidIdentity }
        return response.data
    }
    private func ensureCurrent(_ expected: UInt64) throws { try Task.checkCancellation(); guard generation == expected else { throw CancellationError() } }
    private func adopt(_ latest: ChatGPTStoredAccounts, selectedClientID: String?) {
        records = latest
        // Another instance selecting an account does not silently switch this controller.
        records.activeClientID = selectedClientID
    }
    private func readStored() throws -> ChatGPTStoredAccounts {
        do { let latest = try store.read(); try validateStored(latest); return latest }
        catch { storageBlocked = true; updateStatus(); throw ChatGPTAuthenticationError.storageFailure }
    }
    private func reloadSelectedRecords() throws {
        let selected = records.activeClientID
        adopt(try readStored(), selectedClientID: selected)
        updateStatus()
    }
    private func mutateStored(selectingUpdatedAccount: Bool = false,
                              _ mutation: (inout ChatGPTStoredAccounts) throws -> Void) throws {
        guard !storageBlocked else { throw ChatGPTAuthenticationError.storageFailure }
        let selected = records.activeClientID
        var observed: ChatGPTStoredAccounts?
        do {
            let committed = try store.transaction { candidate in
                try validateStored(candidate)
                observed = candidate
                try mutation(&candidate)
                try validateStored(candidate)
            }
            adopt(committed, selectedClientID: selectingUpdatedAccount ? committed.activeClientID : selected)
        } catch {
            if let observed { adopt(observed, selectedClientID: selected); updateStatus() }
            if let authError = error as? ChatGPTAuthenticationError, authError != .storageFailure { throw authError }
            storageBlocked = true; updateStatus(); throw ChatGPTAuthenticationError.storageFailure
        }
    }
    private func validateStored(_ candidate: ChatGPTStoredAccounts) throws {
        guard candidate.accounts.count <= 8, Set(candidate.accounts.map(\.clientID)).count == candidate.accounts.count else { throw ChatGPTAuthenticationError.storageFailure }
        for registration in candidate.accounts {
            guard OpenAIAuth.validClient(registration.clientID), registration.identity.issuer == OpenAIAuth.issuer,
                  !registration.identity.subject.isEmpty, registration.identity.subject.utf8.count <= 512 else { throw ChatGPTAuthenticationError.storageFailure }
            if let tokens = registration.tokens {
                guard Self.validToken(tokens.accessToken), Self.validToken(tokens.refreshToken), Self.validToken(tokens.idToken),
                      tokens.expiresAt.timeIntervalSince1970.isFinite,
                      tokens.scopes.count <= 128, tokens.scopes.allSatisfy({ Self.validScope($0) }) else { throw ChatGPTAuthenticationError.storageFailure }
            }
        }
        if let selected = candidate.activeClientID, !candidate.accounts.contains(where: { $0.clientID == selected }) { throw ChatGPTAuthenticationError.storageFailure }
    }
    private func updateStatus() {
        if storageBlocked { setStatus("Saved account unavailable; use Continue with ChatGPT to unlock or retry") }
        else if let tokens = activeRegistration?.tokens {
            setStatus(Self.hasPlanPermission(tokens) ? "Connected to ChatGPT" : "Connected to ChatGPT; plan permission is required. Continue with ChatGPT to grant permission.")
        } else { setStatus("Signed out") }
    }
    private func setStatus(_ value: String) { accountStatus = value; onStatusChanged?() }
    private static func validRedirect(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.path == "/auth/callback" && url.port.map { (1...65535).contains($0) } == true && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    private static func callbackParameters(_ callback: URL, redirect: URL) throws -> [String: String] {
        guard callback.absoluteString.utf8.count <= 16_384, callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.path == redirect.path, callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else { throw ChatGPTAuthenticationError.invalidCallback }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else { throw ChatGPTAuthenticationError.invalidCallback }
            values[item.name] = value
        }
        return values
    }
    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = [UInt8](lhs.utf8), b = [UInt8](rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
