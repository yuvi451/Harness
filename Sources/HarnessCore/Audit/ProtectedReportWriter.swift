import Foundation
import Darwin

/// A bounded metadata report. Cooperating writers lock before replacing contents.
/// Truncation and writes are not crash-atomic; ordinary files have no integrity seal.
public enum ProtectedReportWriter {
    public static func write(_ text: String, to url: URL, lockTimeoutSeconds: Double = 5) throws {
        guard text.utf8.count <= 2_000_000 else { throw AuditError.recordTooLarge }
        try BoundedFileLock.validateTimeout(lockTimeoutSeconds)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var directoryInfo = stat()
        guard lstat(directory.path,&directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw AuditError.unsafeFile }
        let descriptor = open(url.path,O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0o600)
        guard descriptor >= 0 else { throw AuditError.io(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw AuditError.unsafeFile }
        try BoundedFileLock.acquire(descriptor, operation: LOCK_EX, timeoutSeconds: lockTimeoutSeconds)
        defer { _ = flock(descriptor,LOCK_UN) }
        guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw AuditError.unsafeFile }
        guard fchmod(descriptor,0o600) == 0, ftruncate(descriptor,0) == 0 else { throw AuditError.io(errno) }
        let data = Data(text.utf8)
        if !data.isEmpty {
            try CompleteWriter.write(data) { pointer,count in
                let written = Darwin.write(descriptor,pointer,count)
                return written < 0 ? .failure(errno) : .success(written)
            }
        }
        try CompleteWriter.synchronize { fsync(descriptor) == 0 ? nil : errno }
    }
}
