import Foundation

public enum PrivacyError: Error, Equatable, Sendable {
    case consentRequired
    case networkSubmissionDisabled
    case credentialRequired
    case captureScopeMismatch
    case maskingRequired
    case invalidMaskingRegions
    case invalidHistoryLimit
    case invalidImage
    case invalidPromptLength
    case operationInProgress
    case operationCancelled
    case responseTooLarge
}

/// Contains response text and non-content metadata only. Screenshots and raw prompts are never history.
public struct PrivacyHistoryEntry: Equatable, Sendable {
    public let operationID: UUID
    public let provider: String
    public let model: String
    public let source: CaptureSource
    public let promptCharacters: Int
    public let response: String
}

/// Runtime consent restored by the app from the saved user choice, and an audited gate for one in-memory image submission at a time.
/// Clearing removes application references; it does not promise physical RAM erasure or control
/// over operating-system swap, frameworks, diagnostics, or crash reporting.
public actor PrivacyController {
    private struct Operation {
        let id: UUID
        let provider: String
        let model: String
        let source: CaptureSource
        let promptCharacters: Int
        var historyLimit: Int
        var image: Data?
        var auditCompleted = false
    }

    private var consentGranted = false
    private var operation: Operation?
    private let maxResponseCharacters: Int
    public private(set) var history: [PrivacyHistoryEntry] = []

    /// Bind this to the visible remote-request indicator. It becomes true only after the audit gate.
    public var remoteRequestActive: Bool { operation?.auditCompleted == true }
    public var retainedImageByteCount: Int { operation?.image?.count ?? 0 }
    public var hasSessionConsent: Bool { consentGranted }

    public init(maxResponseCharacters: Int = 100_000) {
        self.maxResponseCharacters = max(0, maxResponseCharacters)
    }

    public func grantConsent(acknowledged: Bool) throws {
        guard acknowledged else { throw PrivacyError.consentRequired }
        consentGranted = true
    }

    public func revokeConsent() {
        consentGranted = false
        clear()
    }

    public func validate(settings: Settings, credentialPresent: Bool, source: CaptureSource,
                         selectedWindowID: UInt32?, masksApplied: Bool) throws {
        guard consentGranted else { throw PrivacyError.consentRequired }
        guard settings.networkSubmissionEnabled else { throw PrivacyError.networkSubmissionDisabled }
        guard credentialPresent else { throw PrivacyError.credentialRequired }
        guard settings.captureSource == source else { throw PrivacyError.captureScopeMismatch }
        if source == .selectedWindow {
            guard let selectedWindowID, selectedWindowID != 0,
                  settings.selectedWindowID == selectedWindowID else {
                throw PrivacyError.captureScopeMismatch
            }
        } else if selectedWindowID != nil {
            throw PrivacyError.captureScopeMismatch
        }
        guard (0...10).contains(settings.historyLength) else { throw PrivacyError.invalidHistoryLimit }
        if settings.privacyMaskingEnabled {
            guard !settings.maskingRegions.isEmpty, settings.maskingRegions.count <= 32,
                  settings.maskingRegions.allSatisfy(\.isValid) else {
                throw PrivacyError.invalidMaskingRegions
            }
            guard masksApplied else { throw PrivacyError.maskingRequired }
        }
        try settings.validated()
    }

    /// The caller must not start transmission until this returns successfully. No body, image,
    /// prompt, response, or credential is passed to the mandatory audit writer.
    public func beginSubmission(image: Data, settings: Settings, credentialPresent: Bool,
                                source: CaptureSource, selectedWindowID: UInt32?, masksApplied: Bool,
                                promptChars: Int, audit: any AuditLogging,
                                experimentID: UUID? = nil, captureID: UUID? = nil) async throws -> UUID {
        try Task.checkCancellation()
        try validate(settings: settings, credentialPresent: credentialPresent, source: source,
                     selectedWindowID: selectedWindowID, masksApplied: masksApplied)
        guard operation == nil else { throw PrivacyError.operationInProgress }
        guard !image.isEmpty, settings.maxImageBytes > 0, image.count <= settings.maxImageBytes else {
            throw PrivacyError.invalidImage
        }
        guard promptChars >= 0 else { throw PrivacyError.invalidPromptLength }
        let id = UUID()
        operation = Operation(id: id, provider: settings.provider.rawValue, model: settings.model,
                              source: source, promptCharacters: promptChars,
                              historyLimit: settings.historyLength, image: image)
        // Apply a reduced retention limit immediately, even if the new request later fails.
        trimHistory(to: settings.historyLength)
        do {
            try await withTaskCancellationHandler {
                try await audit.record(AuditEvent(.llmRequest, payload: [
                    "provider": .string(settings.provider.rawValue),
                    "model": .string(settings.model),
                    "prompt_chars": .integer(promptChars),
                    "capture_id": .string((captureID ?? id).uuidString)
                ]), mode: settings.visibilityMode.rawValue, experimentID: experimentID)
            } onCancel: {
                Task { await self.cancelSubmission(id: id) }
            }
            try Task.checkCancellation()
            // Actor reentrancy permits revoke/dismiss/cancel while the audit writer is awaited.
            // A cancelled operation must never authorize itself or interfere with a newer one.
            guard operation?.id == id, consentGranted else { throw PrivacyError.operationCancelled }
            operation?.auditCompleted = true
            return id
        } catch {
            cancelSubmission(id: id)
            throw error
        }
    }

    public func completeSubmission(id: UUID, response: String) throws {
        guard let current = operation, current.id == id, current.auditCompleted else {
            throw PrivacyError.operationCancelled
        }
        // Clean up before handling even an invalid response.
        cancelSubmission(id: id)
        guard response.count <= maxResponseCharacters else { throw PrivacyError.responseTooLarge }
        if current.historyLimit > 0 {
            history.append(PrivacyHistoryEntry(operationID: id, provider: current.provider,
                model: current.model, source: current.source,
                promptCharacters: current.promptCharacters, response: response))
        }
        trimHistory(to: current.historyLimit)
    }

    /// Cancelling a request also clears hidden response history.
    public func cancelSubmission() { clear() }

    /// An old cancellation cannot clear a newer request.
    public func cancelSubmission(id: UUID) {
        guard operation?.id == id else { return }
        operation?.image = nil
        operation = nil
    }

    public func dismiss() { clear() }

    public func terminate() { revokeConsent() }

    public func clear() {
        operation?.image = nil
        operation = nil
        history.removeAll(keepingCapacity: false)
    }

    public func applyHistoryLimit(_ limit: Int) throws {
        guard (0...10).contains(limit) else { throw PrivacyError.invalidHistoryLimit }
        if let current = operation {
            operation?.historyLimit = min(current.historyLimit, limit)
        }
        trimHistory(to: limit)
    }

    private func trimHistory(to limit: Int) {
        if history.count > limit { history.removeFirst(history.count - limit) }
    }
}
