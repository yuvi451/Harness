import Foundation
import XCTest
@testable import HarnessCore

final class PrivacyTests: XCTestCase {
    func testNetworkResourceDeadlineBoundsEvenContinuouslyArrivingTraffic() {
        let configuration = PrivacyNetworkConfiguration.makeConfiguration()
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, configuration.timeoutIntervalForRequest)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 180)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    private func enabledSettings() -> Settings {
        var settings = Settings()
        settings.networkSubmissionEnabled = true
        return settings
    }

    private func start(_ controller: PrivacyController, settings: Settings? = nil,
                       audit: any AuditLogging = PrivacyAuditStub()) async throws -> UUID {
        try await controller.beginSubmission(image: Data([1, 2, 3]), settings: settings ?? enabledSettings(),
            credentialPresent: true, source: .excludingSelf, selectedWindowID: nil,
            masksApplied: false, promptChars: 9, audit: audit)
    }

    func testReducingRetentionImmediatelyClearsExistingHistoryWithoutNewSubmission() async throws {
        let controller = PrivacyController(); try await controller.grantConsent(acknowledged:true)
        let id = try await start(controller); try await controller.completeSubmission(id:id,response:"previous response")
        try await controller.applyHistoryLimit(0)
        let history = await controller.history; XCTAssertTrue(history.isEmpty)
        do { try await controller.applyHistoryLimit(11); XCTFail("Invalid limit") } catch { XCTAssertEqual(error as? PrivacyError,.invalidHistoryLimit) }
    }

    func testReducingRetentionDuringSubmissionPreventsCompletionFromRestoringHistory() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let id = try await start(controller)
        try await controller.applyHistoryLimit(0)
        try await controller.completeSubmission(id: id, response: "discard this response")
        let history = await controller.history
        XCTAssertTrue(history.isEmpty)
        let retained = await controller.retainedImageByteCount
        XCTAssertEqual(retained, 0)
    }

    func testNetworkPreferenceDoesNotGrantConsentAndRevocationClearsReferences() async throws {
        let controller = PrivacyController()
        do { _ = try await start(controller); XCTFail("A preference cannot grant session consent") }
        catch { XCTAssertEqual(error as? PrivacyError, .consentRequired) }
        do { try await controller.grantConsent(acknowledged: false); XCTFail("Consent requires acknowledgement") }
        catch { XCTAssertEqual(error as? PrivacyError, .consentRequired) }
        try await controller.grantConsent(acknowledged: true)
        _ = try await start(controller)
        let active = await controller.remoteRequestActive
        XCTAssertTrue(active)
        await controller.revokeConsent()
        let retained = await controller.retainedImageByteCount
        let inactive = await controller.remoteRequestActive
        XCTAssertEqual(retained, 0)
        XCTAssertFalse(inactive)
        do { _ = try await start(controller); XCTFail("Revocation must block the next request") }
        catch { XCTAssertEqual(error as? PrivacyError, .consentRequired) }
    }

    func testDisabledSubmissionMissingCredentialAndCaptureScopeFailClosed() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        var settings = enabledSettings()
        settings.networkSubmissionEnabled = false
        do { _ = try await start(controller, settings: settings); XCTFail("Disabled submission") }
        catch { XCTAssertEqual(error as? PrivacyError, .networkSubmissionDisabled) }
        settings.networkSubmissionEnabled = true
        do {
            try await controller.validate(settings: settings, credentialPresent: false,
                source: .excludingSelf, selectedWindowID: nil, masksApplied: false)
            XCTFail("Missing credentials")
        } catch { XCTAssertEqual(error as? PrivacyError, .credentialRequired) }
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .full, selectedWindowID: nil, masksApplied: false)
            XCTFail("A broader source cannot replace the selected scope")
        } catch { XCTAssertEqual(error as? PrivacyError, .captureScopeMismatch) }
        settings.captureSource = .selectedWindow
        settings.selectedWindowID = 42
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .selectedWindow, selectedWindowID: 43, masksApplied: false)
            XCTFail("Wrong selected window")
        } catch { XCTAssertEqual(error as? PrivacyError, .captureScopeMismatch) }
        settings.selectedWindowID = nil
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .selectedWindow, selectedWindowID: nil, masksApplied: false)
            XCTFail("Missing selected window")
        } catch { XCTAssertEqual(error as? PrivacyError, .captureScopeMismatch) }
    }

    func testMaskingMustHaveValidRegionsAndBeApplied() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        var settings = enabledSettings()
        settings.privacyMaskingEnabled = true
        settings.maskingRegions = [MaskRegion(x: 0.1, y: 0.1, width: 0.2, height: 0.3)]
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .excludingSelf, selectedWindowID: nil, masksApplied: false)
            XCTFail("Masks must be applied before transmission")
        } catch { XCTAssertEqual(error as? PrivacyError, .maskingRequired) }
        try await controller.validate(settings: settings, credentialPresent: true,
            source: .excludingSelf, selectedWindowID: nil, masksApplied: true)
        settings.maskingRegions = [MaskRegion(x: 0.9, y: 0, width: 0.2, height: 0.3)]
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .excludingSelf, selectedWindowID: nil, masksApplied: true)
            XCTFail("Out-of-bounds masking region")
        } catch { XCTAssertEqual(error as? PrivacyError, .invalidMaskingRegions) }
        settings.maskingRegions = []
        do {
            try await controller.validate(settings: settings, credentialPresent: true,
                source: .excludingSelf, selectedWindowID: nil, masksApplied: true)
            XCTFail("Enabled masking requires defined regions")
        } catch { XCTAssertEqual(error as? PrivacyError, .invalidMaskingRegions) }
    }

    func testMandatoryAuditFailureBlocksRequestAndReleasesImage() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        do { _ = try await start(controller, audit: PrivacyAuditStub(fails: true)); XCTFail("Audit failure") }
        catch { XCTAssertEqual(error as? PrivacyAuditFailure, .unavailable) }
        let active = await controller.remoteRequestActive
        let retained = await controller.retainedImageByteCount
        XCTAssertFalse(active)
        XCTAssertEqual(retained, 0)
    }

    func testCancelDuringAwaitedAuditCannotReactivateRequest() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let audit = SuspendedPrivacyAudit()
        let pending = Task { try await self.start(controller, audit: audit) }
        try await audit.waitUntilEntered()
        let activeBeforeAudit = await controller.remoteRequestActive
        XCTAssertFalse(activeBeforeAudit)
        await controller.cancelSubmission()
        await audit.release()
        do { _ = try await pending.value; XCTFail("Cancelled audit wait cannot authorize a request") }
        catch { XCTAssertEqual(error as? PrivacyError, .operationCancelled) }
        let active = await controller.remoteRequestActive
        let retained = await controller.retainedImageByteCount
        XCTAssertFalse(active)
        XCTAssertEqual(retained, 0)
    }

    func testTaskCancellationClearsPendingImageWithoutWaitingForAudit() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let audit = SuspendedPrivacyAudit()
        let pending = Task { try await self.start(controller, audit: audit) }
        try await audit.waitUntilEntered()
        pending.cancel()
        // The cancellation handler hops to the actor; yield deterministically until it is observed.
        for _ in 0..<1000 {
            if await controller.retainedImageByteCount == 0 { break }
            await Task.yield()
        }
        let retained = await controller.retainedImageByteCount
        XCTAssertEqual(retained, 0)
        await audit.release()
        do { _ = try await pending.value; XCTFail("Cancelled task cannot authorize transmission") }
        catch { XCTAssertTrue(error is CancellationError || error as? PrivacyError == .operationCancelled) }
    }

    func testOldAuditCompletionCannotAuthorizeOrCancelANewerRequest() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let audit = SuspendedPrivacyAudit()
        let pending = Task { try await self.start(controller, audit: audit) }
        try await audit.waitUntilEntered()
        await controller.cancelSubmission()
        let currentID = try await start(controller)
        await audit.release()
        do { _ = try await pending.value; XCTFail("Old audit cannot authorize submission") }
        catch { XCTAssertEqual(error as? PrivacyError, .operationCancelled) }
        let active = await controller.remoteRequestActive
        XCTAssertTrue(active)
        try await controller.completeSubmission(id: currentID, response: "current")
    }

    func testAuditReceivesOnlyRequiredMetadataBeforeGateReturns() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let audit = PrivacyAuditStub()
        let id = try await start(controller, audit: audit)
        let events = await audit.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, .llmRequest)
        XCTAssertEqual(Set(events[0].payload.keys), ["provider", "model", "prompt_chars", "capture_id"])
        XCTAssertEqual(events[0].payload["prompt_chars"], .integer(9))
        XCTAssertEqual(events[0].payload["capture_id"], .string(id.uuidString))
        XCTAssertNoThrow(try events[0].validate())
    }

    func testOnlyOneOperationAndStaleCompletionCannotClearNewOperation() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        let oldID = try await start(controller)
        do { _ = try await start(controller); XCTFail("Concurrent operation") }
        catch { XCTAssertEqual(error as? PrivacyError, .operationInProgress) }
        await controller.cancelSubmission()
        let newID = try await start(controller)
        do { try await controller.completeSubmission(id: oldID, response: "stale"); XCTFail("Stale completion") }
        catch { XCTAssertEqual(error as? PrivacyError, .operationCancelled) }
        let active = await controller.remoteRequestActive
        XCTAssertTrue(active)
        try await controller.completeSubmission(id: newID, response: "fresh")
        let responses = await controller.history.map(\.response)
        XCTAssertEqual(responses, ["fresh"])
    }

    func testHistoryIsBoundedAndCompletionDismissalTerminationClearImages() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        var settings = enabledSettings()
        settings.historyLength = 2
        for response in ["one", "two", "three"] {
            let id = try await start(controller, settings: settings)
            try await controller.completeSubmission(id: id, response: response)
            let retained = await controller.retainedImageByteCount
            XCTAssertEqual(retained, 0)
        }
        let responses = await controller.history.map(\.response)
        XCTAssertEqual(responses, ["two", "three"])
        _ = try await start(controller, settings: settings)
        await controller.dismiss()
        let dismissedHistory = await controller.history
        let dismissedBytes = await controller.retainedImageByteCount
        XCTAssertTrue(dismissedHistory.isEmpty)
        XCTAssertEqual(dismissedBytes, 0)
        _ = try await start(controller, settings: settings)
        await controller.terminate()
        let terminatedBytes = await controller.retainedImageByteCount
        XCTAssertEqual(terminatedBytes, 0)
        do { _ = try await start(controller); XCTFail("Termination revokes consent") }
        catch { XCTAssertEqual(error as? PrivacyError, .consentRequired) }
    }

    func testInvalidImageAndResponseBoundsFailClosed() async throws {
        let controller = PrivacyController(maxResponseCharacters: 5)
        try await controller.grantConsent(acknowledged: true)
        do {
            _ = try await controller.beginSubmission(image: Data(), settings: enabledSettings(),
                credentialPresent: true, source: .excludingSelf, selectedWindowID: nil,
                masksApplied: false, promptChars: 0, audit: PrivacyAuditStub())
            XCTFail("Empty image")
        } catch { XCTAssertEqual(error as? PrivacyError, .invalidImage) }
        let id = try await start(controller)
        do { try await controller.completeSubmission(id: id, response: "too long"); XCTFail("Response bound") }
        catch { XCTAssertEqual(error as? PrivacyError, .responseTooLarge) }
        let retained = await controller.retainedImageByteCount
        let history = await controller.history
        XCTAssertEqual(retained, 0)
        XCTAssertTrue(history.isEmpty)
    }

    func testInvalidSettingsAndZeroHistoryCannotRetainExchanges() async throws {
        let controller = PrivacyController()
        try await controller.grantConsent(acknowledged: true)
        var settings = enabledSettings()
        settings.maxImageDimension = 0
        do { _ = try await start(controller, settings: settings); XCTFail("Invalid configuration") }
        catch { XCTAssertEqual(error as? SettingsValidationError, .invalidField("maxImageDimension")) }
        settings.maxImageDimension = 1568
        settings.historyLength = 0
        let id = try await start(controller, settings: settings)
        try await controller.completeSubmission(id: id, response: "discard")
        let history = await controller.history
        XCTAssertTrue(history.isEmpty)
    }

    func testCredentialRedactionHandlesKnownSecretsHeadersAndKeyFormats() {
        let text = "known=sample-private-token Authorization: Bearer token-value\napi_key=secret-value sk-ant-example123 other-safe"
        let redacted = DiagnosticRedactor.redact(text, knownSecrets: ["sample-private-token", ""])
        for secret in ["sample-private-token", "token-value", "secret-value", "sk-ant-example123"] {
            XCTAssertFalse(redacted.contains(secret), "Diagnostic secret remains: \(secret)")
        }
        XCTAssertTrue(redacted.contains("other-safe"))
        let quoted = DiagnosticRedactor.redact(#"{"api_key":"json-secret", "Authorization":"Basic basic-secret"}"#)
        XCTAssertFalse(quoted.contains("json-secret"))
        XCTAssertFalse(quoted.contains("basic-secret"))
    }

    func testNetworkConfigurationDisablesPersistentCachesAndCookies() {
        let configuration = PrivacyNetworkConfiguration.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(configuration.identifier)
    }
}

private enum PrivacyAuditFailure: Error { case unavailable }
private actor PrivacyAuditStub: AuditLogging {
    let fails: Bool
    private(set) var events: [AuditEvent] = []
    init(fails: Bool = false) { self.fails = fails }
    func record(_ event: AuditEvent, mode: Int, experimentID: UUID?) async throws {
        if fails { throw PrivacyAuditFailure.unavailable }
        try event.validate()
        events.append(event)
    }
}

private actor SuspendedPrivacyAudit: AuditLogging {
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func record(_ event: AuditEvent, mode: Int, experimentID: UUID?) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            hasEntered = true
        }
    }
    func waitUntilEntered() async throws { try await waitForTest { self.hasEntered } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
