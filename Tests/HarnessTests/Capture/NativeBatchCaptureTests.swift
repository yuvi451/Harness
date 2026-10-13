import AppKit
import CoreGraphics
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class NativeBatchCaptureTests: XCTestCase {
    func testActualSelectedWindowCapturesQueueTwoSeparateFrames() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_NATIVE_CAPTURE_TESTS"] == "1" else { throw XCTSkip("Actual capture opt-in") }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen Recording is not granted to the test host; no permission prompt was requested") }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSPanel(contentRect:CGRect(x:screen.visibleFrame.midX-300,y:screen.visibleFrame.midY-120,width:600,height:240),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.backgroundColor = .white;window.hasShadow = false
        window.hidesOnDeactivate = false;window.animationBehavior = .none;window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let label = NSTextField(labelWithString:"Simple loops and arrays solve this problem")
        label.font = NSFont(name:"Menlo-Regular",size:18);label.textColor = .black;label.frame = CGRect(x:20,y:100,width:560,height:40)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless();defer { window.close() }
        try await Task.sleep(nanoseconds:100_000_000)
        var settings = Settings();settings.captureSource = .selectedWindow;settings.selectedWindowID = UInt32(window.windowNumber)
        let engine = ScreenCaptureEngine(),queue = ScreenshotBatch()
        for cycle in 0..<5 {
          for color in [NSColor.white,NSColor(srgbRed:0.25,green:0.3,blue:0.4,alpha:1)] {
            window.backgroundColor = color;window.displayIfNeeded()
            try await Task.sleep(nanoseconds:100_000_000)
            let frame = try await engine.capture(settings:settings)
            XCTAssertEqual(frame.selectedWindowID,settings.selectedWindowID)
            if cycle == 0 && color == .white {
                if let path = ProcessInfo.processInfo.environment["HARNESS_FONT_FIXTURE_PATH"] {
                    try XCTUnwrap(NSBitmapImageRep(cgImage:frame.image).representation(using:.png,properties:[:]))
                        .write(to:URL(fileURLWithPath:path))
                }
                let estimate = await Task.detached { TypographyDetector.analyze(image:frame.image,
                    pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:frame.capturedBounds.width) }.value
                let matched = try XCTUnwrap(estimate)
                XCTAssertTrue(matched.fontName.contains("Menlo"));XCTAssertEqual(matched.pointSize,18,accuracy:2)
            }
            let image = try ImageProcessor().process(frame.image,settings:settings)
            try queue.append(.init(id:UUID(),image:image),settings:settings)
          }
          let entries = try queue.take(settings:settings)
          XCTAssertEqual(entries.count,2);XCTAssertNotEqual(entries[0].image.sha256,entries[1].image.sha256)
          XCTAssertEqual(queue.retainedByteCount,0)
        }
    }
}
