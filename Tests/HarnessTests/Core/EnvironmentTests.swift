import Foundation
import XCTest
@testable import HarnessCore

final class EnvironmentTests: XCTestCase {
    func testOwnBundleMetadataHasPriorityOverAdjacentApp() {
        let count = MetadataReadCount()
        let probe = EnvironmentCapabilityProbe(bundleMetadata: fixture(), adjacentAppMetadata: { count.value += 1; return nil })
        let result = probe.snapshot()
        XCTAssertEqual(result["build_metadata_source"], .string("main_bundle"))
        XCTAssertEqual(result["swift"], .string("Swift fixture"))
        XCTAssertEqual(result["app_version"], .string("0.2.0"))
        XCTAssertEqual(count.value, 0)
    }

    func testPackagedCLIReadsOnlyAllowlistedAdjacentAppMetadata() throws {
        var values = fixture(); values["unexpected_private_value"] = "secret-fixture"
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let probe = EnvironmentCapabilityProbe(bundleMetadata: [:], adjacentAppMetadata: { data })
        let result = probe.snapshot()
        XCTAssertEqual(result["build_metadata_source"], .string("packaged_adjacent_app"))
        XCTAssertEqual(result["swift"], .string("Swift fixture"))
        XCTAssertEqual(result["xcode"], .string("Xcode fixture"))
        XCTAssertEqual(result["sdk"], .string("SDK fixture"))
        XCTAssertEqual(result["dependency_revisions"], .string("dependency#fixture"))
        XCTAssertNil(result["unexpected_private_value"])
        XCTAssertFalse(String(describing: result).contains("secret-fixture"))
    }

    func testUnpackagedOrInvalidMetadataIsExplicitlyUnavailable() {
        for data in [nil, Data("not a property list".utf8), Data(repeating: 0, count: 32_769)] {
            let result = EnvironmentCapabilityProbe(bundleMetadata: [:], adjacentAppMetadata: { data }).snapshot()
            XCTAssertEqual(result["build_metadata_source"], .string("not_recorded_unpackaged"))
            XCTAssertEqual(result["swift"], .string("not_recorded_unpackaged"))
            XCTAssertEqual(result["dependency_revisions"], .string("see_Package.resolved"))
        }
    }

    func testAdjacentMetadataRejectsWrongBundleAndExecutableIdentity() throws {
        for change in [("CFBundleIdentifier", "other.application"), ("CFBundleExecutable", "other-binary")] {
            var values = fixture(); values[change.0] = change.1
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            let result = EnvironmentCapabilityProbe(bundleMetadata: [:], adjacentAppMetadata: { data }).snapshot()
            XCTAssertEqual(result["build_metadata_source"], .string("not_recorded_unpackaged"))
        }
    }

    func testAdjacentMetadataRejectsMalformedOrExcessiveBuildValues() throws {
        for value: Any in [true, 42, ["nested"], String(repeating: "x", count: 2049), "", "Swift\u{0}fixture", "Swift\nfixture", "\u{1b}fixture"] {
            var values = fixture(); values["HarnessSwiftVersion"] = value
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            let result = EnvironmentCapabilityProbe(bundleMetadata: [:], adjacentAppMetadata: { data }).snapshot()
            XCTAssertEqual(result["build_metadata_source"], .string("not_recorded_unpackaged"))
        }
    }

    func testMetadataMaximumLengthIsInclusive() throws {
        var values = fixture(); values["HarnessSwiftVersion"] = String(repeating: "x", count: 2048)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let result = EnvironmentCapabilityProbe(bundleMetadata: [:], adjacentAppMetadata: { data }).snapshot()
        XCTAssertEqual(result["build_metadata_source"], .string("packaged_adjacent_app"))
        XCTAssertEqual(result["swift"]?.string?.count, 2048)
    }

    private func fixture() -> [String: Any] {
        ["CFBundleIdentifier": "org.harness.research", "CFBundleExecutable": "Harness", "CFBundleShortVersionString":"0.2.0", "HarnessSwiftVersion": "Swift fixture",
         "HarnessXcodeVersion": "Xcode fixture", "HarnessSDKVersion": "SDK fixture", "HarnessDependencies": "dependency#fixture"]
    }
}
private final class MetadataReadCount { var value = 0 }
