import Darwin
import Foundation

/// Minimal client for macOS usbmuxd, the daemon Xcode and Finder use to talk to iOS devices over USB.
/// `connect` returns a socket that is tunneled to a TCP port on the device.
enum USBMux {
    struct Device { let id: Int; let serial: String }

    enum MuxError: Error { case socket, protocolError, refused(Int) }

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.socket }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); throw MuxError.socket }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ message: [String: Any], tag: UInt32) throws {
        var msg = message
        msg["ClientVersionString"] = "rg-ipad-display"
        msg["ProgName"] = "iPadDisplay"
        let body = try PropertyListSerialization.data(fromPropertyList: msg, format: .xml, options: 0)
        var header = Data()
        for v in [UInt32(16 + body.count), 1, 8, tag] { // length, version (plist), type (plist), tag
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        try Socket.writeAll(fd, header + body)
    }

    private static func receive(_ fd: Int32) throws -> [String: Any] {
        let header = try Socket.readExactly(fd, 16)
        let len = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len >= 16, len < 1 << 20 else { throw MuxError.protocolError }
        let body = try Socket.readExactly(fd, len - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        else { throw MuxError.protocolError }
        return plist
    }

    static func listDevices() -> [Device] {
        guard let fd = try? openSocket() else { return [] }
        defer { close(fd) }
        guard (try? send(fd, ["MessageType": "ListDevices"], tag: 1)) != nil,
              let reply = try? receive(fd),
              let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  (props["ConnectionType"] as? String) == "USB",
                  let id = entry["DeviceID"] as? Int else { return nil }
            return Device(id: id, serial: props["SerialNumber"] as? String ?? "")
        }
    }

    /// Plain TCP to 127.0.0.1, for testing against the iOS Simulator.
    static func connectLocalhost(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Opens a tunnel to `port` on the device. The returned descriptor is a plain byte stream.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            try send(fd, ["MessageType": "Connect", "DeviceID": deviceID,
                          "PortNumber": Int(port.bigEndian)], tag: 2)
            let reply = try receive(fd)
            let code = reply["Number"] as? Int ?? -1
            guard code == 0 else { throw MuxError.refused(code) }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}

enum Socket {
    struct Closed: Error {}

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Closed() }
                off += n
            }
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var off = 0
        try data.withUnsafeMutableBytes { raw in
            while off < count {
                let n = Darwin.read(fd, raw.baseAddress! + off, count - off)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Closed() }
                off += n
            }
        }
        return data
    }
}
