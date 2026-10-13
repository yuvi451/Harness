import Foundation

public struct LLMExchange: Sendable {
    public let prompt: String
    public let response: String
    public init(prompt: String, response: String) { self.prompt = prompt; self.response = response }
}

public struct LLMCompletion: Sendable {
    public let stopReason: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latencyMS: Double
    public init(stopReason: String, inputTokens: Int? = nil, outputTokens: Int? = nil, latencyMS: Double) {
        self.stopReason = stopReason; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.latencyMS = latencyMS
    }
}

public protocol LLMProvider: Sendable {
    var completionSummary: LLMCompletion? { get }
    func stream(prompt: String, image: Data, history: [LLMExchange]) -> AsyncThrowingStream<String, Error>
    func stream(prompt: String, images: [Data], history: [LLMExchange]) -> AsyncThrowingStream<String, Error>
}

public extension LLMProvider {
    func stream(prompt:String,images:[Data],history:[LLMExchange]) -> AsyncThrowingStream<String,Error> {
        guard images.count == 1,let image = images.first else {
            return AsyncThrowingStream { $0.finish(throwing:ChatGPTProviderError.capabilityUnavailable) }
        }
        return stream(prompt:prompt,image:image,history:history)
    }
}

/// The task is bound synchronously before URLSession starts, including cancellation before headers.
final class RequestControl: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var worker: Task<Void, Never>?
    private var task: URLSessionTask?
    func setWorker(_ worker: Task<Void, Never>) {
        let cancelNow = lock.withLock { if !finished { self.worker = worker }; return cancelled }
        if cancelNow { worker.cancel() }
    }
    func releaseWorker() { lock.withLock { finished = true; worker = nil; task = nil } }
    func releaseTask(_ value: URLSessionTask) { lock.withLock { if task === value { task = nil } } }
    func cancel() {
        let references = lock.withLock { cancelled = true; return (worker, task) }
        references.0?.cancel(); references.1?.cancel()
    }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let cancelNow = lock.withLock { self.task = task; return cancelled }
        if cancelNow { task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
