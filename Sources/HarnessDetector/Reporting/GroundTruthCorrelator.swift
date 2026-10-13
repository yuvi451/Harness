import Foundation
import HarnessCore

public struct CorrelationIssue: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unmatchedDetection = "unmatched_detection", missingCapture = "missing_capture", ambiguous
        case identityConflict = "identity_conflict", experimentConflict = "experiment_conflict", windowIDReuse = "window_id_reuse"
        case timestampSkew = "timestamp_skew", clockChange = "clock_change", clockEvidenceInsufficient = "clock_evidence_insufficient"
        case duplicateRecord = "duplicate_record", duplicateConflict = "duplicate_conflict", interruptedCapture = "interrupted_capture"
        case unsupported, missingTruth = "missing_truth", invalidRecord = "invalid_record", incompleteScan = "incomplete_scan", readIssue = "read_issue"
        case rejectedAttempt = "rejected_attempt", captureFailed = "capture_failed"
    }
    public let code: Code
    public let scanID: UUID?
    public let captureID: UUID?
    public init(code: Code, scanID: UUID? = nil, captureID: UUID? = nil) { self.code = code; self.scanID = scanID; self.captureID = captureID }
}
public struct ConfigurationMetrics: Sendable {
    public let configuration: MatrixConfiguration
    public let truePositives, falsePositives, trueNegatives, falseNegatives: Int
    public var sampleCount: Int { truePositives + falsePositives + trueNegatives + falseNegatives }
    public var precision: Double? { ratio(truePositives, truePositives + falsePositives) }
    public var recall: Double? { ratio(truePositives, truePositives + falseNegatives) }
    public var specificity: Double? { ratio(trueNegatives, trueNegatives + falsePositives) }
    public var falsePositiveRate: Double? { ratio(falsePositives, falsePositives + trueNegatives) }
    public var falseNegativeRate: Double? { ratio(falseNegatives, falseNegatives + truePositives) }
    public init(configuration: MatrixConfiguration, truePositives: Int = 0, falsePositives: Int = 0, trueNegatives: Int = 0, falseNegatives: Int = 0) {
        self.configuration = configuration; self.truePositives = truePositives; self.falsePositives = falsePositives
        self.trueNegatives = trueNegatives; self.falseNegatives = falseNegatives
    }
    private func ratio(_ numerator: Int, _ denominator: Int) -> Double? { denominator == 0 ? nil : Double(numerator) / Double(denominator) }
}
public struct CorrelatedSample: Sendable {
    public let captureID, emitterSessionID: UUID
    public let experimentID: UUID?
    public let configuration: MatrixConfiguration
    public let scanID: UUID?
    public let detected: Bool?
    public let truth: IndependentTruth?
    public let calibrationStatus: String
    public let overlayInCapture: Bool?
    public let status: String
    public let browser, browserVersion: String
    public let confidence: Double?
    public let latencyMS: Double?
    public let failureReason: String
}
public struct CorrelationResult: Sendable {
    public let metrics: [ConfigurationMetrics]
    public let issues: [CorrelationIssue]
    public let samples: [CorrelatedSample]
    public let matchedCount, unmatchedCount, indeterminateCount: Int
    public let readIssues: [JSONLReadIssue]
    public let attempts: [RejectedMeasurementAttempt]
    public init(metrics: [ConfigurationMetrics], issues: [CorrelationIssue], samples: [CorrelatedSample] = [], matchedCount: Int,
                unmatchedCount: Int, indeterminateCount: Int, readIssues: [JSONLReadIssue] = [], attempts: [RejectedMeasurementAttempt] = []) {
        self.metrics = metrics; self.issues = issues; self.samples = samples; self.matchedCount = matchedCount
        self.unmatchedCount = unmatchedCount; self.indeterminateCount = indeterminateCount; self.readIssues = readIssues
        self.attempts = attempts
    }
}
public struct RejectedMeasurementAttempt: Sendable {
    public let recordID, sessionID: UUID
    public let experimentID, stepID, captureID: UUID?
    public let mode: VisibilityMode
    public let source: CaptureSource?
    public let reason, status: String
    public init(recordID: UUID, sessionID: UUID, experimentID: UUID? = nil, stepID: UUID? = nil, captureID: UUID? = nil,
                mode: VisibilityMode, source: CaptureSource? = nil, reason: String, status: String = "failed") {
        self.recordID = recordID; self.sessionID = sessionID; self.experimentID = experimentID; self.stepID = stepID
        self.captureID = captureID; self.mode = mode; self.source = source; self.reason = reason; self.status = status
    }
}

