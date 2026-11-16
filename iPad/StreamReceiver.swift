import Foundation
import Network

/// Listens on the iPad's loopback interface. The Mac reaches it through usbmuxd over the USB cable,
/// so no Wi-Fi or local-network permission is involved.
final class StreamReceiver {
    var onPacket: ((PacketType, Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = PacketParser()

    func start() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: streamPort)!) else {
            retryLater()
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.listener?.cancel(); self?.listener = nil; self?.retryLater() }
        }
        l.start(queue: .main)
        listener = l
    }

    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    private func accept(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        parser = PacketParser()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready: self.onConnected?()
            case .failed, .cancelled: self.connection = nil; self.onDisconnected?()
            default: break
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak c] data, _, done, error in
            guard let self, let c, c === self.connection else { return }
            if let data, !data.isEmpty {
                do {
                    for (raw, payload) in try self.parser.feed(data) {
                        if let t = PacketType(rawValue: raw) { self.onPacket?(t, payload) }
                    }
                } catch {
                    c.cancel()
                    return
                }
            }
            if done || error != nil { c.cancel(); return }
            self.receive(on: c)
        }
    }

    func send(_ type: PacketType, _ payload: Data = Data()) {
        connection?.send(content: makePacket(type, payload), completion: .contentProcessed { _ in })
    }
}
