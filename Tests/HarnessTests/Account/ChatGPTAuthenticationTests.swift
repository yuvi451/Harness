import Foundation
import CryptoKit
import Security
import XCTest
@testable import HarnessEmitter
import HarnessCore

final class ChatGPTAuthenticationTests: XCTestCase {
    @MainActor func testSavedAccountSelectionKeepsRegistrationsAndCredentialsSeparate() async throws {
        let first = try AuthFixture(); let initial = first.controller(); try await initial.signIn()
        let second = try AuthFixture(store:first.store); second.browser.clientID = "oaiapp_second"
        let controller = second.controller(); try await controller.signIn(newAccount:true)
        let saved = first.store.records
        XCTAssertEqual(controller.accountChoices.count,2)
        XCTAssertEqual(Set(controller.accountChoices.map(\.label)).count,2,"Same-email registrations need distinct labels")
        try controller.selectAccount("oaiapp_fixture")
        XCTAssertEqual(controller.selectedAccountID,"oaiapp_fixture")
        XCTAssertEqual(first.store.records.activeClientID,"oaiapp_fixture")
        XCTAssertEqual(first.store.records.accounts,saved.accounts)
        XCTAssertThrowsError(try controller.selectAccount("unknown"))
        XCTAssertEqual(controller.selectedAccountID,"oaiapp_fixture")
        XCTAssertEqual(second.controller().selectedAccountID,"oaiapp_fixture")
        try controller.signOut()
        XCTAssertFalse(controller.isConnected)
        try controller.selectAccount("oaiapp_second")
        XCTAssertTrue(controller.isConnected)
        XCTAssertNotNil(first.store.records.accounts.first { $0.clientID == "oaiapp_second" }?.tokens)
    }
    @MainActor func testAccountSelectionCannotRaceTokenRotation() async throws {
        let fixture = try AuthFixture(); let controller = fixture.controller(); try await controller.signIn()
        fixture.clock.value = fixture.clock.value.addingTimeInterval(3590); fixture.http.suspendRefresh = true
        let pending = Task { try await controller.accessToken() }
        try await waitForTest { fixture.http.refreshStarted }
        XCTAssertThrowsError(try controller.selectAccount("oaiapp_fixture")) { XCTAssertEqual($0 as? ChatGPTAuthenticationError,.requestInProgress) }
        fixture.http.releaseRefresh(); _ = try await pending.value
        XCTAssertTrue(controller.isConnected)
    }
    @MainActor func testCancelledStorageAuthorizationCannotReconnectOrStartDuplicateSignIn() async throws {
        let fixture = try AuthFixture()
        try await fixture.controller().signIn()
        fixture.store.failReads = true
        let controller = fixture.controller()
        fixture.store.failReads = false
        var waiting: CheckedContinuation<ChatGPTStoredAccounts, Error>?
        fixture.store.authorize = { try await withCheckedThrowingContinuation { waiting = $0 } }
        let pending = Task { try await controller.signIn() }
        try await waitForTest { waiting != nil }
        do { try await controller.signIn(); XCTFail("Overlapping storage authorization") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .requestInProgress) }
        controller.cancelSignIn(); pending.cancel()
        waiting?.resume(returning: fixture.store.records)
        do { try await pending.value; XCTFail("Cancelled account restored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(controller.isConnected)
        fixture.store.authorize = nil
        try await controller.signIn()
        XCTAssertTrue(controller.isConnected)
    }
    @MainActor func testExplicitSignInRecoversReadableSavedAccountWithoutOpeningBrowser() async throws {
        let fixture = try AuthFixture()
        try await fixture.controller().signIn()
        fixture.store.failReads = true
        let controller = fixture.controller()
        XCTAssertFalse(controller.isConnected)
        fixture.store.failReads = false
        let opened = fixture.browser.opened.count
        try await controller.signIn()
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(fixture.browser.opened.count, opened)
        XCTAssertEqual(fixture.store.authorizedReads, 1)
        let token = try await controller.accessToken()
        XCTAssertEqual(token, "access-fixture")
    }

    @MainActor func testStorageRecoveryNeverOverwritesCorruptRecords() async throws {
        let fixture = try AuthFixture()
        fixture.store.failReads = true
        let controller = fixture.controller()
        fixture.store.failReads = false
        fixture.store.records.activeClientID = "missing-client"
        do { try await controller.signIn(); XCTFail("Corrupt storage accepted") } catch {}
        XCTAssertTrue(fixture.browser.opened.isEmpty)
        XCTAssertEqual(fixture.store.replaceCount, 0)
    }

    @MainActor func testHostIdentityMustBeDurablyStoredBeforeRegistrationCanUseIt() throws {
        let preferences = HostPreferencesStub()
        let host = UserDefaultsChatGPTHost(preferences: preferences)
        XCTAssertThrowsError(try host.hostID()) { error in
            XCTAssertEqual(error as? ChatGPTAuthenticationError, .storageFailure)
        }
        XCTAssertThrowsError(try host.hostID()) { error in
            XCTAssertEqual(error as? ChatGPTAuthenticationError, .storageFailure)
        }
        XCTAssertGreaterThan(preferences.flushCount, 0)
    }

    @MainActor func testStoredHostIdentityIsReusedWithoutGeneratingAnotherIdentity() throws {
        let preferences = HostPreferencesStub()
        preferences.value = "urn:uuid:11111111-1111-1111-1111-111111111111"
        let host = UserDefaultsChatGPTHost(preferences: preferences)
        XCTAssertEqual(try host.hostID(), "urn:uuid:11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(preferences.flushCount, 0)
    }

    @MainActor func testNativeLoopbackReleasesRejectedConnectionsBeforeAcceptingCallback() async throws {
        let opened = expectation(description: "Synthetic browser hook invoked")
        let browser = LoopbackOAuthBrowser(openAuthorization: { _ in opened.fulfill(); return true }, callbackTimeoutSeconds: 3)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        let session = URLSession(configuration: configuration)
        defer { browser.cancel(); session.invalidateAndCancel() }
        let redirect = try await browser.prepareCallback()
        let callback = Task { try await browser.authenticate(authorizationURL: URL(string: "https://example.invalid/?state=synthetic-state")!, redirectURI: redirect) }
        await fulfillment(of: [opened], timeout: 1)
        var unrelated = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        unrelated.path = "/favicon.ico"
        for _ in 0..<12 { _ = try? await session.data(from: unrelated.url!) }
        var rejected = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        rejected.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "wrong")]
        _ = try? await session.data(from: rejected.url!)
        rejected.queryItems = [URLQueryItem(name: "state", value: "synthetic-state"), URLQueryItem(name: "state", value: "duplicate")]
        _ = try? await session.data(from: rejected.url!)
        var expected = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        expected.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"), URLQueryItem(name: "state", value: "synthetic-state")]
        _ = try? await session.data(from: expected.url!)
        do {
            let received = try await callback.value
            XCTAssertEqual(received, expected.url!)
        } catch {
            XCTFail("Synthetic callback was blocked after unrelated connections: \(type(of: error))")
        }
    }

