import SwiftUI
import UIKit

@main
struct iPadDisplayApp: App {
    @StateObject private var model = ReceiverModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack {
                StreamContainer(view: model.streamView).ignoresSafeArea()
                if !model.showingVideo {
                    VStack(spacing: 14) {
                        Image(systemName: "display")
                            .font(.system(size: 56, weight: .light))
                        Text(model.status).font(.title2)
                        Text("Keep the cable connected and open Tether on the Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            .background(Color.black)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .preferredColorScheme(.dark)
            .onChange(of: phase) { p in
                UIApplication.shared.isIdleTimerDisabled = (p == .active)
                if p == .active { model.start() }
            }
            .onAppear { model.start() }
        }
    }
}

struct StreamContainer: UIViewRepresentable {
    let view: StreamView
    func makeUIView(context: Context) -> StreamView { view }
    func updateUIView(_ uiView: StreamView, context: Context) {}
}

@MainActor
final class ReceiverModel: ObservableObject {
    @Published var status = "Waiting for the Mac"
    @Published var showingVideo = false

    let streamView = StreamView(frame: .zero)
    private let receiver = StreamReceiver()

    init() {
        streamView.sendTouch = { [weak self] t in self?.receiver.send(.touch, t.payload) }
        streamView.sendScroll = { [weak self] s in self?.receiver.send(.scroll, s.payload) }
        streamView.requestKeyframe = { [weak self] in self?.requestKeyframe() }

        receiver.onConnected = { [weak self] in
            self?.status = "Connected, starting display…"
            self?.sendHello()
        }
        receiver.onDisconnected = { [weak self] in
            self?.status = "Waiting for the Mac"
            self?.showingVideo = false
            self?.streamView.reset()
        }
        receiver.onPacket = { [weak self] type, payload in self?.handle(type, payload) }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        receiver.start()
    }

    private var lastKeyframeRequest = Date.distantPast

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.25 else { return }
        lastKeyframeRequest = Date()
        receiver.send(.keyframeRequest)
    }

    private func sendHello() {
        let screen = streamView.window?.windowScene?.screen ?? UIScreen.main
        let nb = screen.nativeBounds.size, b = screen.bounds.size
        let hello = ClientHello(
            version: protocolVersion,
            pixelWidth: Int(max(nb.width, nb.height)), pixelHeight: Int(min(nb.width, nb.height)),
            pointWidth: Int(max(b.width, b.height)), pointHeight: Int(min(b.width, b.height)),
            deviceName: UIDevice.current.name)
        if let data = try? JSONEncoder().encode(hello) { receiver.send(.hello, data) }
    }

    private func handle(_ type: PacketType, _ payload: Data) {
        switch type {
        case .streamConfig:
            status = "Starting display…"
        case .parameterSets:
            streamView.setParameterSets(payload)
        case .frame:
            if streamView.enqueueFrame(payload) && !showingVideo { showingVideo = true }
        default:
            break
        }
    }
}
