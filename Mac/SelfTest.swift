import AppKit
import CoreImage
import CoreMedia
import VideoToolbox

/// `iPadDisplay --selftest [out.png]`: creates the virtual display, captures and encodes it into a local
/// socket pair exactly as it would for the iPad, then decodes the received stream and saves the first
/// picture. Verifies the whole Mac side without an iPad.
enum SelfTest {
    static func run() {
        let out = CommandLine.arguments.drop { $0 != "--selftest" }.dropFirst().first ?? "selftest.png"
        print("Screen recording allowed: \(CGPreflightScreenCaptureAccess())")
        // Optional point size after the output path, e.g. `--selftest out.png 1180x820` (iPad Air).
        let sizeArg = CommandLine.arguments.drop { $0 != "--selftest" }.dropFirst(2).first ?? "1366x1024"
        let parts = sizeArg.split(separator: "x").compactMap { Int($0) }
        let (pw0, ph0) = parts.count == 2 ? (parts[0], parts[1]) : (1366, 1024)
        guard let vd = VirtualDisplay(name: "Tether Test", pointWidth: pw0, pointHeight: ph0, diagonalInches: 11, serial: 0xBEEF)
        else { print("FAIL: could not create virtual display"); exit(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let (pw, ph) = vd.pixelSize
        print("Virtual display \(vd.displayID): bounds \(vd.bounds), pixels \(pw)x\(ph)")

        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        let session = Session(fd: fds[0])
        let receiver = Receiver(fd: fds[1])
        receiver.start()

        let streamer = ScreenStreamer(displayID: vd.displayID, width: pw & ~1, height: ph & ~1, session: session)
        var failure: Error?
        var started = false
        Task {
            do { try await streamer.start() } catch { failure = error }
            started = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !started && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let failure { print("FAIL: \(failure.localizedDescription)"); exit(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        streamer.requestKeyframe()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        print("Hardware encoder required: \(streamer.usingHardwareEncoder) (\(streamer.encoderID))")

        // Idle: nothing changes on the display, so nothing should be encoded.
        _ = streamer.takeStats()
        var cpu0 = cpuSeconds(), t0 = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        var st = streamer.takeStats(), dt = Date().timeIntervalSince(t0)
        print(String(format: "IDLE (static screen): %.1f fps, %.2f Mbit/s, process CPU %.1f%%",
                     Double(st.frames) / dt, Double(st.bytes) * 8 / dt / 1e6, (cpuSeconds() - cpu0) / dt * 100))

        // Worst case: a full-screen animation repainting every pixel at 60 Hz.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let frame = vd.bounds
        let win = NSWindow(contentRect: NSRect(x: frame.minX, y: 0, width: frame.width, height: frame.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vd.displayID }) {
            win.setFrame(screen.frame, display: true)
        }
        let anim = AnimatedView(frame: win.contentView!.bounds)
        win.contentView = anim
        win.level = .floating
        win.orderFrontRegardless()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in anim.needsDisplay = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        _ = streamer.takeStats()
        cpu0 = cpuSeconds(); t0 = Date()
        let gpu = sampleGPU(seconds: 8)
        st = streamer.takeStats(); dt = Date().timeIntervalSince(t0)
        print(String(format: "FULL MOTION: %.1f fps, %.2f Mbit/s, process CPU %.1f%%, whole-Mac GPU %d%%",
                     Double(st.frames) / dt, Double(st.bytes) * 8 / dt / 1e6, (cpuSeconds() - cpu0) / dt * 100, gpu))
        timer.invalidate()
        win.orderOut(nil)
        streamer.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let r = receiver.snapshot()
        print("Received: \(r.paramSets) parameter-set packets, \(r.frames) frames (\(r.keyframes) keyframes), \(r.bytes) bytes")
        guard let fmt = r.format, let key = r.firstKeyframe else { print("FAIL: no decodable keyframe"); exit(1) }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        print("Stream format: \(dims.width)x\(dims.height) H.264, first keyframe \(key.count) bytes")
        guard let image = decode(key, fmt) else { print("FAIL: keyframe did not decode"); exit(1) }
        let ctx = CIContext()
        let url = URL(fileURLWithPath: out)
        do {
            try ctx.writePNGRepresentation(of: CIImage(cvPixelBuffer: image), to: url,
                                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            print("PASS: decoded \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) picture saved to \(url.path)")
        } catch {
            print("FAIL: could not write PNG: \(error)")
            exit(1)
        }
        withExtendedLifetime(vd) {}
        exit(0)
    }

    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Average whole-system GPU utilization (from IOKit performance statistics) while running the run loop.
    static func sampleGPU(seconds: Int) -> Int {
        var samples: [Int] = []
        for _ in 0..<seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            p.arguments = ["-r", "-d", "1", "-c", "IOAccelerator"]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let r = out.range(of: "\"Device Utilization %\"=") {
                samples.append(Int(out[r.upperBound...].prefix { $0.isNumber }) ?? 0)
            }
        }
        return samples.isEmpty ? -1 : samples.reduce(0, +) / samples.count
    }

    final class AnimatedView: NSView {
        private var t: CGFloat = 0
        override func draw(_ dirtyRect: NSRect) {
            t += 1
            let g = NSGradient(colors: [NSColor(hue: (t / 240).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.9, alpha: 1),
                                        NSColor(hue: ((t + 120) / 240).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.6, alpha: 1)])
            g?.draw(in: bounds, angle: t * 3)
            let s = "Tether full-motion test \(Int(t))" as NSString
            s.draw(at: NSPoint(x: 40 + (t * 7).truncatingRemainder(dividingBy: bounds.width - 400), y: bounds.midY),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.white])
        }
    }

    private static func decode(_ avcc: Data, _ fmt: CMVideoFormatDescription) -> CVPixelBuffer? {
        guard let sb = makeSampleBuffer(avcc, fmt) else { return nil }
        var session: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                     imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
        guard let session else { return nil }
        var result: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr { result = img }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        return result
    }

    final class Receiver {
        struct Stats { var paramSets = 0, frames = 0, keyframes = 0, bytes = 0
            var format: CMVideoFormatDescription?; var firstKeyframe: Data? }
        private let fd: Int32
        private var stats = Stats()
        private let lock = NSLock()
        init(fd: Int32) { self.fd = fd }

        func snapshot() -> Stats { lock.lock(); defer { lock.unlock() }; return stats }

        func start() {
            Thread { [self] in
                var parser = PacketParser()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                    if n <= 0 { break }
                    guard let packets = try? parser.feed(Data(buf[0..<n])) else { break }
                    lock.lock()
                    stats.bytes += n
                    for (type, payload) in packets {
                        switch PacketType(rawValue: type) {
                        case .parameterSets:
                            stats.paramSets += 1
                            if stats.format == nil { stats.format = makeFormat(payload) }
                        case .frame:
                            stats.frames += 1
                            if payload.first == 1 {
                                stats.keyframes += 1
                                if stats.firstKeyframe == nil { stats.firstKeyframe = payload.dropFirst() }
                            }
                        default: break
                        }
                    }
                    lock.unlock()
                }
            }.start()
        }
    }
}