    func testCancelledAccessTokenRequestCannotReturnCachedCredential() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller(); try await controller.signIn()
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await controller.accessToken()
        }
        do { _ = try await pending.value; XCTFail("Cancelled caller received a credential") }
        catch { XCTAssertTrue(error is CancellationError) }
        await MainActor.run { XCTAssertEqual(fixture.http.refreshCount, 0) }
    }

    func testNativeHTTPClientCancelsBeforeHeadersAndDuringBody() async throws {
        for headers in [false, true] {
            let fixture = OAuthTransportFixture(headers: headers)
            defer { fixture.close() }
            let http = await EphemeralOAuthHTTPClient(session: fixture.session)
            let pending = Task { try await http.send(URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)) }
            await fulfillment(of: [fixture.started], timeout: 2)
            pending.cancel()
            do { _ = try await pending.value; XCTFail("Cancelled OAuth transport succeeded") } catch {}
            await fulfillment(of: [fixture.stopped], timeout: 2)
        }
    }

    func testNativeHTTPClientStopsRejectedOversizedResponse() async throws {
        let fixture = OAuthTransportFixture(headers: true, oversized: true)
        defer { fixture.close() }
        let http = await EphemeralOAuthHTTPClient(session: fixture.session)
        do {
            _ = try await http.send(URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!))
            XCTFail("Oversized response accepted")
        } catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .transportFailure) }
        await fulfillment(of: [fixture.stopped], timeout: 2)
    }

    func testPKCEUsesRFC7636S256Vector() {
        XCTAssertEqual(OAuthPKCE.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testInitDoesNotOpenBrowserOrStartNetwork() async throws {
        try await MainActor.run {
            let fixture = try AuthFixture()
            let controller = fixture.controller()
            XCTAssertFalse(controller.hasAccount)
            XCTAssertEqual(fixture.browser.opened.count, 0)
            XCTAssertEqual(fixture.http.requests.count, 0)
        }
    }

    func testDynamicRegistrationBindsIssuedClientNoncePKCEAndScopes() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        try await controller.signIn()
        try await MainActor.run {
            XCTAssertTrue(controller.hasAccount)
            let authorization = try XCTUnwrap(fixture.browser.opened.first)
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["client_id"], "dynamic_agent_client")
            XCTAssertEqual(query["agent_name_hint"], "Harness")
            XCTAssertEqual(query["ext_agent_host_id"], "urn:uuid:11111111-1111-1111-1111-111111111111")
            XCTAssertEqual(query["resource"], "https://api.openai.com/v1")
            XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:54321/auth/callback")
            XCTAssertEqual(query["code_challenge_method"], "S256")
            let request = try XCTUnwrap(fixture.http.requests.first { $0.url?.path.hasSuffix("/token") == true })
            let form = try XCTUnwrap(String(data: request.httpBody!, encoding: .utf8))
            XCTAssertTrue(form.contains("client_id=oaiapp_fixture"))
            XCTAssertFalse(form.contains("dynamic_agent_client"))
            XCTAssertTrue(form.contains("code_verifier="))
            XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback"))
            XCTAssertEqual(fixture.store.records.accounts.first?.identity.subject, "subject-fixture")
        }
        let access = try await controller.accessToken()
        XCTAssertEqual(access, "access-fixture")
    }

    func testWrongStateDuplicateParametersAndCallbackHostCannotExchangeCode() async throws {
        for mode in [AuthBrowserStub.Mode.wrongState, .duplicateCode, .wrongHost, .wrongPath, .missingClient, .denied] {
            let fixture = try await MainActor.run { () throws -> AuthFixture in
                let f = try AuthFixture(); f.browser.mode = mode; return f
            }
            let controller = await fixture.controller()
            do { try await controller.signIn(); XCTFail("Invalid callback accepted") } catch {}
            await MainActor.run {
                XCTAssertFalse(controller.hasAccount)
                XCTAssertFalse(fixture.http.requests.contains { $0.url?.path.hasSuffix("/token") == true })
                XCTAssertEqual(fixture.store.records.accounts.count, 0)
                XCTAssertGreaterThan(fixture.browser.cancelCount, 0)
            }
        }
    }

    func testJWTRejectsBadSignatureIssuerAudienceNonceExpiryAndSubject() throws {
        let fixture = try RSAJWTFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["iss"] = "https://attacker.invalid" }, { $0["aud"] = "other-client" },
            { $0["nonce"] = "other-nonce" }, { $0["exp"] = 1_799_999_000 },
            { $0["iat"] = 1_800_001_000 }, { $0["sub"] = "" },
            { $0["aud"] = ["oaiapp_fixture", "other-client"]; $0["azp"] = "other-client" }
        ]
        for mutation in mutations {
            var claims = fixture.claims(nonce: "expected-nonce"); mutation(&claims)
            XCTAssertThrowsError(try OpenAIIDTokenValidator().validate(fixture.token(claims: claims), jwks: fixture.jwks,
                clientID: "oaiapp_fixture", nonce: "expected-nonce", now: now))
        }
        let valid = try fixture.token(claims: fixture.claims(nonce: "expected-nonce"))
        let pieces = valid.split(separator: ".")
        let forged = "\(pieces[0]).\(pieces[1]).\(Data(repeating: 0, count: 256).base64URL())"
        XCTAssertThrowsError(try OpenAIIDTokenValidator().validate(forged, jwks: fixture.jwks, clientID: "oaiapp_fixture", nonce: "expected-nonce", now: now))
        XCTAssertThrowsError(try OpenAIIDTokenValidator().validate(valid, jwks: Data("{\"keys\":[]}".utf8), clientID: "oaiapp_fixture", nonce: "expected-nonce", now: now))
        let identity = try OpenAIIDTokenValidator().validate(valid, jwks: fixture.jwks, clientID: "oaiapp_fixture", nonce: "expected-nonce", now: now)
        XCTAssertEqual(identity.subject, "subject-fixture")
    }

    func testIdentityFailureDoesNotReplaceExistingAccount() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        try await controller.signIn()
        await MainActor.run { fixture.http.wrongSubject = true }
        do { try await controller.signIn(); XCTFail("Invalid account replacement accepted") } catch {}
        await MainActor.run {
            XCTAssertTrue(controller.hasAccount)
            XCTAssertEqual(fixture.store.records.accounts.first?.identity.subject, "subject-fixture")
            XCTAssertEqual(fixture.store.records.accounts.first?.tokens?.accessToken, "access-fixture")
            let query = URLComponents(url: fixture.browser.opened.last!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "oaiapp_fixture")
            XCTAssertNil(query.first { $0.name == "agent_name_hint" })
        }
    }

    func testMissingPlanScopeRetainsIdentityButDisablesAccessAndRequestsExplicitConsent() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        await MainActor.run { fixture.http.omitDirectScope = true }
        try await controller.signIn()
        await MainActor.run {
            XCTAssertTrue(controller.hasAccount)
            XCTAssertTrue(controller.accountStatus.contains("permission"))
            XCTAssertEqual(fixture.store.records.accounts.first?.identity.subject, "subject-fixture")
        }
        do { _ = try await controller.accessToken(); XCTFail("Unconsented plan token returned") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .missingPlanPermission) }
        await MainActor.run { fixture.http.omitDirectScope = false }
        try await controller.signIn()
        await MainActor.run {
            let query = URLComponents(url: fixture.browser.opened.last!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "prompt" }?.value, "consent")
        }
        let access = try await controller.accessToken()
        XCTAssertEqual(access, "access-fixture")
    }

    func testTerminalRefreshErrorClearsTokensWhileTransientFailureRetainsThem() async throws {
        for terminal in [false, true] {
            let fixture = try await MainActor.run { try AuthFixture() }
            let controller = await fixture.controller(); try await controller.signIn()
            await MainActor.run {
                fixture.clock.value = fixture.clock.value.addingTimeInterval(3_590)
                fixture.http.refreshError = terminal ? "refresh_token_reused" : "server_error"
            }
            do { _ = try await controller.accessToken(); XCTFail("Failed refresh yielded access") } catch {}
            await MainActor.run {
                XCTAssertEqual(controller.hasAccount, !terminal)
                XCTAssertEqual(fixture.store.records.accounts.first?.clientID, "oaiapp_fixture")
                XCTAssertEqual(fixture.store.records.accounts.first?.tokens == nil, terminal)
            }
        }
    }

    func testStatusCallbackReportsConnectedAndDisconnectedState() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        let statuses = await MainActor.run { AuthStatusRecorder() }
        await MainActor.run { controller.onStatusChanged = { statuses.values.append(controller.accountStatus) } }
        try await controller.signIn()
        try await MainActor.run {
            try controller.signOut()
            XCTAssertTrue(statuses.values.contains("Connected to ChatGPT"))
            XCTAssertTrue(statuses.values.contains("Signed out"))
        }
    }

    func testRefreshRotatesTokensInOneRecordAndConcurrentCallersShareIt() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        try await controller.signIn()
        await MainActor.run { fixture.clock.value = fixture.clock.value.addingTimeInterval(3_590) }
        async let first = controller.accessToken()
        async let second = controller.accessToken()
        let values = try await [first, second]
        XCTAssertEqual(values, ["access-refreshed", "access-refreshed"])
        await MainActor.run {
            XCTAssertEqual(fixture.http.refreshCount, 1)
            XCTAssertEqual(fixture.store.records.accounts.first?.tokens?.refreshToken, "refresh-rotated")
            XCTAssertEqual(fixture.store.records.accounts.first?.tokens?.accessToken, "access-refreshed")
            XCTAssertEqual(fixture.store.replaceCount, 2)
        }
    }

    func testStorageFailureDoesNotReturnNewUnpersistedToken() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller(); try await controller.signIn()
        await MainActor.run {
            fixture.clock.value = fixture.clock.value.addingTimeInterval(3_590)
            fixture.store.failWrites = true
        }
        do { _ = try await controller.accessToken(); XCTFail("Unpersisted rotated credential used") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .storageFailure) }
    }

    func testOtherControllerDisconnectRejectsCachedValidToken() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let first = await fixture.controller(); try await first.signIn()
        let second = await fixture.controller()
        try await MainActor.run { try second.signOut() }
        do { _ = try await first.accessToken(); XCTFail("Disconnected cached credential returned") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .notSignedIn) }
        await MainActor.run { XCTAssertFalse(first.hasAccount); XCTAssertEqual(fixture.http.refreshCount, 0) }
    }

    func testOtherControllerDisconnectPreventsLateRefreshResurrection() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let first = await fixture.controller(); try await first.signIn()
        let second = await fixture.controller()
        await MainActor.run {
            fixture.clock.value = fixture.clock.value.addingTimeInterval(3_590)
            fixture.http.suspendRefresh = true
        }
        let pending = Task { try await first.accessToken() }
        try await waitForTest { await fixture.http.refreshStarted }
        try await MainActor.run { try second.signOut(); fixture.http.releaseRefresh() }
        do { _ = try await pending.value; XCTFail("Late refresh restored disconnected credentials") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .notSignedIn) }
        await MainActor.run { XCTAssertTrue(fixture.store.records.accounts.first?.tokens == nil); XCTAssertFalse(first.hasAccount) }
    }

    func testRefreshPreservesConcurrentDifferentClientRotationAndActiveSelection() async throws {
        let firstFixture = try await MainActor.run { try AuthFixture() }
        let first = await firstFixture.controller(); try await first.signIn()
        let secondFixture = try await MainActor.run { () throws -> AuthFixture in
            let fixture = try AuthFixture(store: firstFixture.store)
            fixture.browser.clientID = "oaiapp_second"
            return fixture
        }
        let second = await secondFixture.controller(); try await second.signIn(newAccount: true)
        await MainActor.run {
            firstFixture.clock.value = firstFixture.clock.value.addingTimeInterval(3_590)
            secondFixture.clock.value = secondFixture.clock.value.addingTimeInterval(3_590)
            firstFixture.http.suspendRefresh = true
        }
        let pending = Task { try await first.accessToken() }
        try await waitForTest { await firstFixture.http.refreshStarted }
        _ = try await second.accessToken()
        await MainActor.run { firstFixture.http.releaseRefresh() }
        _ = try await pending.value
        await MainActor.run {
            XCTAssertEqual(firstFixture.store.records.accounts.count, 2)
            XCTAssertEqual(firstFixture.store.records.accounts.first { $0.clientID == "oaiapp_second" }?.tokens?.refreshToken, "refresh-rotated")
            XCTAssertEqual(firstFixture.store.records.accounts.first { $0.clientID == "oaiapp_fixture" }?.tokens?.refreshToken, "refresh-rotated")
            XCTAssertEqual(firstFixture.store.records.activeClientID, "oaiapp_second")
        }
    }

    func testLateSignInPreservesDifferentClientRegistration() async throws {
        let firstFixture = try await MainActor.run { try AuthFixture() }
        let first = await firstFixture.controller()
        await MainActor.run { firstFixture.http.suspendExchange = true }
        let pending = Task { try await first.signIn() }
        try await waitForTest { await firstFixture.http.exchangeStarted }
        let secondFixture = try await MainActor.run { () throws -> AuthFixture in
            let fixture = try AuthFixture(store: firstFixture.store); fixture.browser.clientID = "oaiapp_second"; return fixture
        }
        let second = await secondFixture.controller(); try await second.signIn(newAccount: true)
        await MainActor.run { firstFixture.http.releaseExchange() }
        try await pending.value
        await MainActor.run {
            XCTAssertEqual(Set(firstFixture.store.records.accounts.map(\.clientID)), Set(["oaiapp_fixture", "oaiapp_second"]))
        }
    }

    func testCancellationAndTimeoutCleanListenerWithoutSavingTokens() async throws {
        for mode in [AuthBrowserStub.Mode.cancelled, .timedOut] {
            let fixture = try await MainActor.run { () throws -> AuthFixture in let f = try AuthFixture(); f.browser.mode = mode; return f }
            let controller = await fixture.controller()
            do { try await controller.signIn(); XCTFail("Cancelled sign-in succeeded") } catch {}
            await MainActor.run {
                XCTAssertFalse(controller.hasAccount)
                XCTAssertEqual(fixture.store.replaceCount, 0)
                XCTAssertGreaterThan(fixture.browser.cancelCount, 0)
            }
        }
    }

    func testSignOutClearsTokensRetainsClientMappingAndAttemptsRevocation() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller(); try await controller.signIn()
        try await MainActor.run {
            try controller.signOut()
            XCTAssertFalse(controller.hasAccount)
            XCTAssertTrue(fixture.store.records.accounts.first?.tokens == nil)
            XCTAssertEqual(fixture.store.records.accounts.first?.clientID, "oaiapp_fixture")
        }
        for _ in 0..<100 {
            if await fixture.http.revocationCount > 0 { break }
            await Task.yield()
        }
        await MainActor.run { XCTAssertEqual(fixture.http.revocationCount, 1) }
        do { _ = try await controller.accessToken(); XCTFail("Signed-out token returned") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .notSignedIn) }
    }

    func testErrorsNeverExposeCredentialsCodesOrURLs() {
        for error in [ChatGPTAuthenticationError.invalidCallback, .invalidIdentity, .transportFailure, .storageFailure] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("access-fixture")); XCTAssertFalse(text.contains("refresh-fixture"))
            XCTAssertFalse(text.contains("authorization-code")); XCTAssertFalse(text.contains("code="))
        }
    }

    func testExplicitCancellationCancelsInFlightExchangeAndPreventsCommit() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        await MainActor.run { fixture.http.suspendExchange = true }
        let pending = Task { try await controller.signIn() }
        try await waitForTest { await fixture.http.exchangeStarted }
        await MainActor.run { controller.cancelSignIn(); fixture.http.releaseExchange() }
        do { try await pending.value; XCTFail("Cancelled exchange persisted tokens") } catch {}
        await MainActor.run {
            XCTAssertTrue(fixture.http.exchangeWasCancelled)
            XCTAssertFalse(controller.hasAccount)
            XCTAssertEqual(fixture.store.replaceCount, 0)
        }
    }

    func testSignOutInvalidatesLateExchangeAndConcurrentSignInIsRejected() async throws {
        let fixture = try await MainActor.run { try AuthFixture() }
        let controller = await fixture.controller()
        await MainActor.run { fixture.http.suspendExchange = true }
        let pending = Task { try await controller.signIn() }
        try await waitForTest { await fixture.http.exchangeStarted }
        do { try await controller.signIn(); XCTFail("Concurrent sign-in accepted") }
        catch { XCTAssertEqual(error as? ChatGPTAuthenticationError, .requestInProgress) }
        try await MainActor.run { try controller.signOut(); fixture.http.releaseExchange() }
        do { try await pending.value; XCTFail("Disconnected exchange persisted credentials") } catch {}
        await MainActor.run {
            XCTAssertFalse(controller.hasAccount)
            XCTAssertTrue(fixture.store.records.accounts.isEmpty)
        }
    }
}

