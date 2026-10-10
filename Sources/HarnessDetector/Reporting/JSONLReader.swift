import Foundation
import Darwin
import HarnessCore

public struct JSONLReadIssue: Equatable, Sendable {
    public enum Code: String, Sendable { case missingFile = "missing_file", unsafeFile = "unsafe_file", fileTooLarge = "file_too_large", lineTooLarge = "line_too_large", tooManyRecords = "too_many_records", malformedTail = "malformed_tail", malformedRecord = "malformed_record", unsupportedSchema = "unsupported_schema", ioError = "io_error", lockTimedOut = "lock_timed_out" }
    public let code: Code
    public let line: Int?
    public init(code: Code, line: Int? = nil) { self.code = code; self.line = line }
}
public struct JSONLReadResult<Record: Sendable>: Sendable {
    public let records: [Record]
    public let issues: [JSONLReadIssue]
    public init(records: [Record], issues: [JSONLReadIssue]) { self.records = records; self.issues = issues }
}
public enum JSONLReader {
    public static func readAudit(url: URL, lockTimeoutSeconds: Double = 5) -> JSONLReadResult<AuditRecord> { read(url: url, lockTimeoutSeconds: lockTimeoutSeconds, decode: AuditRecord.decode) }
    public static func readDetections(url: URL, lockTimeoutSeconds: Double = 5) -> JSONLReadResult<DetectionRecord> { read(url: url, lockTimeoutSeconds: lockTimeoutSeconds, decode: DetectionRecord.decode) }
    private static func read<T: Sendable>(url: URL, lockTimeoutSeconds: Double, decode: (Data) throws -> T) -> JSONLReadResult<T> {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .init(records: [], issues: [.init(code: errno == ENOENT ? .missingFile : errno == ELOOP ? .unsafeFile : .ioError)]) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .init(records: [], issues: [.init(code: .unsafeFile)]) }
        do { try BoundedFileLock.acquire(fd, operation: LOCK_SH, timeoutSeconds: lockTimeoutSeconds) }
        catch AuditError.io(let code) where code == ETIMEDOUT { return .init(records: [], issues: [.init(code: .lockTimedOut)]) }
        catch { return .init(records: [], issues: [.init(code: .ioError)]) }
        defer { _ = flock(fd, LOCK_UN) }
        guard fstat(fd, &info) == 0 else { return .init(records: [], issues: [.init(code: .ioError)]) }
        let maximum = 64 * 1024 * 1024
        guard info.st_size >= 0, info.st_size <= maximum else { return .init(records: [], issues: [.init(code: .fileTooLarge)]) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 32_768), interruptions = 0
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR && interruptions < 100 { interruptions += 1; continue }
                return .init(records: [], issues: [.init(code: .ioError)])
            }
            interruptions = 0
            guard n <= maximum - data.count else { return .init(records: [], issues: [.init(code: .fileTooLarge)]) }
            data.append(contentsOf: buffer.prefix(n))
        }
        var records: [T] = [], issues: [JSONLReadIssue] = [], start = data.startIndex, line = 1
        for index in data.indices where data[index] == 10 {
            guard line <= 100_000 else { issues.append(.init(code: .tooManyRecords, line: line)); return .init(records: records, issues: issues) }
            let length = data.distance(from: start, to: index)
            if length > 65_536 { issues.append(.init(code: .lineTooLarge, line: line)) }
            else {
                do {
                    let bytes = Data(data[start..<index])
                    if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       let version = object["schema_version"] as? Int, version != 1 {
                        issues.append(.init(code: .unsupportedSchema, line: line))
                    } else { records.append(try decode(bytes)) }
                }
                catch DetectionSchemaError.unsupportedVersion { issues.append(.init(code: .unsupportedSchema, line: line)) }
                catch { issues.append(.init(code: .malformedRecord, line: line)) }
            }
            start = data.index(after: index); line += 1
        }
        if start != data.endIndex { issues.append(.init(code: data.distance(from: start, to: data.endIndex) > 65_536 ? .lineTooLarge : .malformedTail, line: line)) }
        return .init(records: records, issues: issues)
    }
}
