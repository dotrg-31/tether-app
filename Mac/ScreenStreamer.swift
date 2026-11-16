import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Captures one display with ScreenCaptureKit, encodes it as low-latency H.264 and sends it to a Session.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum StreamError: LocalizedError {
        case displayNotFound, encoder(OSStatus)
        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "The virtual display did not appear in the capture list."
            case .encoder(let s): return "Could not start the H.264 encoder (\(s))."
            }
        }
    }

    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let session: Session
    private let captureQueue = DispatchQueue(label: "rg.ipaddisplay.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var forceKeyframe = true // only touched on captureQueue
    private var awaitingKeyframe = false // only touched in the (serialized) encoder callback

    /// Average bitrate in bits per second.
    var bitrate = 40_000_000

    /// True when VideoToolbox reports the hardware (media engine) encoder.
    private(set) var usingHardwareEncoder = false
    private(set) var encoderID = ""
    private let statsLock = NSLock()
    private var framesSent = 0
    private var bytesSent = 0

    /// Frames and bytes sent since the last call.
    func takeStats() -> (frames: Int, bytes: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        let r = (framesSent, bytesSent)
        framesSent = 0; bytesSent = 0
        return r
    }

    init(displayID: CGDirectDisplayID, width: Int, height: Int, session: Session) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.session = session
    }

    func start() async throws {
        try makeEncoder()

        // A brand-new virtual display can take a moment to show up.
        var scDisplay: SCDisplay?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw StreamError.displayNotFound }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.queueDepth = 5
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        captureQueue.async { [self] in
            if let e = encoder {
                VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(e)
            }
            encoder = nil
            lastPixelBuffer = nil
        }
    }

    /// Sends a full frame now (used when the iPad (re)joins or its decoder failed).
    func requestKeyframe() {
        captureQueue.async { [self] in
            forceKeyframe = true
            if let pb = lastPixelBuffer {
                lastPTS = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
                encode(pb, pts: lastPTS)
            }
        }
    }

    private func makeEncoder() throws {
        // Low-latency rate control, and insist on the hardware media engine so the CPU stays idle.
        // If the hardware encoder is unavailable we fail rather than silently burning CPU in software.
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue,
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw StreamError.encoder(status) }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(s)
        // The low-latency encoder does not report UsingHardwareAcceleratedVideoEncoder; creation succeeding
        // with RequireHardwareAcceleratedVideoEncoder is the guarantee.
        var id: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &id)
        encoderID = (id as? String) ?? "unknown"
        usingHardwareEncoder = true
        encoder = s
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastPixelBuffer = pb
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        encode(pb, pts: lastPTS)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture stopped: \(error.localizedDescription)")
    }

    // MARK: Encoding (captureQueue)

    private func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let encoder else { return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKeyframe = false
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.handleEncoded(sb)
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync
        // After a dropped frame, delta frames would decode as garbage until the next keyframe.
        if awaitingKeyframe && !isKey { return }

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            var payload = Data()
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let ptr else { continue }
                payload.appendBE(UInt32(size))
                payload.append(ptr, count: size)
            }
            session.send(.parameterSets, payload)
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length + 1)
        data[0] = isKey ? 1 : 0
        data.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress! + 1)
        }
        // Keyframes are never dropped; if a delta frame is dropped the next frame must be a keyframe.
        if session.send(.frame, data, droppable: !isKey) {
            if isKey { awaitingKeyframe = false }
            statsLock.lock(); framesSent += 1; bytesSent += data.count; statsLock.unlock()
        } else {
            awaitingKeyframe = true
            captureQueue.async { [weak self] in self?.forceKeyframe = true }
        }
    }
}
