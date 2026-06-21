import Foundation
import Network

/// Minimal HTTP server that streams a buffer as the response body, in paced
/// chunks, and keeps the connection open afterwards to emulate a live source
/// (like Tvheadend / ffmpeg `-listen`). Used to exercise the resource loader
/// against a real `AVPlayer` offline.
final class LocalTSServer {
    private let listener: NWListener
    private let payload: Data
    private let queue = DispatchQueue(label: "tstream.test.server")
    private let chunkSize: Int
    private let chunkDelay: TimeInterval
    private(set) var port: UInt16 = 0

    /// Set true to close the connection after sending the payload (finite
    /// stream / EOF). Default false keeps it open to simulate live.
    var closeAfterPayload = false

    init(serving payload: Data, chunkSize: Int = 32_768, chunkDelay: TimeInterval = 0.008) throws {
        self.payload = payload
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
        self.listener = try NWListener(using: .tcp)
        self.listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
    }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = self?.listener.port {
                self?.port = p.rawValue
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Consume the request line/headers, then respond.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
            guard let self else { return }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                self.stream(conn, from: 0)
            })
        }
    }

    private func stream(_ conn: NWConnection, from offset: Int) {
        guard offset < payload.count else {
            if closeAfterPayload {
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
            return // otherwise keep the connection open (live)
        }
        let end = min(offset + chunkSize, payload.count)
        let slice = payload.subdata(in: offset..<end)
        conn.send(content: slice, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + self.chunkDelay) {
                self.stream(conn, from: end)
            }
        })
    }
}
