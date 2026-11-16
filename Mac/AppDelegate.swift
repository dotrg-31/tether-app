import AppKit
import ServiceManagement
import CoreGraphics

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Allow touch control…", action: #selector(askAccessibility), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lastStats = Date()
    private let screenItem = NSMenuItem(title: "Allow screen recording…", action: #selector(askScreen), keyEquivalent: "")

    private var pollTimer: Timer?
    private var connecting = false
    private var session: Session?
    private var display: VirtualDisplay?
    private var streamer: ScreenStreamer?
    private var injector: InputInjector?

    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy may drive the iPad; a second copy would fight over the connection.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me && $0.processIdentifier < me }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "Tether")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statsItem.isEnabled = false
        statsItem.isHidden = true
        menu.addItem(statsItem)
        menu.addItem(.separator())
        screenItem.target = self
        accessibilityItem.target = self
        menu.addItem(screenItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshLoginItem()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.promptForTrust() }
        refreshPermissionItems()

        setStatus("Waiting for iPad (open Tether on the iPad, cable connected)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) { teardown() }

    private func setStatus(_ s: String) {
        statusLine.title = s
        NSLog("Status: \(s)")
    }

    private func refreshPermissionItems() {
        screenItem.isHidden = CGPreflightScreenCaptureAccess()
        accessibilityItem.isHidden = InputInjector.isTrusted
    }

    /// Off unless the user turns it on from the menu; shows up in System Settings > General > Login Items.
    private func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        refreshLoginItem()
    }

    @objc private func askAccessibility() {
        InputInjector.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func askScreen() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Shows what the stream actually costs: frames per second, bandwidth, and encoder type.
    private func updateStats() {
        let now = Date()
        let dt = now.timeIntervalSince(lastStats)
        lastStats = now
        guard let st = streamer else { statsItem.isHidden = true; return }
        let (frames, bytes) = st.takeStats()
        let fps = Double(frames) / dt
        let mbit = Double(bytes) * 8 / dt / 1_000_000
        let enc = st.usingHardwareEncoder ? "hardware encoder" : "SOFTWARE encoder"
        statsItem.title = String(format: "%.0f fps · %.1f Mbit/s · %@", fps, mbit, enc)
        statsItem.isHidden = false
    }

    // MARK: Connection

    private func tick() {
        refreshPermissionItems()
        updateStats()
        guard session == nil, !connecting else { return }
        connecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fd: Int32?
            var found = false
            // `--direct`: connect to the iPad app running in the iOS Simulator on this Mac (testing only).
            let direct = CommandLine.arguments.contains("--direct")
            if direct {
                found = true
                fd = USBMux.connectLocalhost(port: streamPort)
            }
            for dev in direct ? [] : USBMux.listDevices() {
                found = true
                if let f = try? USBMux.connect(deviceID: dev.id, port: streamPort) { fd = f; break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.connecting = false
                if let fd { self.startSession(fd) }
                else if !found { self.setStatus("No iPad on the USB cable") }
                else { self.setStatus("iPad found; waiting for Tether to open on the iPad") }
            }
        }
    }

    private func startSession(_ fd: Int32) {
        let s = Session(fd: fd)
        session = s
        s.onPacket = { [weak self] type, payload in self?.handle(type, payload) }
        s.onClose = { [weak self] in
            self?.teardown()
            self?.setStatus("Disconnected; waiting for iPad")
        }
        s.start()
        setStatus("Connected; waiting for iPad details")
    }

    private func handle(_ type: PacketType, _ payload: Data) {
        switch type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(ClientHello.self, from: payload) else { return }
            startStreaming(hello)
        case .keyframeRequest:
            streamer?.requestKeyframe()
        case .touch:
            if let t = TouchPacket(payload) { injector?.handle(t) }
        case .scroll:
            if let s = ScrollPacket(payload) { injector?.handle(s) }
        default:
            break
        }
    }

    private func startStreaming(_ hello: ClientHello) {
        guard let session, display == nil else { return }
        guard let vd = VirtualDisplay(name: hello.deviceName.isEmpty ? "iPad" : hello.deviceName,
                                      pointWidth: hello.pointWidth, pointHeight: hello.pointHeight,
                                      diagonalInches: Self.estimatedDiagonal(hello)) else {
            setStatus("Could not create the virtual display")
            session.close()
            return
        }
        display = vd
        injector = InputInjector { [weak vd] in vd?.bounds ?? .zero }
        // Encode at the iPad's native pixel size; the display itself renders at 2x.
        let w = hello.pixelWidth & ~1, h = hello.pixelHeight & ~1
        let config = StreamConfig(version: protocolVersion, pixelWidth: w, pixelHeight: h)
        session.send(.streamConfig, (try? JSONEncoder().encode(config)) ?? Data())

        let st = ScreenStreamer(displayID: vd.displayID, width: w, height: h, session: session)
        streamer = st
        setStatus("Starting stream to \(hello.deviceName)…")
        Task { @MainActor in
            do {
                try await st.start()
                self.setStatus("Streaming to \(hello.deviceName) (\(hello.pointWidth)×\(hello.pointHeight))")
            } catch {
                self.setStatus("Capture failed: \(error.localizedDescription)")
                self.refreshPermissionItems()
                session.close()
            }
        }
    }

    /// iPads render about 132 points per inch (iPad mini about 163); only used for the display's reported physical size.
    static func estimatedDiagonal(_ h: ClientHello) -> Double {
        let ppi: Double = max(h.pointWidth, h.pointHeight) < 1150 ? 163 : 132
        return (Double(h.pointWidth * h.pointWidth + h.pointHeight * h.pointHeight)).squareRoot() / ppi
    }

    private func teardown() {
        streamer?.stop()
        streamer = nil
        injector = nil
        display = nil // releasing the CGVirtualDisplay removes it
        session?.close()
        session = nil
    }
}
