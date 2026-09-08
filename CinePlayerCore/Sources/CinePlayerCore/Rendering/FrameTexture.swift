import Metal
import CineKit

public enum FrameTextureError: Error, CustomStringConvertible {
    case textureCreationFailed

    public var description: String {
        switch self {
        case .textureCreationFailed:
            return "Failed to create an MTLTexture for the decoded frame."
        }
    }
}

/// Uploads a `DecodedFrame`'s raw sensor pixels into a fresh `.r16Uint`
/// `MTLTexture`, width x height, with no tone-mapping applied — this is a
/// raw upload only. Tone-mapping happens later, in `CineRenderer`.
public func makeFrameTexture(device: MTLDevice, frame: DecodedFrame) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r16Uint,
        width: frame.width,
        height: frame.height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw FrameTextureError.textureCreationFailed
    }

    frame.pixels.withUnsafeBytes { rawBuffer in
        texture.replace(
            region: MTLRegionMake2D(0, 0, frame.width, frame.height),
            mipmapLevel: 0,
            withBytes: rawBuffer.baseAddress!,
            bytesPerRow: frame.width * MemoryLayout<UInt16>.size
        )
    }

    return texture
}
