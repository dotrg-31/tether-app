import Foundation

/// Wire protocol shared by the Mac sender and the iPad receiver.
///
/// Every packet is: UInt32 big-endian length (of type byte + payload), UInt8 type, payload.
enum PacketType: UInt8 {
    // iPad -> Mac
    case hello = 1            // JSON ClientHello
    case touch = 10           // TouchPacket (binary)
    case scroll = 11          // ScrollPacket (binary)
    case keyframeRequest = 12 // empty

    // Mac -> iPad
    case streamConfig = 2     // JSON StreamConfig
    case parameterSets = 3    // H.264 SPS/PPS, each prefixed by UInt32 BE length
    case frame = 4            // UInt8 keyframe flag, then AVCC H.264 access unit (length-prefixed NAL units)
}

let streamPort: UInt16 = 7878
let protocolVersion = 1

struct ClientHello: Codable {
    var version: Int
    /// Landscape size of the iPad screen in pixels and in points.
    var pixelWidth: Int
    var pixelHeight: Int
    var pointWidth: Int
    var pointHeight: Int
    var deviceName: String
}

struct StreamConfig: Codable {
    var version: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

enum TouchPhase: UInt8 {
    case down = 0, drag = 1, up = 2, click = 3, rightClick = 4, move = 5
}

/// Coordinates are normalized 0...1 relative to the streamed picture.
struct TouchPacket {
    var phase: TouchPhase
    var x: Float
    var y: Float

    var payload: Data {
        var d = Data([phase.rawValue])
        d.appendBE(x.bitPattern)
        d.appendBE(y.bitPattern)
        return d
    }

    init(phase: TouchPhase, x: Float, y: Float) { self.phase = phase; self.x = x; self.y = y }

    init?(_ d: Data) {
        guard d.count >= 9, let p = TouchPhase(rawValue: d[d.startIndex]) else { return nil }
        phase = p
        x = Float(bitPattern: d.readBE(at: 1))
        y = Float(bitPattern: d.readBE(at: 5))
    }
}

/// Scroll deltas in points at a normalized location.
struct ScrollPacket {
    var x: Float, y: Float, dx: Float, dy: Float

    var payload: Data {
        var d = Data()
        for v in [x, y, dx, dy] { d.appendBE(v.bitPattern) }
        return d
    }

    init(x: Float, y: Float, dx: Float, dy: Float) { self.x = x; self.y = y; self.dx = dx; self.dy = dy }

    init?(_ d: Data) {
        guard d.count >= 16 else { return nil }
        x = Float(bitPattern: d.readBE(at: 0))
        y = Float(bitPattern: d.readBE(at: 4))
        dx = Float(bitPattern: d.readBE(at: 8))
        dy = Float(bitPattern: d.readBE(at: 12))
    }
}

func makePacket(_ type: PacketType, _ payload: Data = Data()) -> Data {
    var d = Data(capacity: payload.count + 5)
    d.appendBE(UInt32(payload.count + 1))
    d.append(type.rawValue)
    d.append(payload)
    return d
}

/// Accumulates bytes and yields complete packets.
struct PacketParser {
    private var buffer = Data()
    static let maxPacket = 32 * 1024 * 1024

    /// Returns parsed packets; throws if the stream is corrupt.
    mutating func feed(_ bytes: Data) throws -> [(UInt8, Data)] {
        buffer.append(bytes)
        var out: [(UInt8, Data)] = []
        while buffer.count >= 5 {
            let len = Int(buffer.readBE(at: 0) as UInt32)
            guard len >= 1, len <= Self.maxPacket else { throw ProtocolError.corrupt }
            guard buffer.count >= 4 + len else { break }
            let start = buffer.startIndex
            let type = buffer[start + 4]
            let payload = Data(buffer[(start + 5)..<(start + 4 + len)])
            out.append((type, payload))
            buffer = Data(buffer[(start + 4 + len)...])
        }
        return out
    }
}

enum ProtocolError: Error { case corrupt }

extension Data {
    mutating func appendBE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readBE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
}
