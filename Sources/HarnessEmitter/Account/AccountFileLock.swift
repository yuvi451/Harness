import Foundation
import Darwin

/// Contains no credentials. The kernel releases the mutex on close or process exit.
/// Keep the file in place: unlinking a held inode would allow a second owner.
final class AccountFileLock {
    private let descriptor: Int32
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/harness/account-locks")
    }
    init(name: String, directory: URL = AccountFileLock.directory) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ChatGPTAuthenticationError.storageFailure
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ChatGPTAuthenticationError.storageFailure }
        let fd = open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ChatGPTAuthenticationError.storageFailure }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
            close(fd); throw ChatGPTAuthenticationError.storageFailure
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK || code == EAGAIN ? ChatGPTAuthenticationError.sessionInUse : ChatGPTAuthenticationError.storageFailure
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
