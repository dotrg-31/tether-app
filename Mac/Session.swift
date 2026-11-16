import Darwin
import Foundation

/// One connection to the iPad over a usbmux tunnel: packet framing, a reader thread and a bounded writer.
final class Session {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "rg.ipaddisplay.write", qos: .userInteractive)
    private let lock = NSLock()
    private var pendingFrames = 0
    private var closed = false

    /// Called on the main queue.
    var onPacket: ((PacketType, Data) -> Void)?
    /// Called once on the main queue when the connection ends.
    var onClose: (() -> Void)?

    static let maxPendingFrames = 3

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var sndbuf: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rg.ipaddisplay.read"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func readLoop() {
        var parser = PacketParser()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            guard let packets = try? parser.feed(Data(buf[0..<n])) else { break }
            for (raw, payload) in packets {
                guard let type = PacketType(rawValue: raw) else { continue }
                DispatchQueue.main.async { [weak self] in self?.onPacket?(type, payload) }
            }
        }
        close()
    }

    /// Queues a packet. Returns false if it was dropped because the link is backed up
    /// (only packets marked `droppable` are ever dropped).
    @discardableResult
    func send(_ type: PacketType, _ payload: Data = Data(), droppable: Bool = false) -> Bool {
        lock.lock()
        if closed || (droppable && pendingFrames >= Self.maxPendingFrames) {
            lock.unlock()
            return false
        }
        pendingFrames += 1
        lock.unlock()

        let packet = makePacket(type, payload)
        writeQueue.async { [weak self] in
            guard let self else { return }
            let ok = (try? Socket.writeAll(self.fd, packet)) != nil
            self.lock.lock(); self.pendingFrames -= 1; self.lock.unlock()
            if !ok { self.close() }
        }
        return true
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        writeQueue.async { [fd] in Darwin.close(fd) }
        DispatchQueue.main.async { [weak self] in
            self?.onClose?()
            self?.onClose = nil
        }
    }
}