@MainActor private final class AuthStatusRecorder { var values: [String] = [] }

@MainActor private final class HostPreferencesStub: Preferences {
    var value: String?
    var flushCount = 0
    func object(forKey key: String) -> Any? { key == "chatgptHostID" ? value : nil }
    func set(_ value: Any, forKey key: String) { if key == "chatgptHostID" { self.value = value as? String } }
    func removeObject(forKey key: String) { if key == "chatgptHostID" { value = nil } }
    func flush() throws { flushCount += 1; throw SettingsPersistenceError.saveFailed }
}

@MainActor private final class AuthFixture {
    let jwt: RSAJWTFixture
    let browser = AuthBrowserStub()
    let store: AuthStoreStub
    let clock = AuthClockStub()
    let random = AuthRandomStub()
    let http: AuthHTTPStub
    init(store: AuthStoreStub? = nil) throws { self.store = store ?? AuthStoreStub(); jwt = try RSAJWTFixture(); http = AuthHTTPStub(jwt: jwt, browser: browser, clock: clock) }
    func controller() -> ChatGPTAccountController {
        ChatGPTAccountController(http: http, browser: browser, store: store, host: AuthHostStub(), random: random, clock: clock)
    }
}
@MainActor private final class AuthStoreStub: ChatGPTAccountStore {
    var records = ChatGPTStoredAccounts()
    var replaceCount = 0
    var failWrites = false
    var failReads = false
    var authorizedReads = 0
    var authorize: (() async throws -> ChatGPTStoredAccounts)?
    func readAuthorized() async throws -> ChatGPTStoredAccounts {
        authorizedReads += 1
        if let authorize { return try await authorize() }
        return try read()
    }
    func read() throws -> ChatGPTStoredAccounts {
        if failReads { throw ChatGPTAuthenticationError.storageFailure }
        return records
    }
    func replace(_ records: ChatGPTStoredAccounts) throws {
        if failWrites { throw ChatGPTAuthenticationError.storageFailure }
        self.records = records; replaceCount += 1
    }
}
@MainActor private struct AuthHostStub: ChatGPTHostIdentifying {
    func hostID() throws -> String { "urn:uuid:11111111-1111-1111-1111-111111111111" }
}
@MainActor private final class AuthClockStub: OAuthClock {
    var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { value }
}
@MainActor private final class AuthRandomStub: OAuthRandomGenerating {
    var seed: UInt8 = 0
    func bytes(count: Int) throws -> Data { seed += 1; return Data(repeating: seed, count: count) }
}
@MainActor private final class AuthBrowserStub: OAuthBrowserAuthenticating {
    enum Mode { case valid, wrongState, duplicateCode, wrongHost, wrongPath, missingClient, denied, cancelled, timedOut }
    var mode: Mode = .valid
    var opened: [URL] = []
    var cancelCount = 0
    var nonce = ""
    var clientID = "oaiapp_fixture"
    func prepareCallback() async throws -> URL { URL(string: "http://127.0.0.1:54321/auth/callback")! }
    func authenticate(authorizationURL: URL, redirectURI: URL) async throws -> URL {
        opened.append(authorizationURL)
        if mode == .cancelled { throw CancellationError() }
        if mode == .timedOut { throw ChatGPTAuthenticationError.timedOut }
        let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        nonce = query.first { $0.name == "nonce" }!.value!
        let state = mode == .wrongState ? "wrong" : query.first { $0.name == "state" }!.value!
        let host = mode == .wrongHost ? "localhost" : "127.0.0.1"
        let path = mode == .wrongPath ? "/callback" : "/auth/callback"
        let code = mode == .denied ? "error=access_denied" : "code=authorization-code"
        let client = mode == .missingClient ? "" : "&client_id=\(clientID)"
        return URL(string: "http://\(host):54321\(path)?\(code)&state=\(state)\(client)\(mode == .duplicateCode ? "&code=another" : "")")!
    }
    func cancel() { cancelCount += 1 }
}
@MainActor private final class AuthHTTPStub: OAuthHTTPClient {
    let jwt: RSAJWTFixture
    let browser: AuthBrowserStub
    let clock: AuthClockStub
    var requests: [URLRequest] = []
    var omitDirectScope = false
    var wrongSubject = false
    var refreshCount = 0
    var refreshError: String?
    var revocationCount = 0
    var suspendExchange = false
    var exchangeStarted = false
    var exchangeWasCancelled = false
    var exchangeContinuation: CheckedContinuation<Void, Never>?
    var suspendRefresh = false
    var refreshStarted = false
    var refreshContinuation: CheckedContinuation<Void, Never>?
    init(jwt: RSAJWTFixture, browser: AuthBrowserStub, clock: AuthClockStub) { self.jwt = jwt; self.browser = browser; self.clock = clock }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        let url = request.url!
        if url.path == "/.well-known/openid-configuration" {
            return OAuthHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: [
                "issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"]))
        }
        if url.path == "/.well-known/jwks.json" { return OAuthHTTPResponse(status: 200, data: jwt.jwks) }
        if url.path.hasSuffix("/revoke") { revocationCount += 1; return OAuthHTTPResponse(status: 200, data: Data()) }
        let refresh = String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains("grant_type=refresh_token")
        if !refresh && suspendExchange {
            exchangeStarted = true
            await withCheckedContinuation { exchangeContinuation = $0 }
            exchangeWasCancelled = Task.isCancelled
        }
        if refresh {
            refreshCount += 1; await Task.yield()
            if suspendRefresh {
                refreshStarted = true
                await withCheckedContinuation { refreshContinuation = $0 }
            }
            if let refreshError {
                return OAuthHTTPResponse(status: refreshError == "server_error" ? 503 : 400,
                    data: try JSONSerialization.data(withJSONObject: ["error": refreshError]))
            }
        }
        var claims = jwt.claims(nonce: browser.nonce)
        claims["aud"] = browser.clientID
        claims["iat"] = Int(clock.value.timeIntervalSince1970); claims["exp"] = Int(clock.value.timeIntervalSince1970) + 3600
        if wrongSubject { claims["sub"] = "wrong-subject" }
        let response: [String: Any] = ["access_token": refresh ? "access-refreshed" : "access-fixture",
            "refresh_token": refresh ? "refresh-rotated" : "refresh-fixture", "id_token": try jwt.token(claims: claims),
            "token_type": "Bearer", "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke\(omitDirectScope ? "" : " chatgpt.tokens.use.direct")"]
        return OAuthHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: response))
    }
    func releaseExchange() { exchangeContinuation?.resume(); exchangeContinuation = nil }
    func releaseRefresh() { refreshContinuation?.resume(); refreshContinuation = nil }
}

