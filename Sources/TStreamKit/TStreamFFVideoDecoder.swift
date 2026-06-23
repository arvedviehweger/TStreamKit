import CoreVideo
import Foundation
import CFFVideoDecoder

/// Swift wrapper over the libavcodec C shim: feed raw (Annex-B) video bytes,
/// get back decoded `CVPixelBuffer`s (I420) with their presentation times.
/// libavcodec handles NAL parsing, field/frame assembly, B-frame reordering and
/// error concealment — the robustness VideoToolbox lacks for this broadcast.
final class TStreamFFVideoDecoder {
    private let decoder: OpaquePointer
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// A decoded frame and its 90 kHz presentation time.
    struct DecodedFrame {
        let pixelBuffer: CVPixelBuffer
        let pts: Int64
    }

    init?(codec: VideoCodec) {
        let id: CFFCodec
        switch codec {
        case .h264: id = CFF_CODEC_H264
        case .h265: id = CFF_CODEC_HEVC
        case .mpeg2: id = CFF_CODEC_MPEG2
        }
        guard let dec = cff_create(id) else { return nil }
        self.decoder = dec
    }

    deinit { cff_destroy(decoder) }

    private var statFrames = 0

    /// Feeds one chunk of elementary stream and returns any frames it completed.
    func decode(_ data: Data, pts: Int64, dts: Int64) -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = cff_feed(decoder, base, Int32(data.count), pts, dts)
        }
        var cff = CFFFrame()
        while cff_receive(decoder, &cff) == 1 {
            if let pb = makePixelBuffer(from: cff) {
                frames.append(DecodedFrame(pixelBuffer: pb, pts: cff.pts))
            }
        }
        statFrames += frames.count
        if statFrames >= 100, TStreamDiagnostics.isEnabled { logStats() }
        return frames
    }

    /// Logs accumulated decode/filter timing so we can see where the CPU goes:
    /// whether decode is multithreaded, and decode vs. deinterlace cost per frame.
    private func logStats() {
        var s = CFFStats()
        cff_read_stats(decoder, &s)
        statFrames = 0
        guard s.frames > 0 else { return }
        let n = Double(s.frames)
        let decodeMs = Double(s.decode_us) / n / 1000.0
        let filterMs = Double(s.filter_us) / n / 1000.0
        let threads = s.thread_type == 0 ? "SINGLE-THREADED" : "\(s.thread_count)t type=\(s.thread_type)"
        TStreamDiagnostics.log(String(format:
            "ffdec: %dx%d%@ %@ — decode %.2fms/f, filter %.2fms/f (%d frames)",
            s.width, s.height, s.interlaced == 1 ? "i" : "p", threads, decodeMs, filterMs, s.frames))
    }

    // MARK: - NV12 → CVPixelBuffer

    private func makePixelBuffer(from frame: CFFFrame) -> CVPixelBuffer? {
        let w = Int(frame.width), h = Int(frame.height)
        guard w > 0, h > 0, let y = frame.y, let u = frame.u, let v = frame.v else { return nil }

        if pixelBufferPool == nil || poolWidth != w || poolHeight != h {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8Planar,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            pixelBufferPool = pool
            poolWidth = w; poolHeight = h
        }
        guard let pool = pixelBufferPool else { return nil }

        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }

        // Anamorphic SD (e.g. 720x576 16:9) has non-square pixels — carry the
        // sample aspect ratio so the display layer stretches it correctly.
        if frame.sar_num > 0, frame.sar_den > 0, frame.sar_num != frame.sar_den {
            let par: [CFString: Any] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(frame.sar_num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(frame.sar_den),
            ]
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey,
                                  par as CFDictionary, .shouldPropagate)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // I420: plane 0 = Y (w×h), plane 1 = Cb, plane 2 = Cr (each w/2 × h/2).
        // The decoder hands us the planes directly, so this is the only full-frame
        // copy in the pipeline (no intermediate color conversion).
        copyPlane(pixelBuffer, plane: 0, src: y, srcStride: Int(frame.y_stride), width: w, height: h)
        copyPlane(pixelBuffer, plane: 1, src: u, srcStride: Int(frame.u_stride), width: w / 2, height: h / 2)
        copyPlane(pixelBuffer, plane: 2, src: v, srcStride: Int(frame.v_stride), width: w / 2, height: h / 2)
        return pixelBuffer
    }

    /// Copies one plane into the pixel buffer, falling back to a per-row copy
    /// only when source and destination strides differ.
    private func copyPlane(_ pb: CVPixelBuffer, plane: Int, src: UnsafePointer<UInt8>, srcStride: Int, width: Int, height: Int) {
        guard let dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return }
        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        if dstStride == srcStride {
            memcpy(dst, src, dstStride * height)
        } else {
            let rowBytes = min(width, dstStride, srcStride)
            for row in 0..<height {
                memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
            }
        }
    }
}
