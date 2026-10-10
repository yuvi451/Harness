import XCTest
@testable import HarnessCore
@testable import HarnessEmitter
@MainActor final class SubmissionTests: XCTestCase {
    func testSubmissionPassesCustomInstructionsThroughProviderFactoryWithoutAuditingText() async throws {
        let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
        let log = SubmissionAudit(); var received = ""
        let service = RemoteSubmissionService(privacy:privacy,audit:log) { _,configuration in
            received = String(reflecting:configuration); return SubmissionProvider()
        }
        var settings = Settings(); settings.systemPrompt = "private synthetic prompt"
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        _ = try await service.submit(image:image,settings:settings,prompt:"Answer",captureID:UUID(),credential:"synthetic",source:.excludingSelf,selectedWindowID:nil)
        XCTAssertTrue(received.contains("private synthetic prompt"))
        let events = await log.events
        XCTAssertFalse(String(reflecting:events).contains("private synthetic prompt"))
    }
    func testConsentCredentialAndAuditGatePreventProviderCreation() async throws {
        let privacy = PrivacyController(); let log = SubmissionAudit(); var creations = 0
        let service = RemoteSubmissionService(privacy:privacy,audit:log) { _,_ in creations += 1; return SubmissionProvider() }
        var settings = Settings(); settings.networkSubmissionEnabled = true
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        do { _ = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:"key",source:.excludingSelf,selectedWindowID:nil,onText:{_,_ in}); XCTFail() } catch {}
        XCTAssertEqual(creations,0)
        try await privacy.grantConsent(acknowledged:true)
        do { _ = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:nil,source:.excludingSelf,selectedWindowID:nil,onText:{_,_ in}); XCTFail() } catch {}
        XCTAssertEqual(creations,0)
        await log.setFail(true)
        do { _ = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:"key",source:.excludingSelf,selectedWindowID:nil,onText:{_,_ in}); XCTFail() } catch {}
        XCTAssertEqual(creations,0)
        let bytes = await privacy.retainedImageByteCount; XCTAssertEqual(bytes,0)
    }
    func testSubmissionPublishesOnlyCompleteAnswerAuditsMetadataAndClearsImage() async throws {
        let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
        let log = SubmissionAudit(); let service = RemoteSubmissionService(privacy:privacy,audit:log) { _,_ in SubmissionProvider() }
        var settings = Settings(); settings.networkSubmissionEnabled = true
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        let captureID = UUID(); var texts:[String] = []
        let result = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:captureID,credential:"key",source:.excludingSelf,selectedWindowID:nil,onText:{text,_ in texts.append(text)})
        XCTAssertEqual(result.response,"hello world")
        XCTAssertEqual(texts,["hello world"], "Partial answers must stay off the frontend")
        let events = await log.events
        XCTAssertEqual(events.map(\.name),[.llmRequest,.llmCompleted])
        XCTAssertEqual(events.first?.payload["capture_id"],.string(captureID.uuidString))
        XCTAssertEqual(events.last?.payload["out_chars"],.integer(11))
        let bytes = await privacy.retainedImageByteCount; let active = await privacy.remoteRequestActive
        XCTAssertEqual(bytes,0); XCTAssertFalse(active)
    }
    func testPartialTextStaysBufferedUntilSuccessfulCompletion() async throws {
        let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
        let provider = PendingSubmissionProvider()
        let service = RemoteSubmissionService(privacy:privacy,audit:SubmissionAudit()) { _,_ in provider }
        var settings = Settings(); settings.networkSubmissionEnabled = true
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        var presented:[String] = []
        let request = Task {
            try await service.submit(image:image,settings:settings,prompt:"Answer",captureID:UUID(),credential:"synthetic",source:.excludingSelf,selectedWindowID:nil) { text,active in
                XCTAssertFalse(active); presented.append(text)
            }
        }
        defer { request.cancel() }
        for _ in 0..<200 { if provider.continuation != nil { break }; try await Task.sleep(nanoseconds:5_000_000) }
        let continuation = try XCTUnwrap(provider.continuation)
        continuation.yield("first ")
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertTrue(presented.isEmpty)
        continuation.yield("second")
        provider.completed = true; continuation.finish()
        let result = try await request.value
        XCTAssertEqual(result.response,"first second"); XCTAssertEqual(presented,["first second"])
    }

    func testCompletionAuditFailureCannotCommitHistoryOrFinalText() async throws {
        let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
        let log = SubmissionAudit(); await log.failCompletion()
        let service = RemoteSubmissionService(privacy:privacy,audit:log) { _,_ in SubmissionProvider() }
        var settings = Settings(); settings.networkSubmissionEnabled = true
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        var finalShown = false
        do { _ = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:"token",source:.excludingSelf,selectedWindowID:nil,onText:{_,active in if !active { finalShown = true } }); XCTFail() } catch {}
        let retained = await privacy.retainedImageByteCount; let history = await privacy.history
        XCTAssertEqual(retained,0); XCTAssertTrue(history.isEmpty); XCTAssertFalse(finalShown)
    }

    func testMaximumFragmentedAnswerDoesNotRepeatedlyScanAccumulatedText() async throws {
        let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
        let provider = SubmissionProvider(chunks:Array(repeating:"a",count:100_000))
        let service = RemoteSubmissionService(privacy:privacy,audit:SubmissionAudit()) { _,_ in provider }
        var settings = Settings(); settings.networkSubmissionEnabled = true
        let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:"synthetic",source:.excludingSelf,selectedWindowID:nil,onText:{_,_ in})
        XCTAssertEqual(result.response.count,100_000)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000_000,5,
            "Fragmented responses must not repeatedly traverse the growing answer on the main actor")
    }
    func testFailedIncompleteOversizedAndCancelledStreamsReleaseStateForRetry() async throws {
        for failure in 0..<4 {
            let privacy = PrivacyController(); try await privacy.grantConsent(acknowledged:true)
            let log = SubmissionAudit()
            let provider = SubmissionProvider(chunks:failure == 2 ? [String(repeating:"🙂",count:100_001)] : ["partial"," answer"],
                complete:failure != 1, failure:failure == 0 ? SubmissionError.incomplete : (failure == 3 ? CancellationError() : nil))
            var attempts = 0, finalShown = false
            let service = RemoteSubmissionService(privacy:privacy,audit:log) { _,_ in
                attempts += 1; return attempts == 1 ? provider : SubmissionProvider()
            }
            let settings: Settings = { var value = Settings(); value.networkSubmissionEnabled = true; return value }()
            let image = ProcessedImage(bytes:Data([1]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false)
            // Cancellation targets only the first request, so the retry runs in a fresh task.
            let request = Task {
                try await service.submit(image:image,settings:settings,prompt:"Explain",captureID:UUID(),credential:"synthetic",source:.excludingSelf,selectedWindowID:nil,onText:{_,active in
                    if !active { finalShown = true }
                })
            }
            do { _ = try await request.value; XCTFail("Failed stream accepted, case \(failure)") } catch {}
            let bytes = await privacy.retainedImageByteCount, active = await privacy.remoteRequestActive, history = await privacy.history
            XCTAssertEqual(bytes,0); XCTAssertFalse(active); XCTAssertTrue(history.isEmpty); XCTAssertFalse(finalShown)
            let events = await log.events
            XCTAssertEqual(events.map(\.name),[.llmRequest,.llmFailed])
            let retry = try await service.submit(image:image,settings:settings,prompt:"Retry",captureID:UUID(),credential:"synthetic",source:.excludingSelf,selectedWindowID:nil,onText:{_,_ in})
            XCTAssertEqual(retry.response,"hello world"); XCTAssertEqual(attempts,2)
        }
    }

}
private final class SubmissionProvider: LLMProvider {
    let chunks: [String], complete: Bool, failure: Error?
    init(chunks:[String] = ["hello ","world"],complete:Bool = true,failure:Error? = nil) {
        self.chunks = chunks; self.complete = complete; self.failure = failure
    }
    var completionSummary: LLMCompletion? { complete ? .init(stopReason:"end_turn",inputTokens:1,outputTokens:2,latencyMS:3) : nil }
    func stream(prompt:String,image:Data,history:[LLMExchange])->AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { c in chunks.forEach { c.yield($0) }; c.finish(throwing:failure) }
    }
}
private actor SubmissionAudit: AuditLogging {
    var events:[AuditEvent] = []; var fail = false; var completionFails = false
    func failCompletion() { completionFails = true }
    func setFail(_ value:Bool) { fail = value }
    func record(_ event:AuditEvent,mode:Int,experimentID:UUID?) throws { if fail || (completionFails && event.name == .llmCompleted) { throw AuditError.io(28) }; try event.validate(); events.append(event) }
}

private final class PendingSubmissionProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedContinuation: AsyncThrowingStream<String,Error>.Continuation?
    private var storedCompleted = false
    var continuation: AsyncThrowingStream<String,Error>.Continuation? { lock.withLock { storedContinuation } }
    var completed: Bool {
        get { lock.withLock { storedCompleted } }
        set { lock.withLock { storedCompleted = newValue } }
    }
    var completionSummary: LLMCompletion? { completed ? .init(stopReason:"completed",inputTokens:1,outputTokens:2,latencyMS:3) : nil }
    func stream(prompt:String,image:Data,history:[LLMExchange]) -> AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { value in lock.withLock { storedContinuation = value } }
    }
}
