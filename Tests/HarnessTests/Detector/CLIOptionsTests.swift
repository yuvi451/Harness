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
}
