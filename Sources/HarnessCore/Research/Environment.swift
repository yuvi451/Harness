import Foundation
import Darwin

public struct EnvironmentCapabilityProbe {
    private let bundleMetadata: [String: Any]
    private let adjacentAppMetadata: () -> Data?
    public init() {
        bundleMetadata = Bundle.main.infoDictionary ?? [:]
        adjacentAppMetadata = Self.readAdjacentAppMetadata
    }
    /// Inject metadata bytes without touching an app bundle or hardware in tests.
    public init(bundleMetadata: [String: Any], adjacentAppMetadata: @escaping () -> Data?) {
        self.bundleMetadata = bundleMetadata; self.adjacentAppMetadata = adjacentAppMetadata
    }
    public func snapshot() -> [String: JSONValue] {
        let system = NSDictionary(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"))
        var name = utsname(); uname(&name)
        let kernel = withUnsafePointer(to: &name.release) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var metadata = Self.validatedMetadata(bundleMetadata)
        var source = metadata == nil ? "not_recorded_unpackaged" : "main_bundle"
        if metadata == nil, let data = adjacentAppMetadata(), data.count <= 32_768,
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let adjacent = Self.validatedMetadata(object) {
            metadata = adjacent; source = "packaged_adjacent_app"
        }
        return ["macos_product_version": .string(system?["ProductVersion"] as? String ?? "unavailable"),
                "os_build": .string(system?["ProductBuildVersion"] as? String ?? "unavailable"),
                "kernel": .string(kernel), "architecture": .string(architecture),
                "app_version": .string(metadata?["CFBundleShortVersionString"] ?? "development"),
                "swift": .string(metadata?["HarnessSwiftVersion"] ?? "not_recorded_unpackaged"),
                "xcode": .string(metadata?["HarnessXcodeVersion"] ?? "not_recorded_unpackaged"),
                "sdk": .string(metadata?["HarnessSDKVersion"] ?? "not_recorded_unpackaged"),
                "dependency_revisions": .string(metadata?["HarnessDependencies"] ?? "see_Package.resolved"),
                "build_metadata_source": .string(source),
                "runtime_validation": .string("not_tested")]
    }
    private static func validatedMetadata(_ object: [String: Any]) -> [String: String]? {
        guard object["CFBundleIdentifier"] as? String == "org.harness.research",
              object["CFBundleExecutable"] as? String == "Harness" else { return nil }
        var selected: [String: String] = [:]
        for key in ["HarnessSwiftVersion", "HarnessXcodeVersion", "HarnessSDKVersion", "HarnessDependencies"] {
            guard let value = object[key] as? String, value.utf8.count <= 2048,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            selected[key] = value
        }
        if let version = object["CFBundleShortVersionString"] as? String,
           version.range(of:"^[0-9]+\\.[0-9]+\\.[0-9]+$",options:.regularExpression) != nil, version.utf8.count <= 32 {
            selected["CFBundleShortVersionString"] = version
        }
        return selected
    }
    /// The detector distribution has exactly one known companion app. No searching,
    /// arbitrary metadata paths, auth files or home-directory discovery is performed.
    private static func readAdjacentAppMetadata() -> Data? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let directory = executable.deletingLastPathComponent().standardizedFileURL
        let base = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { return nil }; defer { close(base) }
        let app = openat(base, "Harness.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard app >= 0 else { return nil }; defer { close(app) }
        let contents = openat(app, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { return nil }; defer { close(contents) }
        let fd = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 32_768 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0, interruptions = 0
        let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR && interruptions < 100 { interruptions += 1; continue }; return false }
                guard count > 0 else { return false }; offset += count
                interruptions = 0
            }
            return true
        }
        return complete ? Data(bytes) : nil
    }
}
