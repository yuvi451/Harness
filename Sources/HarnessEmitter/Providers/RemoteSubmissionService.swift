import Foundation
import HarnessCore

public struct SubmissionResult {
    public let response: String
    public let completion: LLMCompletion
}

/// All transmission paths pass through this mandatory metadata-only audit and consent gate.
@MainActor public final class RemoteSubmissionService {
    private let privacy: PrivacyController
    private let audit: any AuditLogging
    private let factory: @MainActor (String, Settings) -> any LLMProvider
    public init(privacy: PrivacyController, audit: any AuditLogging,
                providerFactory: @escaping @MainActor (String, Settings) -> any LLMProvider = { ChatGPTProvider(token:$0,model:$1.model,systemPrompt:$1.effectiveSystemPrompt) }) {
        self.privacy = privacy; self.audit = audit; self.factory = providerFactory
    }
    public func submit(image: ProcessedImage, settings: Settings, prompt: String, captureID: UUID,
                       credential: String?, source: CaptureSource, selectedWindowID: UInt32?,
                       onText: @escaping @MainActor (String, Bool) -> Void = { _,_ in }) async throws -> SubmissionResult {
        try await submit(images:[QueuedScreenshot(id:captureID,image:image)],settings:settings,prompt:prompt,
            credential:credential,source:source,selectedWindowID:selectedWindowID,onText:onText)
    }
    public func submit(images:[QueuedScreenshot],settings:Settings,prompt:String,credential:String?,
                       source:CaptureSource,selectedWindowID:UInt32?,
                       onText:@escaping @MainActor (String,Bool) -> Void = { _,_ in }) async throws -> SubmissionResult {
        let captureID = images.last?.id ?? UUID()
        var operationID: UUID?
        do {
            guard let credential, !credential.isEmpty else { throw PrivacyError.credentialRequired }
            let id = try await privacy.beginSubmission(images:images.map { $0.image.bytes },settings:settings,credentialPresent:true,
                source:source,selectedWindowID:selectedWindowID,masksApplied:images.allSatisfy { $0.image.masksApplied },
                promptChars:prompt.count,audit:audit,captureIDs:images.map(\.id))
            operationID = id
            try Task.checkCancellation()
            let history = await privacy.history.suffix(settings.historyLength).map {
                LLMExchange(prompt:"Previous capture discussion",response:$0.response)
            }
            try Task.checkCancellation()
            let provider = factory(credential,settings)
            var text = "", emittedCharacters = 0, emittedBytes = 0
            for try await delta in provider.stream(prompt:prompt,images:images.map { $0.image.bytes },history:history) {
                try Task.checkCancellation()
                let bytes = delta.utf8.count
                guard bytes <= 400_000 - emittedBytes else { throw PrivacyError.responseTooLarge }
                emittedBytes += bytes
                emittedCharacters += delta.count
                guard emittedCharacters <= 100_000 else { throw PrivacyError.responseTooLarge }
                text += delta
            }
            try Task.checkCancellation()
            guard let completion = provider.completionSummary,
                  !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw SubmissionError.incomplete }
            try await audit.record(.init(.llmCompleted,payload:["stop_reason":.string(completion.stopReason),
                "out_chars":.integer(text.count),"latency_ms":.number(completion.latencyMS),"capture_id":.string(captureID.uuidString)]),
                mode:settings.visibilityMode.rawValue,experimentID:nil)
            try Task.checkCancellation()
            try await privacy.completeSubmission(id:id,response:text)
            try Task.checkCancellation()
            onText(text,false)
            return SubmissionResult(response:text,completion:completion)
        } catch {
            if let operationID { await privacy.cancelSubmission(id:operationID) }
            // An audit failure must propagate; no provider body or arbitrary localized error is logged.
            if !(error is AuditError) {
                let reason: String
                switch error {
                case ChatGPTProviderError.invalidResponseStage(let stage): reason = "invalid_response_" + stage
                case ChatGPTProviderError.responseModelMismatch: reason = "response_model_mismatch"
                default: reason = error is CancellationError ? "cancelled" : "provider_or_stream_failure"
                }
                try await audit.record(.init(.llmFailed,payload:["reason":.string(reason),"capture_id":.string(captureID.uuidString)]),mode:settings.visibilityMode.rawValue,experimentID:nil)
            }
            throw error
        }
    }
}
public enum SubmissionError: Error { case incomplete }
