import Foundation
import CoreGraphics
import HarnessCore

/// Explicit command-line connectivity check. Generates an in-memory white JPEG;
/// never reads the screen, clipboard, files or other applications' pixels.
@MainActor public enum SyntheticAccountDiagnostic {
    public static func run() async -> Int32 {
        let privacy = PrivacyController()
        do {
            let audit = AuditLogger(sink: try POSIXAuditSink(url: POSIXAuditSink.defaultURL))
            let account = ChatGPTAccountController()
            let token = try await account.accessToken()
            var settings = Settings(); settings.networkSubmissionEnabled = true; settings.historyLength = 0
            guard let context = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageProcessingError.allocationFailed }
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:64))
            guard let image = context.makeImage() else { throw ImageProcessingError.allocationFailed }
            let processed = try ImageProcessor().process(image, settings: settings)
            try await privacy.grantConsent(acknowledged: true)
            let result = try await RemoteSubmissionService(privacy:privacy,audit:audit).submit(image:processed,
                settings:settings,prompt:"Connection diagnostic with a generated white image. Reply with just OK.",
                captureID:UUID(),credential:token,source:settings.captureSource,selectedWindowID:nil,onText:{ _,_ in })
            print("ChatGPT synthetic-image connection succeeded; response characters: \(result.response.count); stop: \(result.completion.stopReason).")
            await privacy.terminate(); return 0
        } catch {
            await privacy.terminate()
            if let error = error as? ChatGPTProviderError { print(error.localizedDescription) }
            else if let error = error as? ChatGPTAuthenticationError { print(error.localizedDescription) }
            else { print("Connection check failed (\(String(reflecting:type(of:error)))).") }
            return 1
        }
    }
}
