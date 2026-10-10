import Foundation

public enum DetectorCommand: String, Sendable { case scan, matrix, correlate, help }
public enum DetectorCLIError: Error, LocalizedError {
    case invalidArguments, invalidRecords, interactiveTerminalRequired, inputTooLong, measurementTimedOut
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Invalid command or option. Run harness-detect --help for supported arguments."
        case .invalidRecords: return "Audit records are missing, incomplete or invalid; the matrix cannot be armed."
        case .interactiveTerminalRequired: return "The matrix requires an interactive terminal and your physical capture-key press."
        case .inputTooLong: return "Interactive input exceeded the supported bound."
        case .measurementTimedOut: return "No complete physical capture was observed before the measurement timeout."
        }
    }
}
public struct DetectorCLIOptions: Sendable {
    public var command: DetectorCommand
    public var outputDirectory = POSIXAuditSink.defaultURL.deletingLastPathComponent()
    public var emitterSessionID: UUID?
    public var timeoutSeconds = 120
    public var maximumSkewMS = 500
    public var ownerPID: Int?
    public var browser = "not_recorded"
    public var browserVersion = "not_recorded"
    private var explicitAuditURL: URL?
    private var explicitDetectionsURL: URL?
    public var auditURL: URL { explicitAuditURL ?? outputDirectory.appendingPathComponent("audit.jsonl") }
    public var detectionsURL: URL { explicitDetectionsURL ?? outputDirectory.appendingPathComponent("detections.jsonl") }
    public static func parse(_ args: [String]) throws -> Self {
        guard args.count <= 25, args.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else { throw DetectorCLIError.invalidArguments }
        if args.isEmpty || args == ["--help"] || args == ["help"] { return .init(command:.help) }
        guard let first = args.first, let command = DetectorCommand(rawValue:first), command != .help else { throw DetectorCLIError.invalidArguments }
        var result = Self(command:command)
        let common: Set<String> = ["--out-dir"]
        let allowed: Set<String>
        switch command {
        case .scan: allowed = common.union(["--owner-pid"])
        case .matrix: allowed = common.union(["--emitter-session","--timeout","--browser","--browser-version","--audit"])
        case .correlate: allowed = common.union(["--audit","--detections","--max-skew-ms"])
        case .help: allowed = []
        }
        var seen: Set<String> = []; var index = 1
        while index < args.count {
            let key = args[index]
            guard allowed.contains(key), seen.insert(key).inserted, index + 1 < args.count else { throw DetectorCLIError.invalidArguments }
            let value = args[index+1]; guard !value.isEmpty else { throw DetectorCLIError.invalidArguments }
            func integer(_ range: ClosedRange<Int>) throws -> Int {
                guard let n = Int(value), range.contains(n) else { throw DetectorCLIError.invalidArguments }; return n
            }
            switch key {
            case "--out-dir": result.outputDirectory = URL(fileURLWithPath:value,isDirectory:true).standardizedFileURL
            case "--audit": result.explicitAuditURL = URL(fileURLWithPath:value).standardizedFileURL
            case "--detections": result.explicitDetectionsURL = URL(fileURLWithPath:value).standardizedFileURL
            case "--emitter-session": guard let id = UUID(uuidString:value) else { throw DetectorCLIError.invalidArguments }; result.emitterSessionID = id
            case "--timeout": result.timeoutSeconds = try integer(1...300)
            case "--max-skew-ms": result.maximumSkewMS = try integer(0...10_000)
            case "--owner-pid": result.ownerPID = try integer(1...Int(Int32.max))
            case "--browser", "--browser-version":
                guard value.utf8.count <= 256, !value.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { throw DetectorCLIError.invalidArguments }
                if key == "--browser" { result.browser = value } else { result.browserVersion = value }
            default: throw DetectorCLIError.invalidArguments
            }
            index += 2
        }
        return result
    }
}
