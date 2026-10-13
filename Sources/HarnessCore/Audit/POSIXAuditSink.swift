import Foundation
import Darwin
/// Cooperating readers and writers use nonblocking attempts with a monotonic wait budget.
public enum BoundedFileLock {
    public static func acquire(_ descriptor: Int32, operation: Int32, timeoutSeconds: Double = 5) throws {
        guard operation == LOCK_SH || operation == LOCK_EX else { throw AuditError.io(EINVAL) }
        try wait(timeoutSeconds: timeoutSeconds) {
            if flock(descriptor, operation | LOCK_NB) == 0 { return true }
            let code = errno
            guard code == EINTR || code == EWOULDBLOCK || code == EAGAIN else { throw AuditError.io(code) }
            return false
        }
    }

    static func validateTimeout(_ seconds: Double) throws {
        guard seconds.isFinite, (0...5).contains(seconds) else { throw AuditError.io(EINVAL) }
    }

    /// Also bounds the sink's local mutex; all waits consume the same append budget.
    static func wait(timeoutSeconds: Double, attempt: () throws -> Bool) throws {
        try validateTimeout(timeoutSeconds)
        let budget = UInt64(timeoutSeconds * 1_000_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            if try attempt() { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            guard elapsed < budget else { throw AuditError.io(ETIMEDOUT) }
            let pause = max(1, min(10_000, (budget - elapsed) / 1_000))
            usleep(UInt32(pause))
        }
    }
}
public enum WriteOutcome { case success(Int), failure(Int32) }
public enum CompleteWriter {
    public static func synchronize(operation: () -> Int32?) throws {
        for _ in 0..<101 {
            guard let code = operation() else { return }
            guard code == EINTR else { throw AuditError.io(code) }
        }
        throw AuditError.io(EINTR)
    }
    public static func write(_ data: Data, operation: (UnsafeRawPointer, Int) -> WriteOutcome) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw AuditError.schema }
            var offset = 0; var interruptions = 0
            while offset < bytes.count {
                switch operation(base.advanced(by: offset), bytes.count - offset) {
                case .success(let n): guard n > 0, n <= bytes.count - offset else { throw AuditError.io(EIO) }; offset += n; interruptions = 0
                case .failure(let code):
                    if code == EINTR && interruptions < 100 { interruptions += 1; continue }
                    throw AuditError.io(code)
                }
            }
        }
    }
}
/// Complete record locks coordinate cooperating appenders. Not crash-proof or tamper-proof.
public final class POSIXAuditSink: AuditSink, @unchecked Sendable {
    private let fd: Int32
    private let localLock = NSLock()
    private let lockTimeoutSeconds: Double
    public init(url: URL, lockTimeoutSeconds: Double = 5) throws {
        try BoundedFileLock.validateTimeout(lockTimeoutSeconds)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(dir.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw AuditError.unsafeFile }
        guard chmod(dir.path, 0o700) == 0 else { throw AuditError.io(errno) }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AuditError.io(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { close(descriptor); throw AuditError.unsafeFile }
        guard fchmod(descriptor, 0o600) == 0 else { let code = errno; close(descriptor); throw AuditError.io(code) }
        fd = descriptor
        self.lockTimeoutSeconds = lockTimeoutSeconds
    }
    deinit { close(fd) }
    public func append(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536, data.last == 10 else { throw AuditError.schema }
        let started = DispatchTime.now().uptimeNanoseconds
        try BoundedFileLock.wait(timeoutSeconds: lockTimeoutSeconds) { localLock.try() }
        defer { localLock.unlock() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        try BoundedFileLock.acquire(fd, operation: LOCK_EX,
                                   timeoutSeconds: max(0, lockTimeoutSeconds - elapsed))
        defer { _ = flock(fd, LOCK_UN) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw AuditError.io(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw AuditError.unsafeFile }
        if info.st_size > 0 {
            var last: UInt8 = 0
            let n = pread(fd, &last, 1, info.st_size - 1)
            guard n == 1 else { throw AuditError.io(errno) }
            guard last == 10 else { throw AuditError.incompleteTail }
        }
        try CompleteWriter.write(data) { ptr, count in
            let n = Darwin.write(fd, ptr, count); return n < 0 ? .failure(errno) : .success(n)
        }
        try CompleteWriter.synchronize { fsync(fd) == 0 ? nil : errno }
    }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/harness/audit.jsonl")
    }
}
