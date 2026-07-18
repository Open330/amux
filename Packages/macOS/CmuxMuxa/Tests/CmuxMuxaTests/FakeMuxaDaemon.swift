import Foundation

/// A scripted muxad stand-in bound to a temporary unix socket.
///
/// Accepts connections and answers each received JSON line via `respond`
/// (one request line in, zero or more response lines out). ``push(line:)``
/// writes an unsolicited line to every connected client — how tests emit
/// subscribe transitions.
///
/// Uses DispatchSource accept/read sources (the sanctioned low-level socket
/// primitives); all mutable state is confined to `queue`, which is the
/// safety argument for `@unchecked Sendable`.
final class FakeMuxaDaemon: @unchecked Sendable {
    /// The socket path clients should connect to.
    let path: String

    private let queue = DispatchQueue(label: "com.cmux.muxa.fake-daemon")
    private let listenFd: Int32
    private let acceptSource: any DispatchSourceRead
    private let respond: @Sendable (String) -> [String]
    /// Connected client fds and their read sources / partial buffers; queue-confined.
    private var clients: [Int32: (source: any DispatchSourceRead, pending: Data)] = [:]
    /// Total connections accepted over this daemon's lifetime; queue-confined.
    private var acceptedCount = 0

    /// How many connections have been accepted so far (lets a test assert that
    /// concurrent client calls coalesced onto a single connection).
    var totalAccepted: Int { queue.sync { acceptedCount } }

    /// Binds a fresh socket in a temporary directory.
    ///
    /// - Parameter respond: maps one received request line to response lines.
    init(respond: @escaping @Sendable (String) -> [String]) throws {
        self.respond = respond
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muxa-fake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("muxa.sock").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        precondition(bytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            bytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dest.count)))
            }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0, "bind() failed: \(errno)")
        precondition(listen(fd, 8) == 0, "listen() failed")

        listenFd = fd
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        acceptSource.resume()
    }

    /// Writes one raw line (newline appended) to every connected client.
    func push(line: String) {
        queue.async { [self] in
            let payload = Data((line + "\n").utf8)
            for fd in clients.keys {
                payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            }
        }
    }

    /// Closes every client connection (clients see EOF) but keeps listening.
    func dropClients() {
        queue.async { [self] in
            for (fd, client) in clients { client.source.cancel(); _ = fd }
            clients.removeAll()
        }
    }

    func shutdown() {
        queue.sync { [self] in
            for (_, client) in clients { client.source.cancel() }
            clients.removeAll()
            acceptSource.cancel()
            close(listenFd)
            unlink(path)
        }
    }

    private func acceptPending() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        acceptedCount += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        clients[fd] = (source, Data())
        source.setEventHandler { [weak self] in
            self?.drainClient(fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
    }

    private func drainClient(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        var scratch = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &scratch, scratch.count)
        guard count > 0 else {
            client.source.cancel()
            clients[fd] = nil
            return
        }
        client.pending.append(contentsOf: scratch[0..<count])
        while let newline = client.pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = client.pending[client.pending.startIndex..<newline]
            client.pending.removeSubrange(client.pending.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            for response in respond(line) {
                let payload = Data((response + "\n").utf8)
                payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            }
        }
        clients[fd] = client
    }
}
