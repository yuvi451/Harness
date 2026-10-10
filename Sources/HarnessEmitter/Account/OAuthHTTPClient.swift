import Foundation

@MainActor final class EphemeralOAuthHTTPClient: OAuthHTTPClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        guard request.url?.scheme == "https", request.url?.host == "auth.openai.com" else { throw ChatGPTAuthenticationError.transportFailure }
        let control = RequestControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: control)
            defer { bytes.task.cancel(); control.releaseTask(bytes.task) }
            guard let http = response as? HTTPURLResponse, http.url?.host == "auth.openai.com", !(300...399).contains(http.statusCode),
                  response.expectedContentLength <= 262_144 else { throw ChatGPTAuthenticationError.transportFailure }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 262_144 else { throw ChatGPTAuthenticationError.malformedResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return OAuthHTTPResponse(status: http.statusCode, data: data)
        }, onCancel: { control.cancel() })
    }
}
