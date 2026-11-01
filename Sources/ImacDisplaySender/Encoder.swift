import CoreMedia
import Foundation
import IDPCore
import IDPProtocol
import VideoToolbox

enum EncoderError: LocalizedError {
    case createFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status):
            return "Could not create a hardware HEVC encoder (VideoToolbox error \(status))"
        }
    }
}

/// Hardware HEVC encoder producing Annex-B access units for FRAME messages
/// (PROTOCOL §6.2, PLAN S4): real-time, no reordering, keyframes only on
/// request, VPS/SPS/PPS in-band on every keyframe.
final class Encoder: @unchecked Sendable {
    typealias Output = (FrameHeader, Data) -> Void
    /// Called once per frame submitted with `forceKeyframe`, after its output
    /// (if any) went to `Output`: true if it came out as a keyframe, false if
    /// it failed, was dropped or came out as a delta frame.
    typealias ForcedKeyframeOutcome = (Encoder, Bool) -> Void

    let size: PixelSize
    private let session: VTCompressionSession
    private let onOutput: Output
    private let onForcedKeyframe: ForcedKeyframeOutcome
    private let state = Locked(State())

    private struct State {
        var lastPtsUs: UInt64?
        var inFlight = 0
        var invalidated = false
    }

    init(size: PixelSize, bitrateKbps: UInt32, onOutput: @escaping Output,
         onForcedKeyframe: @escaping ForcedKeyframeOutcome) throws {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size.width), height: Int32(size.height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw EncoderError.createFailed(status) }

        self.size = size
        self.session = created
        self.onOutput = onOutput
        self.onForcedKeyframe = onForcedKeyframe

        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        // TCP never loses data, so periodic keyframes are pure cost (§6.4).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        setBitrate(kbps: bitrateKbps)
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.info(.vt, "HEVC hardware encoder ready at \(size), \(bitrateKbps / 1000) Mbit/s")
    }

    deinit {
        invalidate()
    }

    /// Frames submitted but not yet output; counted toward backpressure.
    var inFlight: Int { state.value.inFlight }

    /// Updates the target live: average plus a 1.5× per-second cap.
    func setBitrate(kbps: UInt32) {
        let bitsPerSecond = Int(kbps) * 1_000
        set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond)
        let limits = [Double(bitsPerSecond) * 1.5 / 8, 1.0] as CFArray
        set(kVTCompressionPropertyKey_DataRateLimits, limits)
    }

    /// Encodes `imageBuffer` stamped `presentationTime` (host clock).
    func encode(_ imageBuffer: CVImageBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        let shouldEncode = state.withLock { state -> Bool in
            guard !state.invalidated else { return false }
            state.inFlight += 1
            return true
        }
        guard shouldEncode else { return }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            self?.handleOutput(status: status, sampleBuffer: encoded, forced: forceKeyframe)
        }
        if status != noErr {
            state.withLock { $0.inFlight -= 1 }
            Log.error(.vt, "encode failed: \(status)")
            if forceKeyframe { onForcedKeyframe(self, false) }
        }
    }

    /// Blocks until every submitted frame has been output.
    func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        let first = state.withLock { state -> Bool in
            defer { state.invalidated = true }
            return !state.invalidated
        }
        guard first else { return }
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Output

    private func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?, forced: Bool) {
        var deliveredKeyframe = false
        defer {
            state.withLock { $0.inFlight -= 1 }
            if forced {
                if !deliveredKeyframe { Log.warn(.vt, "forced keyframe was not produced; requesting another") }
                onForcedKeyframe(self, deliveredKeyframe)
            }
        }
        guard status == noErr, let sampleBuffer else {
            if status != noErr { Log.error(.vt, "encoder output error \(status)") }
            return
        }
        do {
            let (accessUnit, isKeyframe) = try Self.accessUnit(from: sampleBuffer)
            let ptsUs = monotonicPts(for: sampleBuffer)
            onOutput(FrameHeader(ptsUs: ptsUs, isKeyframe: isKeyframe), accessUnit)
            deliveredKeyframe = isKeyframe
        } catch {
            Log.error(.vt, "could not convert encoder output to Annex-B: \(error)")
        }
    }

    /// pts_us from the capture timestamp. It must strictly increase (§6.2).
    /// With reordering off it always does; if not, nudge it rather than drop
    /// an encoded frame, which would corrupt the picture (§8).
    private func monotonicPts(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let captured = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000) : Monotonic.microseconds()
        return state.withLock { state in
            var pts = captured
            if let last = state.lastPtsUs, pts <= last {
                Log.error(.vt, "non-increasing pts \(pts) after \(last); using \(last + 1)")
                pts = last + 1
            }
            state.lastPtsUs = pts
            return pts
        }
    }

    /// Length-prefixed sample → Annex-B, with parameter sets on keyframes.
    static func accessUnit(from sampleBuffer: CMSampleBuffer) throws -> (Data, Bool) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { throw AnnexB.ConversionError.truncatedNAL(offset: 0) }

        var setCount = 0
        var nalLengthSize: Int32 = 4
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &setCount, nalUnitHeaderLengthOut: &nalLengthSize)

        var parameterSets: [Data] = []
        if isKeyframe {
            // VPS, SPS, PPS in that order (indices 0, 1, 2).
            for index in 0..<setCount {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer { parameterSets.append(Data(bytes: pointer, count: length)) }
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var pointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: total),
           CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                       dataPointerOut: &pointer) == noErr,
           let pointer {
            // Borrow the encoder's bytes; the conversion copies them once.
            let borrowed = Data(bytesNoCopy: pointer, count: total, deallocator: .none)
            let output = try AnnexB.fromLengthPrefixed(
                borrowed, nalLengthSize: Int(nalLengthSize), parameterSets: parameterSets)
            return (output, isKeyframe)
        }
        var copy = Data(count: total)
        copy.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        return (try AnnexB.fromLengthPrefixed(copy, nalLengthSize: Int(nalLengthSize), parameterSets: parameterSets),
                isKeyframe)
    }

    private func set(_ key: CFString, _ value: Any) {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            Log.warn(.vt, "encoder property \(key) not applied (\(status))")
        }
    }
}
