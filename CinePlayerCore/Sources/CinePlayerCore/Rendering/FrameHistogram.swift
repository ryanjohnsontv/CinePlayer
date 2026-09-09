import Foundation
@preconcurrency import Metal

public enum FrameHistogramError: Error, CustomStringConvertible {
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed

    public var description: String {
        switch self {
        case .textureCreationFailed:
            return "Failed to create the offscreen histogram render target."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer for histogram computation."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize the histogram render target."
        }
    }
}

/// A per-channel value histogram — 256 bins (8-bit resolution, matching
/// every mainstream photo/video histogram UI, including Adobe Camera Raw's,
/// which this feature is modeled on), each holding a raw pixel count rather
/// than a pre-normalized height. Normalizing (and any perceptual scaling,
/// e.g. sqrt-compressing tall peaks the way most histogram UIs do so a
/// single spike doesn't flatten everything else) is a presentation concern
/// left to whatever draws this, not baked in here.
public struct FrameHistogram: Equatable, Sendable {
    public static let binCount = 256

    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]

    public init(red: [Int], green: [Int], blue: [Int]) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Computes a `FrameHistogram` from the *rendered* (post-debayer, post-
/// grading, post-LUT) image — matching what a raw-editing tool's histogram
/// shows: the picture as currently graded, not the raw sensor mosaic
/// underneath it. Reuses `CineRenderer`'s existing tonemap pipeline (the
/// same one the live view and every export path already share) rather than
/// a second, independent implementation, for the same reason
/// `CinePreviewImage`'s own doc comment gives for doing likewise.
public enum FrameHistogramComputer {
    /// - Parameter targetDimension: side length of the small square offscreen
    ///   target rendered into purely for this computation — deliberately
    ///   NOT aspect-correct (a squished render is fine; only the
    ///   *distribution* of pixel values matters for a histogram, not their
    ///   spatial layout) and deliberately small: 128×128 (16,384 samples) is
    ///   ample for a smooth 256-bin histogram while keeping the render/
    ///   readback cost tiny regardless of the source frame's native
    ///   resolution — the same reasoning that keeps Quick Look thumbnail
    ///   generation cheap (see `ThumbnailProvider`'s doc comments), applied
    ///   here to a computation that can run once per frame change or grading
    ///   tweak rather than once per file.
    public static func compute(
        rawTexture: MTLTexture,
        uniforms: ExposureUniforms,
        grading: GradingUniforms,
        renderer: CineRenderer,
        device: MTLDevice,
        lutTexture: MTLTexture? = nil,
        targetDimension: Int = 128,
        toneCurveTextures: ToneCurveTextureSet? = nil
    ) throws -> FrameHistogram {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetDimension,
            height: targetDimension,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: descriptor) else {
            throw FrameHistogramError.textureCreationFailed
        }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw FrameHistogramError.commandBufferCreationFailed
        }

        // Viewport intentionally left at `.identity` (ignoring whatever
        // zoom/pan the live view currently has) — a histogram/auto-exposure
        // analysis should always reflect the *whole* frame, matching how a
        // real raw-editing tool's histogram never changes just because the
        // user zoomed into the preview.
        renderer.render(
            rawTexture: rawTexture,
            uniforms: uniforms,
            into: commandBuffer,
            colorAttachment: targetTexture,
            lutTexture: lutTexture,
            grading: grading,
            toneCurveTextures: toneCurveTextures
        )

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw FrameHistogramError.blitEncoderCreationFailed
        }
        blitEncoder.synchronize(resource: targetTexture)
        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = targetDimension * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * targetDimension)
        pixelData.withUnsafeMutableBytes { buffer in
            targetTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, targetDimension, targetDimension),
                mipmapLevel: 0
            )
        }

        var redBins = [Int](repeating: 0, count: FrameHistogram.binCount)
        var greenBins = [Int](repeating: 0, count: FrameHistogram.binCount)
        var blueBins = [Int](repeating: 0, count: FrameHistogram.binCount)

        // `.bgra8Unorm` memory order: B, G, R, A per pixel — same layout
        // `CinePreviewImage.makeCGImage`'s own doc comment documents for the
        // identical render-target format.
        pixelData.withUnsafeBufferPointer { pixels in
            var offset = 0
            let count = targetDimension * targetDimension
            for _ in 0..<count {
                blueBins[Int(pixels[offset])] += 1
                greenBins[Int(pixels[offset + 1])] += 1
                redBins[Int(pixels[offset + 2])] += 1
                offset += 4
            }
        }

        return FrameHistogram(red: redBins, green: greenBins, blue: blueBins)
    }
}
