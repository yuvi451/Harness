import Foundation
import Darwin
import HarnessCore
import HarnessDetector

@main struct HarnessDetectMain {
    static let help = """
    harness-detect — visible, manually operated screen-visibility research

    scan [--out-dir PATH] [--owner-pid PID]
      Enumerate window metadata once. The PID filters printed counts only;
      every raw observation remains in detections.jsonl.
    matrix [--out-dir PATH] [--audit PATH] [--emitter-session UUID]
           [--timeout 1..300] [--browser NAME] [--browser-version VERSION]
      Walk all nine configurations. Select Settings yourself, return focus to
      your authorized test app, and physically press the configured ⌥⇧8 shortcut.
      The detector only observes audit metadata; it cannot trigger captures.
    correlate [--out-dir PATH] [--audit PATH] [--detections PATH]
              [--max-skew-ms 0..10000]
      Write report.md. Default skew is ±500 ms. Missing independent truth
      makes accuracy metrics N/A; missing experiments remain not_tested.

    Default directory: ~/Library/Application Support/harness
    --help
    """
    static func main() async {
        do {
            let options = try DetectorCLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case .help: print(help)
            case .scan: try await scan(options)
            case .matrix: try await matrix(options)
            case .correlate: try report(options)
            }
        } catch {
            let message: String
            if let error = error as? DetectorCLIError { message = error.localizedDescription }
            else if let error = error as? MatrixCoordinationError { message = error.localizedDescription }
            else if error is AuditError { message = "Metadata storage failed. Check private output permissions and incomplete JSONL tails." }
            else { message = "Detector failed. Check record schemas and read/write permissions." }
            fputs("harness-detect: \(message)\n",stderr)
            exit(1)
        }
    }
    private static func scan(_ options: DetectorCLIOptions) async throws {
        let audit = AuditLogger(sink:try POSIXAuditSink(url:options.outputDirectory.appendingPathComponent("audit.jsonl")))
        let sink = try POSIXAuditSink(url:options.detectionsURL)
        let measurement = await DetectorProbe().scan()
        try await persist(measurement,sink:sink,audit:audit,mode:0,experimentID:nil)
        printScan(measurement,ownerPID:options.ownerPID)
    }
    private static func persist(_ scan: DetectorScan,sink:POSIXAuditSink,audit:AuditLogger,mode:Int,experimentID:UUID?) async throws {
        for record in scan.records { try sink.append(record.encodeLine()) }
        try await audit.record(.init(.detectorScan,payload:["scan_id":.string(scan.scanID.uuidString),
            "n_windows":.integer(scan.observations.count),"n_flagged":.integer(scan.flaggedCount),
            "status":.string("cg_\(String(describing:scan.cgStatus))_sck_\(String(describing:scan.sckStatus))")]),mode:mode,experimentID:experimentID)
    }
    private static func printScan(_ scan: DetectorScan,ownerPID:Int? = nil) {
        let count = ownerPID.map { pid in scan.observations.filter { $0.ownerPID == pid }.count } ?? scan.observations.count
        print("Scan \(scan.scanID.uuidString): \(count) window observations\(ownerPID == nil ? "" : " matching the print filter"); \(scan.observations.count) raw observations retained.")
        print("CoreGraphics: \(String(describing:scan.cgStatus)); ScreenCaptureKit: \(String(describing:scan.sckStatus)). Metadata does not prove pixel inclusion.")
    }
    private static func report(_ options:DetectorCLIOptions) throws {
        let audit = JSONLReader.readAudit(url:options.auditURL,additionalURL:options.command == .matrix ?
            options.outputDirectory.appendingPathComponent("audit.jsonl") : nil)
        let detections = JSONLReader.readDetections(url:options.detectionsURL)
        let result = GroundTruthCorrelator.correlate(audit:audit.records,detections:detections.records,
            maxSkewMS:options.maximumSkewMS,readIssues:audit.issues + detections.issues)
        var metadata = EnvironmentCapabilityProbe().snapshot()
        metadata["operator_browser"] = .string(options.browser)
        metadata["operator_browser_version"] = .string(options.browserVersion)
        let content = ReportGenerator.render(result:result,environment:.init(metadata:metadata))
        try ProtectedReportWriter.write(content,to:options.outputDirectory.appendingPathComponent("report.md"))
        print("Saved report.md. \(audit.records.count) audit records, \(detections.records.count) detection records; \(audit.issues.count + detections.issues.count) reader issues retained in the report.")
    }
    private static func matrix(_ options:DetectorCLIOptions) async throws {
        guard isatty(STDIN_FILENO) == 1 else { throw DetectorCLIError.interactiveTerminalRequired }
        let coordinator = MatrixSessionCoordinator(emitterSessionID:options.emitterSessionID)
        let audit = AuditLogger(sink:try POSIXAuditSink(url:options.outputDirectory.appendingPathComponent("audit.jsonl")))
        let sink = try POSIXAuditSink(url:options.detectionsURL)
        print("Experiment \(coordinator.experimentID.uuidString). Remote submission may remain disabled for visibility measurements.")
        print("Show the calibration overlay in Harness Settings. Each step needs a new physical capture; this CLI sends no commands to Harness.")
        for configuration in MatrixConfiguration.all {
            var stepID = UUID()
            print("\nSelect \(configuration.mode.badge), source \(configuration.source.rawValue), and Save Settings. Selected-window mode also needs a target.")
            print("Press Enter when saved, or q to finish with remaining cells not_tested.")
            guard try continueFromTerminal() else { break }
            do {
                let records = try verifiedAudit(options.auditURL)
                // Only metadata is delayed. This timer never initiates capture.
                try await Task.sleep(nanoseconds:200_000_000)
                let arm = try coordinator.arm(configuration:configuration,records:records,nowMonotonicNS:Int(DispatchTime.now().uptimeNanoseconds))
                stepID = arm.stepID
                print("Armed step \(arm.stepID.uuidString). Return focus to your test application and physically press the configured capture key once (⌥⇧8 by default).")
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(options.timeoutSeconds) * 1_000_000_000
                let start = try await waitForStart(coordinator:coordinator,arm:arm,url:options.auditURL,deadline:deadline)
                guard let captureText = start.payload["capture_id"]?.string, let captureID = UUID(uuidString:captureText),
                      let windowID = start.payload["window_id"]?.int, let ownerPID = start.payload["owner_pid"]?.int else { throw DetectorCLIError.invalidRecords }
                let context = ScanContext(emitterSessionID:arm.emitterSessionID,experimentID:arm.experimentID,
                    stepID:arm.stepID,captureID:captureID,targetWindowID:windowID,ownerPID:ownerPID,
                    mode:configuration.mode,source:configuration.source,browser:options.browser,browserVersion:options.browserVersion)
                // Observe promptly after capture_started, rather than after slow image/network work.
                let observationNow = DispatchTime.now().uptimeNanoseconds
                let remainingNS = deadline > observationNow ? deadline - observationNow : 0
                let remainingSeconds = min(5,Double(remainingNS) / 1_000_000_000)
                let measurement = await DetectorProbe(enumerator:NativeWindowEnumerator(sckTimeoutSeconds:remainingSeconds)).scan(context:context)
                try await persist(measurement,sink:sink,audit:audit,mode:configuration.mode.rawValue,experimentID:arm.experimentID)
                // Read the terminal at least once even if metadata enumeration used
                // the remaining deadline; a timely capture must not become a timeout.
                var terminal = try coordinator.finish(arm:arm,start:start,records:verifiedAudit(options.auditURL))
                while terminal == nil && DispatchTime.now().uptimeNanoseconds < deadline {
                    terminal = try coordinator.finish(arm:arm,start:start,records:verifiedAudit(options.auditURL))
                    if terminal == nil { try await Task.sleep(nanoseconds:100_000_000) }
                }
                guard let terminal else { throw DetectorCLIError.measurementTimedOut }
                try await audit.record(.init(.matrixStepCompleted,payload:["capture_id":.string(terminal.captureID.uuidString),
                    "step_id":.string(terminal.stepID.uuidString),"scan_id":.string(measurement.scanID.uuidString),
                    "window_id":.integer(terminal.windowID),"owner_pid":.integer(terminal.ownerPID),"source":.string(terminal.source.rawValue),
                    "status":.string(terminal.outcome.rawValue),"calibration_status":.string(terminal.calibrationStatus),
                    "calibration_reason":.string(terminal.reason),"confidence":terminal.calibrationConfidence.map(JSONValue.number) ?? .null,
                    "browser":.string(options.browser),"browser_version":.string(options.browserVersion)]),mode:terminal.mode.rawValue,experimentID:terminal.experimentID)
                print("Capture \(terminal.captureID.uuidString): \(terminal.outcome.rawValue); calibration \(terminal.calibrationStatus).")
                printScan(measurement)
            } catch {
                if error is AuditError { throw error }
                try await audit.record(.init(.experimentFailed,payload:["source":.string(configuration.source.rawValue),
                    "step_id":.string(stepID.uuidString),"status":.string("not_completed"),"reason":.string("manual_measurement_invalid_or_timed_out")]),mode:configuration.mode.rawValue,experimentID:coordinator.experimentID)
                if let error = error as? MatrixCoordinationError { print(error.localizedDescription) }
                else if let error = error as? DetectorCLIError { print(error.localizedDescription) }
                else { print("Measurement interrupted; no successful sample is claimed.") }
                let launches = JSONLReader.readAudit(url:options.auditURL).records.filter { $0.event == .appLaunch }
                if options.emitterSessionID == nil && launches.count > 1 {
                    print("Select an emitter explicitly with --emitter-session: \(launches.map { $0.sessionID.uuidString }.joined(separator:", "))")
                }
            }
            print("Press Enter to continue, or q to finish.")
            guard try continueFromTerminal() else { break }
        }
        try report(options)
    }
    private static func verifiedAudit(_ url:URL) throws -> [AuditRecord] {
        let result = JSONLReader.readAudit(url:url)
        guard result.issues.isEmpty, !result.records.isEmpty else { throw DetectorCLIError.invalidRecords }
        return result.records
    }
    private static func waitForStart(coordinator:MatrixSessionCoordinator,arm:MatrixArm,url:URL,deadline:UInt64) async throws -> AuditRecord {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let start = try coordinator.nextCaptureStart(arm:arm,records:verifiedAudit(url)) { return start }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw DetectorCLIError.measurementTimedOut
    }
    private static func continueFromTerminal() throws -> Bool {
        fflush(stdout)
        var bytes = [UInt8](); var interruptions = 0
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO,&byte,1)
            if count == 0 { return false }
            if count < 0 {
                if errno == EINTR && interruptions < 100 { interruptions += 1; continue }
                throw DetectorCLIError.interactiveTerminalRequired
            }
            interruptions = 0
            if byte == 10 { break }
            guard bytes.count < 4096 else { throw DetectorCLIError.inputTooLong }
            bytes.append(byte)
        }
        let answer = String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        return answer != "q" && answer != "quit"
    }
}
