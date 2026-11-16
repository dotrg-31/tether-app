import AVFoundation
import UIKit

/// Shows the decoded Mac display and turns touches into mouse input.
final class StreamView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    var sendTouch: ((TouchPacket) -> Void)?
    var sendScroll: ((ScrollPacket) -> Void)?
    var requestKeyframe: (() -> Void)?

    private var format: CMVideoFormatDescription?
    private var videoSize = CGSize(width: 4, height: 3)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isMultipleTouchEnabled = true
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Video

    func setParameterSets(_ payload: Data) {
        guard let f = makeFormat(payload) else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: f) { return }
        if format != nil { flush(removeImage: false) }
        format = f
        let d = CMVideoFormatDescriptionGetDimensions(f)
        videoSize = CGSize(width: Int(d.width), height: Int(d.height))
    }

    /// Returns true if the frame was handed to the decoder.
    @discardableResult
    func enqueueFrame(_ payload: Data) -> Bool {
        if rendererNeedsReset {
            flush(removeImage: false)
            format = nil
            requestKeyframe?()
            return false
        }
        guard let format, payload.count > 1, let sb = makeSampleBuffer(payload.dropFirst(), format) else {
            requestKeyframe?()
            return false
        }
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sb)
        } else {
            displayLayer.enqueue(sb)
        }
        return true
    }

    func reset() {
        flush(removeImage: true)
        format = nil
    }

    // iPadOS 17 moved decoding to `sampleBufferRenderer`; iPadOS 16 uses the layer directly.
    private var rendererNeedsReset: Bool {
        if #available(iOS 17.0, *) {
            let r = displayLayer.sampleBufferRenderer
            return r.status == .failed || r.requiresFlushToResumeDecoding
        }
        return displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding
    }

    private func flush(removeImage: Bool) {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: removeImage, completionHandler: nil)
        } else if removeImage {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
    }

    // MARK: Input

    private var videoRect: CGRect { AVMakeRect(aspectRatio: videoSize, insideRect: bounds) }

    private func normalized(_ p: CGPoint) -> (Float, Float) {
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        return (Float((p.x - r.minX) / r.width), Float((p.y - r.minY) / r.height))
    }

    private func touch(_ phase: TouchPhase, _ p: CGPoint) {
        let (x, y) = normalized(p)
        sendTouch?(TouchPacket(phase: phase, x: x, y: y))
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all // trackpad / mouse wheel too
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        [tap, twoFingerTap, drag, scroll, hover].forEach(addGestureRecognizer)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        touch(.click, g.location(in: self))
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        touch(.rightClick, g.location(in: self))
    }

    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let t = g.translation(in: self)
            touch(.down, CGPoint(x: p.x - t.x, y: p.y - t.y))
            touch(.drag, p)
        case .changed: touch(.drag, p)
        case .ended, .cancelled, .failed: touch(.up, p)
        default: break
        }
    }

    private var lastScroll = CGPoint.zero

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began: lastScroll = t
        case .changed:
            let dx = t.x - lastScroll.x, dy = t.y - lastScroll.y
            lastScroll = t
            let (x, y) = normalized(g.location(in: self))
            sendScroll?(ScrollPacket(x: x, y: y, dx: Float(dx), dy: Float(dy)))
        default: break
        }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        if g.state == .changed || g.state == .began { touch(.move, g.location(in: self)) }
    }
}
