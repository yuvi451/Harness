import Foundation
public protocol AuditClock: Sendable { func now() -> Date }
public struct SystemAuditClock: AuditClock { public init() {}; public func now() -> Date { Date() } }
public struct FixedAuditClock: AuditClock { let date: Date; public init(_ date: Date) { self.date = date }; public func now() -> Date { date } }
public protocol AuditSink: Sendable { func append(_ data: Data) throws }
public protocol AuditLogging: Sendable {
    func record(_ event: AuditEvent, mode: Int, experimentID: UUID?) async throws
}
public actor AuditLogger: AuditLogging {
    private let sink: any AuditSink
    private let clock: any AuditClock
    public nonisolated let sessionID: UUID
    private let macOS: String
    private var sequence = 0
    private var failed = false
    public init(sink: any AuditSink, clock: any AuditClock = SystemAuditClock(), macOS: String = ProcessInfo.processInfo.operatingSystemVersionString, sessionID: UUID = UUID()) {
        self.sink = sink; self.clock = clock; self.macOS = macOS; self.sessionID = sessionID
    }
    public func record(_ event: AuditEvent, mode: Int, experimentID: UUID? = nil) throws {
        guard !failed else { throw AuditError.latchedFailure }
        do {
            try event.validate()
            guard (0...2).contains(mode), sequence < Int.max else { throw AuditError.schema }
            let record = AuditRecord(schemaVersion: 1, ts: AuditRecord.timestampFormatter().string(from: clock.now()), event: event.name, mode: mode, macos: macOS, sessionID: sessionID, eventID: UUID(), experimentID: experimentID, sequence: sequence + 1, payload: event.payload)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(record)
            _ = try AuditRecord.decode(line)
            line.append(10)
            guard line.count <= 65_536 else { throw AuditError.recordTooLarge }
            try sink.append(line); sequence += 1
        } catch { failed = true; throw error }
    }
}
