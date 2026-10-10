import Foundation
import HarnessCore

public struct ReportEnvironment: Sendable {
    public let metadata: [String: JSONValue]
    public init(metadata: [String: JSONValue]) { self.metadata = metadata }
}
public enum ReportGenerator {
    public static func render(result: CorrelationResult, environment: ReportEnvironment) -> String {
        var lines = ["# Screen visibility measurement report", "", "## Executive summary", "",
            "Matched captures: \(result.matchedCount). Unmatched records: \(result.unmatchedCount). Indeterminate observations: \(result.indeterminateCount).",
            "Accuracy metrics require an explicit independent truth label and an unambiguous, complete enumeration measurement. Missing evidence is never success.",
            "", "## Experimental environment", "", "| Field | Value |", "| --- | --- |"]
        for key in environment.metadata.keys.sorted().prefix(100) {
            lines.append("| \(escape(key)) | \(escape(describe(environment.metadata[key]!))) |")
        }
        lines += ["", "## Methodology", "",
            "CoreGraphics queries on-screen windows with desktop elements excluded. All returned layers and system owners are inspected. ScreenCaptureKit independently enumerates on-screen shareable content with desktop windows included, only after nonprompting permission preflight.",
            "Correlation requires session, capture, window/PID, mode and source identity, rejects conflicting experiment identities, and checks bounded wall-clock skew. Monotonic comparisons require comparable clock evidence; insufficient evidence is reported. No timestamp-only joins are made.",
            "Confidence scores describe metadata completeness using fixed rules; they are not calibrated probabilities. Sharing-state zero and ScreenCaptureKit listing describe metadata and do not guarantee pixel inclusion or exclusion in third-party capture.",
            "", "## Complete visibility matrix and detector confusion counts", "",
            "| Mode | Capture source | Status | Samples with truth | TP | FP | TN | FN | Precision | Recall | Specificity | FPR | FNR |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for metric in result.metrics {
            let config = metric.configuration
            let samples = result.samples.filter { $0.configuration == config }
            let attempts = result.attempts.filter { $0.mode == config.mode && $0.source == config.source }
            let status: String
            if metric.sampleCount > 0 { status = "observed" }
            else if samples.contains(where: { $0.status == "observed" }) { status = "observed_without_truth" }
            else if samples.contains(where: { $0.status == "failed" }) || !attempts.isEmpty { status = "failed" }
            else if samples.contains(where: { $0.status == "interrupted" }) { status = "interrupted" }
            else if !samples.isEmpty { status = "indeterminate" }
            else { status = "not_tested" }
            lines.append("| \(config.mode.rawValue) | \(config.source.rawValue) | \(status) | \(metric.sampleCount) | \(metric.truePositives) | \(metric.falsePositives) | \(metric.trueNegatives) | \(metric.falseNegatives) | \(rate(metric.precision)) | \(rate(metric.recall)) | \(rate(metric.specificity)) | \(rate(metric.falsePositiveRate)) | \(rate(metric.falseNegativeRate)) |")
        }
        lines += ["", "## Recorded captures", "", "| Session | Experiment | Capture | Mode | Source | Overlay in own capture | Calibration | Detector enumeration | Status | Truth method | Confidence | Latency ms | Browser | Failure reason |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for sample in result.samples {
            lines.append("| \(sample.emitterSessionID) | \(sample.experimentID?.uuidString ?? "not_recorded") | \(sample.captureID) | \(sample.configuration.mode.rawValue) | \(sample.configuration.source.rawValue) | \(boolean(sample.overlayInCapture)) | \(escape(sample.calibrationStatus)) | \(boolean(sample.detected)) | \(escape(sample.status)) | \(sample.truth?.method.rawValue ?? "not_established") | \(number(sample.confidence)) | \(number(sample.latencyMS)) | \(escape(sample.browser + " " + sample.browserVersion)) | \(escape(sample.failureReason)) |")
        }
        lines += ["", "## Rejected and failed measurement attempts", "", "| Session | Experiment | Step | Capture | Mode | Source | Status | Reason |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for attempt in result.attempts {
            lines.append("| \(attempt.sessionID) | \(attempt.experimentID?.uuidString ?? "not_recorded") | \(attempt.stepID?.uuidString ?? "not_recorded") | \(attempt.captureID?.uuidString ?? "not_recorded") | \(attempt.mode.rawValue) | \(attempt.source?.rawValue ?? "not_recorded") | \(escape(attempt.status)) | \(escape(attempt.reason)) |")
        }
        lines += ["", "## Uncertainty and failure analysis", "", "| Condition | Count |", "| --- | --- |"]
        let counts = Dictionary(grouping: result.issues, by: { $0.code.rawValue }).mapValues(\.count)
        if counts.isEmpty { lines.append("| none reported | 0 |") }
        else { for code in counts.keys.sorted() { lines.append("| \(code) | \(counts[code]!) |") } }
        for issue in result.readIssues { lines.append("- Input diagnostic: \(issue.code.rawValue), line \(issue.line.map(String.init) ?? "not_available").") }
        lines += ["", "## Reproducibility, limitations, security and privacy", "",
            "The matrix covers modes 0–2 and all three capture sources. Capture is initiated only by the user’s registered hotkey; the detector cannot capture or change mode. Untested configurations remain explicit. Metadata-only JSONL records contain no window titles, screenshot pixels, prompt text, response text, or credentials.",
            "Public Space association is unsupported. Display association is geometric and may include multiple displays. ScreenCaptureKit permission/query failures remain explicit. Self-exclusion filters do not establish third-party invisibility. No hardware, OS version or browser is validated merely by appearing in this report.",
            "Input parsing and scan sizes are bounded. Malformed tails, unsupported schemas and incomplete scans block accuracy metrics. Cooperating file locks prevent mid-append reads; logs are neither crash-proof nor tamper-proof. The OS, swap and crash diagnostics are outside the application's absolute storage control.", ""]
        return lines.joined(separator: "\n")
    }
    private static func rate(_ value: Double?) -> String { value.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "N/A" }
    private static func number(_ value: Double?) -> String { rate(value) }
    private static func boolean(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "not_established" }
    private static func escape(_ value: String) -> String {
        let redacted = DiagnosticRedactor.redact(String(value.prefix(2048)))
        return redacted.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "`", with: "\\`")
    }
    private static func describe(_ value: JSONValue, depth: Int = 0) -> String {
        guard depth < 5 else { return "metadata_depth_limit" }
        switch value {
        case .string(let text): return String(text.prefix(2048))
        case .integer(let number): return String(number)
        case .number(let number): return number.isFinite ? String(number) : "invalid"
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "not_recorded"
        case .array(let array): return array.prefix(100).map { describe($0, depth: depth + 1) }.joined(separator: ", ")
        case .object(let object): return object.keys.sorted().prefix(40).map { "\($0)=\(describe(object[$0]!, depth: depth + 1))" }.joined(separator: "; ")
        }
    }
}
