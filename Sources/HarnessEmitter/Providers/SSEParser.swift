import Foundation

enum SSEError: Error { case responseTooLarge, eventTooLarge, malformedStream }

struct SSEEvent {
    let event: String
    let data: Data
}

/// Frames raw bytes before UTF-8 decoding, preserving split scalars and CRLF boundaries.
struct SSEParser {
    private var line = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var receivedBytes = 0
    private var previousCR = false
    private var firstLine = true
    private let eventLimit: Int
    private let totalLimit: Int

    init(eventLimit: Int = 65_536, totalLimit: Int = 2_000_000) {
        self.totalLimit = max(1, min(totalLimit, 4_194_304))
        self.eventLimit = max(1, min(eventLimit, self.totalLimit))
    }

    mutating func feed(_ bytes: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes { if let event = try feed(byte) { events.append(event) } }
        return events
    }

    mutating func feed(_ byte: UInt8) throws -> SSEEvent? {
        receivedBytes += 1
        guard receivedBytes <= totalLimit else { throw SSEError.responseTooLarge }
        if previousCR {
            previousCR = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            let event = try finishLine()
            previousCR = byte == 13
            return event
        }
        guard line.count < eventLimit else { throw SSEError.eventTooLarge }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> SSEEvent? {
        guard var value = String(data: line, encoding: .utf8) else { throw SSEError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if value.hasPrefix("\u{feff}") { value.removeFirst() } }
        if value.isEmpty {
            defer { eventName = ""; dataLines.removeAll(keepingCapacity: false); eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventName, data: Data(dataLines.joined(separator: "\n").utf8))
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var content = parts.count == 2 ? String(parts[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        eventBytes += value.utf8.count + 1
        guard eventBytes <= eventLimit else { throw SSEError.eventTooLarge }
        switch field {
        case "event": eventName = content
        case "data": dataLines.append(content)
        default: break // id/retry and future fields do not initiate retries or requests.
        }
        return nil
    }
}
