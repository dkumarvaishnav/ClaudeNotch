import Foundation
import HookProtocol
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 for `claudenotch-hook`. One request per connection;
/// a request can be held open (permission requests, reply waits) until it is answered.
final class HookServer {
    static let port = HookAuth.port
    private static let maxBody = 4_000_000
    private static let maxConnections = 64
    /// A request must arrive in full this quickly (held requests are not affected once they have).
    private static let readTimeout: TimeInterval = 10

    struct Request {
        let path: String
        let query: [String: String]
        let headers: [String: String]   // lowercased names
        let body: Data
    }

    /// A request waiting for its response. Lives on the main thread.
    final class Exchange {
        private let connection: NWConnection
        private(set) var isOpen = true
        var onClose: (() -> Void)?
        /// Signs the response so the helper can tell it really comes from this app.
        var proof: ((Int, Data) -> String)?

        init(_ connection: NWConnection) { self.connection = connection }

        func respond(status: Int = 200, json: Data? = nil) {
            guard isOpen else { return }
            isOpen = false
            onClose = nil
            let body = json ?? Data()
            let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 413: "Payload Too Large", 503: "Service Unavailable"]
            var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            if json != nil { head += "Content-Type: application/json\r\n" }
            if let proof { head += "\(HookAuth.proofHeader): \(proof(status, body))\r\n" }
            let connection = self.connection
            connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }

        /// The client went away (Claude Code timed the hook out, or the session ended).
        fileprivate func closed() {
            guard isOpen else { return }
            isOpen = false
            let handler = onClose
            onClose = nil
            handler?()
        }
    }

    var onRequest: (Request, Exchange) -> Void = { _, exchange in exchange.respond() }
    private(set) var failure: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ClaudeNotch.hooks")
    private var open = 0 // connections, on `queue`

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true // rebind at once after a restart
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async { self?.failure = "Port \(Self.port) is busy: \(error)" }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            failure = error.localizedDescription
        }
    }

    private func accept(_ connection: NWConnection) {
        guard open < Self.maxConnections else { return connection.cancel() }
        open += 1
        let state = ReadState()
        connection.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed:
                connection.cancel() // always ends in .cancelled, counted once there
            case .cancelled:
                self?.open -= 1
                state.onEnd?()
                state.onEnd = nil
            default: break
            }
        }
        connection.start(queue: queue)
        // Slow or half-sent requests don't get to sit on a connection.
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { if !state.complete { connection.cancel() } }
        receive(connection, buffer: Data(), state: state)
    }

    private final class ReadState {
        var complete = false
        var onEnd: (() -> Void)?
    }

    private func receive(_ connection: NWConnection, buffer: Data, state: ReadState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                state.complete = true
                self.dispatch(request, connection, state)
            case .invalid:
                connection.cancel()
            case .incomplete:
                if isComplete || error != nil || buffer.count > Self.maxBody + 64 * 1024 { connection.cancel() }
                else { self.receive(connection, buffer: buffer, state: state) }
            }
        }
    }

    private func dispatch(_ request: Request, _ connection: NWConnection, _ state: ReadState) {
        let exchange = Exchange(connection)
        state.onEnd = { DispatchQueue.main.async { exchange.closed() } }
        // Anything arriving now means the client closed (or misbehaves): either way the request is over.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            DispatchQueue.main.async { exchange.closed() }
        }
        DispatchQueue.main.async { [weak self] in self?.onRequest(request, exchange) }
    }

    private enum Parsed {
        case request(Request)
        case incomplete
        case invalid
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 * 1024 ? .invalid : .incomplete }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBody).contains(length) else { return .invalid }
        let body = data[split.upperBound...]
        guard body.count >= length else { return .incomplete }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
            }
        }
        return .request(Request(path: String(parts.first ?? ""), query: query, headers: headers, body: Data(body.prefix(length))))
    }
}
