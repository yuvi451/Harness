// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Harness", platforms: [.macOS(.v14)], products: [
 .executable(name: "harness", targets: ["HarnessApp"]),
 .executable(name: "harness-detect", targets: ["HarnessDetect"])
], dependencies: [
 .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", exact: "4.2.2")
], targets: [
 .target(name: "HarnessCore"),
 .target(name: "NativeKeychain", linkerSettings: [.linkedFramework("Security")]),
 .target(name: "HarnessEmitter", dependencies: ["HarnessCore", "NativeKeychain", "KeychainAccess"], resources: [.copy("Resources/Fonts")]),
 .target(name: "HarnessDetector", dependencies: ["HarnessCore"]),
 .executableTarget(name: "HarnessApp", dependencies: ["HarnessEmitter"]),
 .executableTarget(name: "HarnessDetect", dependencies: ["HarnessCore", "HarnessDetector"]),
 .target(name: "LockTestSupport", path: "Tests/LockTestSupport"),
 .testTarget(name: "HarnessTests", dependencies: ["HarnessCore", "HarnessEmitter", "HarnessDetector", "LockTestSupport", "NativeKeychain"])
])
