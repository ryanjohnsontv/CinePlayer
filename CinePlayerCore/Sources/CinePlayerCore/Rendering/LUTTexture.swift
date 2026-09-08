import Metal
import CineKit

public enum LUTTextureError: Error, CustomStringConvertible {
    case textureCreationFailed

    public var description: String {
        switch self {
        case .textureCreationFailed:
            return "Failed to create the 3D LUT MTLTexture."
        }
    }
}

/// Builds a Metal 3D texture from a parsed `CubeLUT`, for `Tonemap.metal`'s
/// `tonemapFragment` to sample (see `CineRenderer.render`'s `lutTexture`
/// parameter). Small enum namespace of static functions, matching this
/// package's convention (see `FrameTexture.swift`'s free function / this
/// file's sibling for the raw-sensor-texture equivalent).
public enum LUTTexture {
    /// Expands each RGB triple in `lut.values` to RGBA (alpha = 1.0) --
    /// Metal has no plain 3-channel sampleable pixel format -- and uploads
    /// the result into a fresh `.type3D`, `.rgba32Float` texture of
    /// `lut.size` on each axis.
    ///
    /// `storageMode = .shared`: this texture is uploaded once by the CPU
    /// here and only ever read by the GPU afterwards -- no render-target/
    /// readback synchronize dance is needed (unlike, e.g., `RangeExporter`'s
    /// `.managed` render-target textures elsewhere in this codebase; that
    /// pattern exists for textures the GPU writes and the CPU reads back,
    /// which is not this case).
    public static func make(from lut: CubeLUT, device: MTLDevice) throws -> MTLTexture {
        let n = lut.size

        var rgba = [Float](repeating: 0, count: n * n * n * 4)
        for i in 0..<(n * n * n) {
            rgba[i * 4 + 0] = lut.values[i * 3 + 0]
            rgba[i * 4 + 1] = lut.values[i * 3 + 1]
            rgba[i * 4 + 2] = lut.values[i * 3 + 2]
            rgba[i * 4 + 3] = 1.0
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LUTTextureError.textureCreationFailed
        }

        rgba.withUnsafeBytes { rawBuffer in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, n, n, n),
                mipmapLevel: 0,
                slice: 0,
                withBytes: rawBuffer.baseAddress!,
                bytesPerRow: n * 4 * MemoryLayout<Float>.size,
                bytesPerImage: n * n * 4 * MemoryLayout<Float>.size
            )
        }

        return texture
    }

    /// A tiny 1x1x1 `.rgba32Float` texture whose contents are never actually
    /// sampled -- `tonemapFragment` only samples `lutTexture` when
    /// `uniforms.lutEnabled != 0` -- used so `CineRenderer` always has
    /// *something* valid bound at the LUT texture argument slot even when no
    /// real LUT is loaded (Metal requires a bound resource for any texture
    /// argument a fragment function declares, even if a runtime branch never
    /// samples it).
    public static func makeIdentityDummy(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = 1
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LUTTextureError.textureCreationFailed
        }

        let dummy: [Float] = [0, 0, 0, 1]
        dummy.withUnsafeBytes { rawBuffer in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                mipmapLevel: 0,
                slice: 0,
                withBytes: rawBuffer.baseAddress!,
                bytesPerRow: 4 * MemoryLayout<Float>.size,
                bytesPerImage: 4 * MemoryLayout<Float>.size
            )
        }

        return texture
    }
}
