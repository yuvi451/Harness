import Foundation

struct ShareabilityQueryResult: Sendable {
    enum Status: Equatable, Sendable { case success, failed, timedOut, cancelled }
    let status: Status
    let windows: [ShareableWindowIdentity]
    init(status: Status, windows: [ShareableWindowIdentity] = []) { self.status = status; self.windows = windows }
}

/// Resolves once independently of an OS callback's cancellation behavior. Late callbacks are
/// ignored. No task group waits for an uncooperative query before returning partial metadata.
enum ShareabilityCallbackGate {
    static func query(timeoutSeconds: Double,
        operation: @escaping @Sendable (@escaping @Sendable (ShareabilityQueryResult) -> Void) -> Void,
        scheduleTimeout: @escaping @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }) async -> ShareabilityQueryResult {
        let state = CallbackState()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                if Task.isCancelled { state.finish(.init(status: .cancelled)); return }
                let delay = timeoutSeconds.isFinite ? max(0.001, min(5, timeoutSeconds)) : 5
                scheduleTimeout(delay) { [weak state] in state?.finish(.init(status: .timedOut)) }
                guard !state.finished else { return }
                operation { [weak state] result in state?.finish(result) }
            }
        }, onCancel: { state.finish(.init(status: .cancelled)) })
    }
}

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareabilityQueryResult, Never>?
    private var result: ShareabilityQueryResult?
    var finished: Bool { lock.withLock { result != nil } }
    func install(_ value: CheckedContinuation<ShareabilityQueryResult, Never>) -> Bool {
        let previous = lock.withLock { () -> ShareabilityQueryResult? in
            if let result { return result }; continuation = value; return nil
        }
        if let previous { value.resume(returning: previous); return false }; return true
    }
    func finish(_ value: ShareabilityQueryResult) {
        let waiting = lock.withLock { () -> CheckedContinuation<ShareabilityQueryResult, Never>? in
            guard result == nil else { return nil }; result = value
            let waiting = continuation; continuation = nil; return waiting
        }
        waiting?.resume(returning: value)
    }
}
