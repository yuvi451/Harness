import Foundation
import AppKit
import Network

/// Binds exclusively to IPv4 loopback; authorization callbacks are ephemeral memory.
@MainActor final class LoopbackOAuthBrowser: OAuthBrowserAuthenticating {
    private let openAuthorization: (URL) -> Bool
    private let callbackTimeoutSeconds: Double
    private let queue = DispatchQueue(label: "org.harness.research.oauth.loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var redirect: URL?
    private var timeout: Task<Void, Never>?
    private var opened = false
    private var expectedState: String?
    init(openAuthorization: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, callbackTimeoutSeconds: Double = 180) {
        self.openAuthorization = openAuthorization
        self.callbackTimeoutSeconds = callbackTimeoutSeconds.isFinite ? max(0.05, min(180, callbackTimeoutSeconds)) : 180
    }
    func prepareCallback() async throws -> URL {
        cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                if case .ready = state, let port = listener.port {
                    let uri = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirect = uri; self.ready?.resume(returning: uri); self.ready = nil
                } else if case .failed = state { self.finish(throwing: ChatGPTAuthenticationError.transportFailure) }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.finish(throwing: ChatGPTAuthenticationError.timedOut)
                }
                listener.start(queue: queue)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    func authenticate(authorizationURL: URL, redirectURI: URL) async throws -> URL {
        guard redirect == redirectURI, listener != nil, !opened else { throw ChatGPTAuthenticationError.invalidCallback }
        let states = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, let state = states.first?.value, !state.isEmpty, state.utf8.count <= 256 else { throw ChatGPTAuthenticationError.invalidCallback }
        expectedState = state
        opened = true; timeout?.cancel()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.callbackTimeoutSeconds ?? 180) * 1_000_000_000)) } catch { return }
                    self?.finish(throwing: ChatGPTAuthenticationError.timedOut)
                }
                if !openAuthorization(authorizationURL) { finish(throwing: ChatGPTAuthenticationError.browserUnavailable) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    func cancel() { finish(throwing: CancellationError()) }
    private func finish(throwing error: Error) {
        ready?.resume(throwing: error); ready = nil; callback?.resume(throwing: error); callback = nil
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll(); redirect = nil; opened = false; expectedState = nil
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 10, case let .hostPort(host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1") else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state {
                Task { @MainActor in if let connection { self?.close(connection) } }
            } else if case .cancelled = state {
                Task { @MainActor in if let connection { self?.close(connection) } }
            }
        }
        connections.append(connection); connection.start(queue: queue); receive(connection, accumulated: Data())
    }
    private func close(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        connections.removeAll { $0 === connection }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.listener != nil, self.connections.contains(where: { $0 === connection }) else { connection.cancel(); return }
                var buffer = accumulated; if let data { buffer.append(data) }
                guard buffer.count <= 16_384, error == nil else { self.close(connection); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { self.handle(buffer, connection: connection) }
                else if complete { self.close(connection) } else { self.receive(connection, accumulated: buffer) }
            }
        }
    }
    private func handle(_ data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8), let first = request.components(separatedBy: "\r\n").first,
              let redirect, callback != nil else { close(connection); return }
        let pieces = first.split(separator: " ")
        guard pieces.count == 3, pieces[0] == "GET", pieces[2] == "HTTP/1.1", pieces[1].hasPrefix("/auth/callback?"),
              !pieces[1].contains("#"), let uri = URL(string: "http://127.0.0.1:\(redirect.port!)\(pieces[1])") else { close(connection); return }
        let query = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == expectedState,
              Set(query.map(\.name)).count == query.count,
              query.contains(where: { ($0.name == "code" || $0.name == "error") && $0.value?.isEmpty == false }) else { close(connection); return }
        let body = "Authorization received. Return to Harness to see the result."
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let continuation = callback; callback = nil
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        continuation?.resume(returning: uri)
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil; self.redirect = nil; opened = false; expectedState = nil
        connections.filter { $0 !== connection }.forEach { $0.cancel() }; connections.removeAll()
    }
}
