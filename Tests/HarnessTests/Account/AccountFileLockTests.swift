import XCTest
import Darwin
import LockTestSupport
@testable import HarnessEmitter

final class AccountFileLockTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testExclusiveOwnershipAndReleaseWithoutDeletingTheLockFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var owner: AccountFileLock? = try AccountFileLock(name: "accounts", directory: dir)
        XCTAssertThrowsError(try AccountFileLock(name: "accounts", directory: dir)) {
            XCTAssertEqual($0 as? ChatGPTAuthenticationError, .sessionInUse)
        }
        withExtendedLifetime(owner) {}
        owner = nil
        let next = try AccountFileLock(name: "accounts", directory: dir)
        withExtendedLifetime(next) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("accounts").path))
    }
    func testKilledOwnerCannotStrandAccountLock() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("accounts").path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }; close(fd)
        let child = path.withCString { harness_fork_hold_lock($0, 5_000_000) }
        XCTAssertGreaterThan(child, 0); guard child > 0 else { return }
        XCTAssertThrowsError(try AccountFileLock(name: "accounts", directory: dir)) {
            XCTAssertEqual($0 as? ChatGPTAuthenticationError, .sessionInUse)
        }
        XCTAssertEqual(kill(child, SIGKILL), 0)
        _ = harness_wait_for_lock_child(child)
        let recovered = try AccountFileLock(name: "accounts", directory: dir)
        withExtendedLifetime(recovered) {}
    }
    func testUnsafeFileAndDirectoryCannotBecomeLocks() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("other")
        try Data("untouched".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("accounts"), withDestinationURL: file)
        XCTAssertThrowsError(try AccountFileLock(name: "accounts", directory: dir))
        XCTAssertThrowsError(try AccountFileLock(name: "../other", directory: dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("accounts"))
        try FileManager.default.linkItem(at: file, to: dir.appendingPathComponent("accounts"))
        XCTAssertThrowsError(try AccountFileLock(name: "accounts", directory: dir))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "untouched")
        let link = dir.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try AccountFileLock(name: "accounts", directory: link))
    }
}
