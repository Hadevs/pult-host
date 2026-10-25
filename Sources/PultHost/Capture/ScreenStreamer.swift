import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

enum CaptureError: Error { case noDisplay; case encoder(OSStatus) }

/// Captures the main display with ScreenCaptureKit and encodes it to
/// low-latency H.264. Frames are only encoded while the sender has room
/// (`canSend`), so a slow link skips captures instead of building a queue.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((VideoFrame) -> Void)?
    var onStopped: (() -> Void)?
    var canSend: () -> Bool = { true }
    var bitrate: Int = 20_000_000

    private(set) var info: ScreenInfo?
    private(set) var displayBounds: CGRect = .zero   // global points

    private let queue = DispatchQueue(label: "pult.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var lastPixelBuffer: CVPixelBuffer?
    private var forceKey = true
    private var skippedFrame = false
    private var nextFrameId: UInt32 = 0

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor ?? 1
        // Native pixels, capped so the longer side stays ≤ 2560 (decode + bitrate budget).
        var w = Double(display.width) * scale, h = Double(display.height) * scale
        let cap = 2560.0 / max(w, h)
        if cap < 1 { w *= cap; h *= cap }
        let vw = Int(w) & ~1, vh = Int(h) & ~1

        displayBounds = CGDisplayBounds(display.displayID)
        info = ScreenInfo(width: Float(display.width), height: Float(display.height),
                          videoWidth: UInt16(vw), videoHeight: UInt16(vh),
                          name: Host.current().localizedName ?? "Mac")

        let config = SCStreamConfiguration()
        config.width = vw
        config.height = vh
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false        // the client draws the cursor locally
        config.queueDepth = 4
        config.capturesAudio = false

        try makeEncoder(width: vw, height: vh)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.sync {
            if let e = encoder { VTCompressionSessionInvalidate(e) }
            encoder = nil
            lastPixelBuffer = nil
        }
    }

    /// Next frame goes out as IDR. With a static screen there's no next
    /// capture, so re-encode the last one right away.
    func requestKeyframe() {
        queue.async { [self] in
            forceKey = true
            if let pb = lastPixelBuffer { encode(pb) }
        }
    }

    /// Called when the pipe drained: if we skipped the newest picture,
    /// send it now so a screen that went still isn't left stale.
    func pipeDrained() {
        queue.async { [self] in
            guard skippedFrame, let pb = lastPixelBuffer, canSend() else { return }
            encode(pb)
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        lastPixelBuffer = pb
        guard canSend() || forceKey else { skippedFrame = true; return }
        encode(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("capture stopped: \(error.localizedDescription, privacy: .public)")
        onStopped?()
    }

    // MARK: Encoding

    private func makeEncoder(width: Int, height: Int) throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status != noErr {
            // Low-latency rate control unavailable: fall back to the plain hardware encoder.
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        }
        guard status == noErr, let session else {
            throw CaptureError.encoder(status)
        }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
        ]
        for (k, v) in props { VTSessionSetProperty(session, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        queue.sync { encoder = session; forceKey = true }
    }

    private func encode(_ pb: CVPixelBuffer) {
        guard let encoder else { return }
        skippedFrame = false
        let key = forceKey
        forceKey = false
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb)
        }
    }

    private func emit(_ sb: CMSampleBuffer) {
        guard let block = sb.dataBuffer, let fmt = sb.formatDescription else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        var sps = Data(), pps = Data()
        if isKey {
            sps = parameterSet(fmt, 0)
            pps = parameterSet(fmt, 1)
        }
        var avcc = Data(count: block.dataLength)
        avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: block.dataLength, destination: $0.baseAddress!) }

        nextFrameId &+= 1
        let us = UInt64(max(0, sb.presentationTimeStamp.seconds) * 1_000_000)
        onFrame?(VideoFrame(id: nextFrameId, isKey: isKey, ptsMicros: us, sps: sps, pps: pps, avcc: avcc))
    }

    private func parameterSet(_ fmt: CMFormatDescription, _ index: Int) -> Data {
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                                                           parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard let ptr else { return Data() }
        return Data(bytes: ptr, count: size)
    }
}
