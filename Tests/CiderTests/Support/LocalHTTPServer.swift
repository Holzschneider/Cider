import Foundation
import Network

// Minimal HTTP/1.1 server for URL-source tests. Handles a fixed map of
// `path → response`, supports GET and HEAD, sends Content-Type and
// Content-Length, and binds to 127.0.0.1 on a random port. Not robust,
// not threaded smartly — just enough for the Installer URL tests to
// drive a real network round-trip without depending on python3 being
// installed.
final class LocalHTTPServer {
    struct Response {
        let body: Data
        let contentType: String?
        let status: Int
        init(body: Data, contentType: String? = nil, status: Int = 200) {
            self.body = body
            self.contentType = contentType
            self.status = status
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cider.test.http")
    private let lock = NSLock()
    private var routes: [String: Response]
    private(set) var port: UInt16 = 0

    init(routes: [String: Response] = [:]) throws {
        self.routes = routes
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Port 0 → kernel-picked free port.
        listener = try NWListener(using: params, on: .any)
    }

    func setRoute(_ path: String, response: Response) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = response
    }

    private func route(for path: String) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        return routes[path]
    }

    func start() throws {
        let started = DispatchSemaphore(value: 0)
        var startupError: Swift.Error?

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener.port?.rawValue {
                    self.port = p
                }
                started.signal()
            case .failed(let err):
                startupError = err
                started.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + .seconds(5))
        if let startupError {
            throw startupError
        }
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    // MARK: - Connection handling

    private func handle(connection conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn: conn, accumulated: Data())
    }

    private func receive(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            // Look for end-of-headers (\r\n\r\n). For HEAD/GET there's no
            // body to wait for — stop as soon as headers complete.
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                self.respond(conn: conn, headerBytes: headerData)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn: conn, accumulated: buffer)
        }
    }

    private func respond(conn: NWConnection, headerBytes: Data) {
        guard let headers = String(data: headerBytes, encoding: .utf8) else {
            conn.cancel(); return
        }
        let lines = headers.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0]).uppercased()
        let path = normalisedPath(String(parts[1]))

        guard let response = route(for: path) else {
            send(conn: conn, status: 404, body: Data("not found".utf8), contentType: "text/plain", method: method)
            return
        }
        send(conn: conn, status: response.status, body: response.body,
             contentType: response.contentType, method: method)
    }

    private func normalisedPath(_ p: String) -> String {
        // Strip query, decode, ensure leading slash matches our route keys.
        let noQuery = p.split(separator: "?").first.map(String.init) ?? p
        return noQuery.hasPrefix("/") ? noQuery : "/" + noQuery
    }

    private func send(conn: NWConnection, status: Int, body: Data, contentType: String?, method: String) {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        if method != "HEAD" {
            packet.append(body)
        }
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}