private struct RSAJWTFixture {
    let key: SecKey
    let jwks: Data
    init() throws {
        var error: Unmanaged<CFError>?
        key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false] as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let bytes = [UInt8](try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &error)) as Data)
        var index = 1
        func length() -> Int {
            let byte = Int(bytes[index]); index += 1
            if byte < 128 { return byte }
            var value = 0
            for _ in 0..<(byte & 127) { value = (value << 8) | Int(bytes[index]); index += 1 }
            return value
        }
        _ = length(); XCTAssertEqual(bytes[index], 2); index += 1
        let count = length(); var modulus = Data(bytes[index..<(index + count)]); index += count
        if modulus.first == 0 { modulus.removeFirst() }
        XCTAssertEqual(bytes[index], 2); index += 1
        let exponentCount = length(); let exponent = Data(bytes[index..<(index + exponentCount)])
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "alg": "RS256", "use": "sig", "kid": "fixture-key", "n": modulus.base64URL(), "e": exponent.base64URL()]]])
    }
    func claims(nonce: String) -> [String: Any] {
        ["iss": "https://auth.openai.com", "aud": "oaiapp_fixture", "sub": "subject-fixture", "nonce": nonce,
         "iat": 1_800_000_000, "exp": 1_800_003_600, "email": "fixture@example.invalid"]
    }
    func token(claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture-key", "typ": "JWT"], options: .sortedKeys).base64URL()
        let payload = try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys).base64URL()
        let message = Data("\(header).\(payload)".utf8)
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error)) as Data
        return "\(header).\(payload).\(signature.base64URL())"
    }
}
private extension Data {
    func base64URL() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private final class OAuthTransportFixture: @unchecked Sendable {
    static let lock = NSLock()
    static var registry: [String: OAuthTransportFixture] = [:]
    let identifier = UUID().uuidString
    let headers: Bool
    let oversized: Bool
    let session: URLSession
    let started = XCTestExpectation(description: "OAuth transport started")
    let stopped = XCTestExpectation(description: "OAuth transport stopped")
    init(headers: Bool, oversized: Bool = false) {
        self.headers = headers; self.oversized = oversized
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthTransportProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Harness-OAuth-Test": identifier]
        session = URLSession(configuration: configuration)
        Self.lock.withLock { Self.registry[identifier] = self }
    }
    func close() {
        session.invalidateAndCancel()
        _ = Self.lock.withLock { Self.registry.removeValue(forKey: identifier) }
    }
}
private final class OAuthTransportProtocol: URLProtocol {
    private var fixture: OAuthTransportFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        fixture = OAuthTransportFixture.lock.withLock { OAuthTransportFixture.registry[request.value(forHTTPHeaderField: "X-Harness-OAuth-Test") ?? ""] }
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        if fixture.headers {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Content-Length": fixture.oversized ? "300000" : "10"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{".utf8))
        }
        fixture.started.fulfill()
    }
    override func stopLoading() { fixture?.stopped.fulfill() }
}
