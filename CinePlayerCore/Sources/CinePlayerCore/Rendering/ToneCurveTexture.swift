import Metal

public enum ToneCurveTextureError: Error, CustomStringConvertible {
    case textureCreationFailed

    public var description: String {
        switch self {
        case .textureCreationFailed:
            return "Failed to create the 1D tone-curve MTLTexture."
        }
    }
}

/// Builds a Metal 1D texture from a `ToneCurve`'s sampled output levels.
public enum ToneCurveTexture {
    public static let sampleCount = 256

    public static func make(from curve: ToneCurve, device: MTLDevice) throws -> MTLTexture {
        let levels = curve.sampled(count: sampleCount)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r32Float
        descriptor.width = sampleCount
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ToneCurveTextureError.textureCreationFailed
        }

        levels.withUnsafeBytes { rawBuffer in
            texture.replace(
                region: MTLRegionMake1D(0, sampleCount),
                mipmapLevel: 0,
                withBytes: rawBuffer.baseAddress!,
                bytesPerRow: sampleCount * MemoryLayout<Float>.size
            )
        }

        return texture
    }

    /// A 2-texel identity ramp — always sampled (no enable flag), so it
    /// must be a real identity, not placeholder content.
    public static func makeIdentityDummy(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r32Float
        descriptor.width = 2
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ToneCurveTextureError.textureCreationFailed
        }

        let ramp: [Float] = [0, 1]
        ramp.withUnsafeBytes { rawBuffer in
            texture.replace(
                region: MTLRegionMake1D(0, 2),
                mipmapLevel: 0,
                withBytes: rawBuffer.baseAddress!,
                bytesPerRow: 2 * MemoryLayout<Float>.size
            )
        }

        return texture
    }
}

/// The four Metal textures `Tonemap.metal`'s tone-curve stage samples, one
/// per `ToneCurveChannel`.
public struct ToneCurveTextureSet {
    public var master: MTLTexture
    public var red: MTLTexture
    public var green: MTLTexture
    public var blue: MTLTexture

    public init(master: MTLTexture, red: MTLTexture, green: MTLTexture, blue: MTLTexture) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: ToneCurveChannel) -> MTLTexture {
        get {
            switch channel {
            case .master: return master
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .master: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    public static func make(from curves: ToneCurveSet, device: MTLDevice) throws -> ToneCurveTextureSet {
        ToneCurveTextureSet(
            master: try ToneCurveTexture.make(from: curves.master, device: device),
            red: try ToneCurveTexture.make(from: curves.red, device: device),
            green: try ToneCurveTexture.make(from: curves.green, device: device),
            blue: try ToneCurveTexture.make(from: curves.blue, device: device)
        )
    }
}