public enum GroundTruthCorrelator {
    private struct CaptureKey: Hashable { let session: UUID; let capture: UUID }
    public static func correlate(audit: [AuditRecord], detections: [DetectionRecord], maxSkewMS: Int = 500,
                                 readIssues: [JSONLReadIssue] = []) -> CorrelationResult {
        var issues: [CorrelationIssue] = [], unmatched = 0, indeterminate = 0, matched = 0
        var fatalDataset = !readIssues.isEmpty || !(0...60_000).contains(maxSkewMS) || audit.count > 100_000 || detections.count > 100_000
        if !readIssues.isEmpty { issues.append(.init(code: .readIssue)) }
        if !(0...60_000).contains(maxSkewMS) || audit.count > 100_000 || detections.count > 100_000 { issues.append(.init(code: .invalidRecord)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var auditByID: [UUID: (AuditRecord, Data)] = [:], detectionByID: [UUID: (DetectionRecord, Data)] = [:]
        var invalidAuditIDs: Set<UUID> = [], invalidDetectionIDs: Set<UUID> = []
        for record in audit.prefix(100_000) {
            do {
                let data = try encoder.encode(record); _ = try AuditRecord.decode(data)
                if let old = auditByID[record.eventID] {
                    let equal = old.1 == data; issues.append(.init(code: equal ? .duplicateRecord : .duplicateConflict))
                    if !equal { invalidAuditIDs.insert(record.eventID); fatalDataset = true }
                } else { auditByID[record.eventID] = (record, data) }
            } catch { issues.append(.init(code: .invalidRecord)); fatalDataset = true }
        }
        for record in detections.prefix(100_000) {
            do {
                try record.validate(); let data = try encoder.encode(record); _ = try DetectionRecord.decode(data)
                if let old = detectionByID[record.recordID] {
                    let equal = old.1 == data; issues.append(.init(code: equal ? .duplicateRecord : .duplicateConflict, scanID: record.scanID))
                    if !equal { invalidDetectionIDs.insert(record.recordID); fatalDataset = true }
                } else { detectionByID[record.recordID] = (record, data) }
            } catch { issues.append(.init(code: .invalidRecord, scanID: record.scanID)); fatalDataset = true }
        }
        var audits: [AuditRecord] = []
        for pair in auditByID.values where !invalidAuditIDs.contains(pair.0.eventID) { audits.append(pair.0) }
        audits.sort { left, right in
            if left.sessionID == right.sessionID { return left.sequence < right.sequence }
            return left.sessionID.uuidString < right.sessionID.uuidString
        }
        var detectorRecords: [DetectionRecord] = []
        for pair in detectionByID.values where !invalidDetectionIDs.contains(pair.0.recordID) { detectorRecords.append(pair.0) }
        var badClockSessions: Set<UUID> = []
        let auditsBySession: [UUID: [AuditRecord]] = Dictionary(grouping: audits, by: { $0.sessionID })
        for (session, records) in auditsBySession {
            var previousSequence = 0, previousClock: (Date, Int)?
            for record in records {
                if record.sequence <= previousSequence { fatalDataset = true; issues.append(.init(code: .invalidRecord)) }
                previousSequence = record.sequence
                if let mono = record.payload["monotonic_ns"]?.int, let wall = parseTimestamp(record.ts) {
                    guard mono >= 0 else { badClockSessions.insert(session); continue }
                    if let old = previousClock {
                        let wallDelta = wall.timeIntervalSince(old.0) * 1000
                        let monoDelta = (Double(mono) - Double(old.1)) / 1_000_000
                        if mono < old.1 || abs(wallDelta - monoDelta) > Double(maxSkewMS) {
                            badClockSessions.insert(session)
                        }
                    }
                    previousClock = (wall, mono)
                }
            }
        }
        var captures: [CaptureKey: [AuditRecord]] = [:], attempts: [RejectedMeasurementAttempt] = []
        func rejectedAttempt(_ record: AuditRecord) -> RejectedMeasurementAttempt {
            RejectedMeasurementAttempt(recordID: record.eventID, sessionID: record.sessionID, experimentID: record.experimentID,
                stepID: record.payload["step_id"]?.string.flatMap(UUID.init(uuidString:)),
                captureID: record.payload["capture_id"]?.string.flatMap(UUID.init(uuidString:)),
                mode: VisibilityMode(rawValue: record.mode)!, source: record.payload["source"]?.string.flatMap(CaptureSource.init(rawValue:)),
                reason: safeReason(record.payload["reason"]?.string ?? "reason_not_recorded"),
                status: record.event == .captureFailed ? "rejected" : "failed")
        }
        for record in audits where record.event == .experimentFailed {
            attempts.append(rejectedAttempt(record)); issues.append(.init(code: .rejectedAttempt))
        }
        for record in audits where [.captureStarted,.captureCompleted,.captureFailed].contains(record.event) {
            guard let raw = record.payload["capture_id"]?.string, let id = UUID(uuidString: raw) else {
                if record.event == .captureFailed, record.payload["capture_id"] == nil {
                    attempts.append(rejectedAttempt(record)); issues.append(.init(code: .rejectedAttempt)); continue
                }
                issues.append(.init(code: .invalidRecord)); fatalDataset = true; continue
            }
            captures[CaptureKey(session: record.sessionID, capture: id), default: []].append(record)
        }
        var validScans: [DetectionRecord] = [], rowsByScan: [UUID: [WindowObservation]] = [:]
        for (scanID, group) in Dictionary(grouping: detectorRecords, by: \.scanID).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let summaries = group.filter { $0.kind == .scanSummary }
            guard summaries.count == 1, let summary = summaries.first else {
                issues.append(.init(code: .incompleteScan, scanID: scanID)); indeterminate += 1; continue
            }
            let rows = group.filter { $0.kind == .window }
            guard rows.count == summary.windowCount, group.allSatisfy({ consistent($0, summary) }) else {
                issues.append(.init(code: .incompleteScan, scanID: scanID)); indeterminate += 1; continue
            }
            let observations = rows.compactMap(\.observation)
            guard observations.count == summary.windowCount else { issues.append(.init(code: .incompleteScan, scanID: scanID)); indeterminate += 1; continue }
            let windowIDs = observations.compactMap(\.windowID)
            guard Set(windowIDs).count == windowIDs.count else {
                issues.append(.init(code: .incompleteScan, scanID: scanID)); indeterminate += 1; continue
            }
            let actualFlagged = observations.filter { $0.classifications.contains(where: { [.legacyNonsharingSignal,.metadataIncomplete,.unknown,.unsupported].contains($0) }) }.count
            guard actualFlagged == summary.flaggedCount else { issues.append(.init(code: .incompleteScan, scanID: scanID)); indeterminate += 1; continue }
            validScans.append(summary); rowsByScan[scanID] = observations
        }
        var scansByCapture: [CaptureKey: [DetectionRecord]] = [:]
        for scan in validScans {
            guard let context = scan.context else { issues.append(.init(code: .unmatchedDetection, scanID: scan.scanID)); unmatched += 1; continue }
            let key = CaptureKey(session: context.emitterSessionID, capture: context.captureID)
            guard captures[key] != nil else { issues.append(.init(code: .missingCapture, scanID: scan.scanID, captureID: key.capture)); unmatched += 1; continue }
            scansByCapture[key, default: []].append(scan)
        }
        var counts: [MatrixConfiguration: [Int]] = [:], samples: [CorrelatedSample] = []
        for (key, records) in captures.sorted(by: { $0.key.session.uuidString + $0.key.capture.uuidString < $1.key.session.uuidString + $1.key.capture.uuidString }) {
            let starts = records.filter { $0.event == .captureStarted }, terminals = records.filter { $0.event != .captureStarted }
            if starts.isEmpty {
                for failure in terminals where failure.event == .captureFailed { attempts.append(rejectedAttempt(failure)) }
                issues.append(.init(code: .missingCapture, captureID: key.capture)); unmatched += 1; continue
            }
            guard starts.count == 1, let start = starts.first, let mode = VisibilityMode(rawValue: start.mode),
                  let rawSource = start.payload["source"]?.string, let source = CaptureSource(rawValue: rawSource) else {
                issues.append(.init(code: .ambiguous, captureID: key.capture)); indeterminate += 1; continue
            }
            let configuration = MatrixConfiguration(mode: mode, source: source)
            let scans = scansByCapture[key] ?? [], scan = scans.count == 1 ? scans.first : nil
            var detected: Bool?, status = "indeterminate", sampleTruth: IndependentTruth?
            let terminal = terminals.count == 1 ? terminals.first : nil
            func add(_ code: CorrelationIssue.Code) { issues.append(.init(code: code, scanID: scan?.scanID, captureID: key.capture)) }
            if terminals.count > 1 {
                add(.ambiguous); indeterminate += 1
            } else if terminal == nil {
                add(.interruptedCapture); indeterminate += 1; status = "interrupted"
            } else if terminal?.event == .captureFailed {
                add(.captureFailed); indeterminate += 1; status = "failed"
            } else if scans.isEmpty { add(.unmatchedDetection); unmatched += 1; status = "missing_scan" }
            else if scans.count > 1 { add(.ambiguous); indeterminate += 1 }
            else if let scan, let context = scan.context, let terminal {
                let identities = ["window_id","owner_pid","source"]
                let displayConflict = start.payload["display_id"]?.int != nil && terminal.payload["display_id"] != nil &&
                    start.payload["display_id"] != terminal.payload["display_id"]
                if terminal.sequence <= start.sequence || terminal.mode != start.mode ||
                    displayConflict ||
                    identities.contains(where: { start.payload[$0] == nil || terminal.payload[$0] != start.payload[$0] }) ||
                    start.payload["window_id"]?.int != context.targetWindowID || start.payload["owner_pid"]?.int != context.ownerPID ||
                    start.mode != context.mode.rawValue || rawSource != context.source.rawValue ||
                    (context.captureMonotonicNS != nil && context.captureMonotonicNS != start.payload["monotonic_ns"]?.int) {
                    add(.identityConflict); indeterminate += 1
                } else if conflictingExperiment(start, terminal, context) { add(.experimentConflict); indeterminate += 1 }
                else if badClockSessions.contains(key.session) { add(.clockChange); indeterminate += 1 }
                else if let scanTime = parseTimestamp(scan.ts), let captureTime = parseTimestamp(start.ts) {
                    let wallSkew = scanTime.timeIntervalSince(captureTime) * 1000
                    var clockConflict = false
                    if let domain = scan.clockDomainID, domain == context.clockDomainID,
                       let scanMono = scan.monotonicNS, let captureMono = context.captureMonotonicNS {
                        let monoSkew = (Double(scanMono) - Double(captureMono)) / 1_000_000
                        clockConflict = abs(wallSkew - monoSkew) > Double(maxSkewMS)
                    } else { add(.clockEvidenceInsufficient) }
                    if clockConflict { add(.clockChange); indeterminate += 1 }
                    else if abs(wallSkew) > Double(maxSkewMS) { add(.timestampSkew); indeterminate += 1 }
                    else if scan.cgStatus != .success || scan.truncated || !scan.errors.isEmpty {
                        add(.unsupported); indeterminate += 1
                    } else {
                        let rows = rowsByScan[scan.scanID] ?? []
                        let sameID = rows.filter { $0.windowID == context.targetWindowID }
                        if sameID.contains(where: { $0.ownerPID != context.ownerPID }) { add(.windowIDReuse); indeterminate += 1 }
                        else if sameID.count > 1 { add(.ambiguous); indeterminate += 1 }
                        else if rows.contains(where: { $0.windowID == nil || $0.ownerPID == nil }) { add(.unsupported); indeterminate += 1 }
                        else {
                            detected = !sameID.isEmpty; matched += 1; status = fatalDataset ? "indeterminate" : "observed"
                            if fatalDataset { indeterminate += 1 }
                            sampleTruth = context.independentTruth
                            if let truth = sampleTruth, !fatalDataset {
                                var values = counts[configuration] ?? [0,0,0,0]
                                let index = truth.value ? (detected! ? 0 : 3) : (detected! ? 1 : 2)
                                values[index] += 1; counts[configuration] = values
                            } else if sampleTruth == nil { add(.missingTruth) }
                        }
                    }
                } else { add(.invalidRecord); indeterminate += 1 }
            }
            samples.append(CorrelatedSample(captureID: key.capture, emitterSessionID: key.session,
                experimentID: scan?.context?.experimentID ?? start.experimentID, configuration: configuration, scanID: scan?.scanID,
                detected: detected, truth: sampleTruth, calibrationStatus: terminal?.payload["calibration_status"]?.string ?? "indeterminate",
                overlayInCapture: terminal?.payload["overlay_in_capture"]?.boolean, status: status,
                browser: scan?.context?.browser ?? "not_recorded", browserVersion: scan?.context?.browserVersion ?? "not_recorded",
                confidence: detected == nil ? nil : 1, latencyMS: scan?.latencyMS,
                failureReason: safeReason(terminal?.payload["reason"]?.string ?? (status == "observed" ? "none" : status))))
        }
        let metrics = MatrixConfiguration.all.map { configuration -> ConfigurationMetrics in
            let values = fatalDataset ? [0,0,0,0] : counts[configuration] ?? [0,0,0,0]
            return ConfigurationMetrics(configuration: configuration, truePositives: values[0], falsePositives: values[1], trueNegatives: values[2], falseNegatives: values[3])
        }
        return CorrelationResult(metrics: metrics, issues: issues, samples: samples, matchedCount: matched,
            unmatchedCount: unmatched, indeterminateCount: indeterminate, readIssues: readIssues, attempts: attempts)
    }
    private static func consistent(_ row: DetectionRecord, _ summary: DetectionRecord) -> Bool {
        row.detectorSessionID == summary.detectorSessionID && row.ts == summary.ts && row.context == summary.context &&
        row.monotonicNS == summary.monotonicNS && row.clockDomainID == summary.clockDomainID &&
        row.cgStatus == summary.cgStatus && row.sckStatus == summary.sckStatus && row.windowCount == summary.windowCount &&
        row.flaggedCount == summary.flaggedCount && row.truncated == summary.truncated && row.errors == summary.errors &&
        row.latencyMS == summary.latencyMS && row.cgFilters == summary.cgFilters && row.sckFilters == summary.sckFilters
        && row.sckTS == summary.sckTS && row.cgLatencyMS == summary.cgLatencyMS && row.sckLatencyMS == summary.sckLatencyMS
    }
    private static func conflictingExperiment(_ start: AuditRecord, _ terminal: AuditRecord, _ context: ScanContext) -> Bool {
        let ids = [start.experimentID, terminal.experimentID, context.experimentID].compactMap { $0 }
        if Set(ids).count > 1 { return true }
        let steps = [start.payload["step_id"]?.string, terminal.payload["step_id"]?.string].compactMap { $0 }
        return steps.contains { UUID(uuidString: $0) == nil || UUID(uuidString: $0) != context.stepID }
    }
    private static func safeReason(_ value: String) -> String {
        let clean = DiagnosticRedactor.redact(String(value.prefix(256)))
        return clean.components(separatedBy: CharacterSet.controlCharacters).joined()
    }
}
