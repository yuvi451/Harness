import XCTest
@testable import HarnessCore

final class CLIOptionsTests: XCTestCase {
    func testDefaultsAndExplicitMeasurementOptions() throws {
        let defaults = try DetectorCLIOptions.parse(["scan"])
        XCTAssertEqual(defaults.command, .scan)
        XCTAssertEqual(defaults.maximumSkewMS, 500)
        XCTAssertEqual(defaults.timeoutSeconds, 120)
        let id = UUID()
        let value = try DetectorCLIOptions.parse(["matrix", "--emitter-session", id.uuidString,
            "--timeout", "30", "--out-dir", "/private/tmp/research", "--browser", "Safari", "--browser-version", "27"])
        XCTAssertEqual(value.emitterSessionID, id)
        XCTAssertEqual(value.timeoutSeconds, 30)
        XCTAssertEqual(value.outputDirectory.path, "/private/tmp/research")
        XCTAssertEqual(value.browser, "Safari")
    }
    func testInvalidAmbiguousAndResourceExhaustingArgumentsFail() {
        for args in [["capture"], ["scan", "--mode", "1"], ["matrix", "--timeout", "0"],
                     ["matrix", "--timeout", "301"], ["scan", "--owner-pid", "-1"],
                     ["scan", "--owner-pid", "999999999999999999999999"],
                     ["correlate", "--max-skew-ms", "10001"], ["matrix", "--emitter-session", "bad"],
                     ["scan", "--out-dir"], ["scan", "--out-dir", "/tmp", "--out-dir", "/tmp"],
                     ["scan", "--timeout", "1"], ["matrix", "--browser", String(repeating:"a",count:257)]] {
            XCTAssertThrowsError(try DetectorCLIOptions.parse(args), "\(args)")
        }
    }
    func testReadOnlyCorrelationPathsAndPrintFilter() throws {
        let options = try DetectorCLIOptions.parse(["correlate", "--audit", "/tmp/audit.jsonl", "--detections", "/tmp/detections.jsonl", "--max-skew-ms", "250"])
        XCTAssertEqual(options.auditURL.path, "/tmp/audit.jsonl")
        XCTAssertEqual(options.detectionsURL.path, "/tmp/detections.jsonl")
        XCTAssertEqual(options.maximumSkewMS, 250)
        XCTAssertEqual(try DetectorCLIOptions.parse(["scan", "--owner-pid", "42"]).ownerPID, 42)
    }

    func testMatrixCannotReplaceItsAuditInputWithItsReport() throws {
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["matrix", "--out-dir", "/private/tmp/research",
            "--audit", "/private/tmp/research/report.md"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["matrix", "--out-dir", alias.appendingPathComponent("future").path,
            "--audit", actual.appendingPathComponent("future/report.md").path]))
        let report = actual.appendingPathComponent("report.md")
        try Data("fixture".utf8).write(to: report)
        let inputAlias = actual.appendingPathComponent("audit-input.jsonl")
        try FileManager.default.linkItem(at: report, to: inputAlias)
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["matrix", "--out-dir", actual.path,
            "--audit", inputAlias.path]))
    }

    func testCorrelationCannotReplaceEitherInputWithItsReport() throws {
        for option in ["--audit", "--detections"] {
            XCTAssertThrowsError(try DetectorCLIOptions.parse(["correlate", "--out-dir", "/private/tmp/research",
                option, "/private/tmp/research/report.md"]))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["correlate", "--out-dir", alias.path,
            "--audit", actual.appendingPathComponent("report.md").path]))
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["correlate", "--out-dir", alias.appendingPathComponent("future").path,
            "--audit", actual.appendingPathComponent("future/report.md").path]))
        let report = actual.appendingPathComponent("report.md")
        try Data("fixture".utf8).write(to: report)
        let inputAlias = actual.appendingPathComponent("audit-input.jsonl")
        try FileManager.default.linkItem(at: report, to: inputAlias)
        XCTAssertThrowsError(try DetectorCLIOptions.parse(["correlate", "--out-dir", actual.path,
            "--audit", inputAlias.path]))
    }
}
