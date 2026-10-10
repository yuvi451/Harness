import Foundation

/// Defense in depth for diagnostic text, not permission to log request bodies or screenshot data.
/// Supply any retrieved credentials as knownSecrets; arbitrary formats cannot all be inferred.
public struct DiagnosticRedactor: Sendable {
    private let knownSecrets: [String]
    public init(knownSecrets: [String] = []) {
        self.knownSecrets = knownSecrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in knownSecrets {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // Header lines and quoted JSON fields are both covered. Include Basic/custom auth,
        // not just Bearer, so unknown credentials in an Authorization header are also removed.
        let patterns: [(String, String)] = [
            (#"(?i)(\"?authorization\"?\s*[:=]\s*\"?)[^\r\n\",}]+"#, "$1[REDACTED]"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (#"(?i)([\"']?(?:api[_-]?key|x-api-key|access[_-]?token|secret|password)[\"']?\s*[:=]\s*[\"']?)[^\s\"'&,;}]+"#, "$1[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]+"#, "[REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: replacement)
        }
        return result
    }

    public static func redact(_ text: String, knownSecrets: [String] = []) -> String {
        DiagnosticRedactor(knownSecrets: knownSecrets).redact(text)
    }
}

/// No persistent caches/cookies or background/file-backed transfers. Consumers must submit
/// request bodies from memory using data/stream tasks; never use uploadTask(fromFile:).
public enum PrivacyNetworkConfiguration {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        return configuration
    }

    public static func makeSession(delegate: (any URLSessionDelegate)? = nil,
                                   delegateQueue: OperationQueue? = nil) -> URLSession {
        URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: delegateQueue)
    }
}
