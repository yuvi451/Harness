import Foundation

/// Resolves once independently of framework cancellation. Late callbacks are ignored;
/// Timeout/cancellation do not wait for the native operation or authorization dialog.
enum NativeCallbackGate {
    static func query<Value>(timeoutSeconds: Double = 5, timeoutError: Error = CaptureError.captureFailed,
        operation: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let state = NativeCallbackState<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                if Task.isCancelled { state.finish(.failure(CancellationError())); return }
                let delay = timeoutSeconds.isFinite ? max(0.001, min(180, timeoutSeconds)) : 5
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak state] in
                    state?.finish(.failure(timeoutError))
                }
                guard !state.finished else { return }
                operation { [weak state] result in state?.finish(result) }
            }
        }, onCancel: { state.finish(.failure(CancellationError())) })
    }
}
private final class NativeCallbackState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    var finished: Bool { lock.withLock { result != nil } }
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let prior = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }; self.continuation = continuation; return nil
        }
        if let prior { continuation.resume(with: prior); return false }
        return true
    }
    func finish(_ result: Result<Value, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let waiting = continuation; continuation = nil; return waiting
        }
        waiting?.resume(with: result)
    }
}
