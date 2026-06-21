import Foundation
import Network

/// Minimal loopback HTTP/1.1 server that serves the live HLS playlists and
/// fMP4 segments from an `HLSStore`. AVPlayer connects to it over real HTTP,
/// which is the only way to deliver HLS media segments on iOS.
///
/// Binds to 127.0.0.1 on an OS-assigned port; nothing is exposed off-device.
/// No third-party dependencies (uses `Network.framework`).
final class HLSLocalServer {
    private let store: HLSStore
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.tstream.hlsserver")
    private(set) var port: UInt16 = 0

    init(store: HLSStore) throws {
        self.store = store
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: 0)!)
        self.listener = try NWListener(using: params)
    }

    /// The master playlist URL to hand to AVPlayer (valid after `start()`).
    var playlistURL: URL {
        URL(string: "http://127.0.0.1:\(port)/\(HLSStore.playlistName)")!
    }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = self.listener.port {
                self.port = p.rawValue
                TStreamDiagnostics.log("server: listening on 127.0.0.1:\(self.port)")
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.route(conn, requestHeader: header)
            } else if error == nil, !isComplete, buffer.count < 65_536 {
                self.receive(conn, buffer: buffer)
            } else {
                conn.cancel()
            }
        }
    }

    private func route(_ conn: NWConnection, requestHeader: String) {
        // First line: "GET /path HTTP/1.1"
        let path = requestHeader.split(separator: "\r\n").first
            .map(String.init)?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let name = (path as NSString).lastPathComponent

        switch name {
        case HLSStore.playlistName:
            guard store.hasVariant else { return notFound(conn, name) }
            respond(conn, contentType: "application/vnd.apple.mpegurl", body: Data(store.masterPlaylist().utf8))
        case HLSStore.mediaName:
            guard store.segmentCount > 0 else { return notFound(conn, name) }
            respond(conn, contentType: "application/vnd.apple.mpegurl", body: Data(store.mediaPlaylist().utf8))
        case HLSStore.initName:
            guard let data = store.initSegment else { return notFound(conn, name) }
            respond(conn, contentType: "video/mp4", body: data)
        case let s where s.hasPrefix("segment") && s.hasSuffix(".m4s"):
            guard let seq = Int(s.dropFirst(7).dropLast(4)), let data = store.segmentData(forSequence: seq) else {
                return notFound(conn, name)
            }
            respond(conn, contentType: "video/mp4", body: data)
        default:
            notFound(conn, name)
        }
    }

    private func respond(_ conn: NWConnection, contentType: String, body: Data) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func notFound(_ conn: NWConnection, _ name: String) {
        TStreamDiagnostics.log("server: 404 \(name)")
        let body = Data("not found".utf8)
        let header = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}
