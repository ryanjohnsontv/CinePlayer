import Foundation

/// The "Cine Colour" grading stage uniforms. Must mirror the
/// `GradingUniforms` struct in both copies of `Shaders/Tonemap.metal`
/// exactly (same fields, same order, append-only). `.identity` must be a
/// true no-op through every shader stage that reads it.
public struct GradingUniforms: Equatable, Sendable {
    public var brightness: Float
    public var gain: Float
    public var gainR: Float
    public var gainG: Float
    public var gainB: Float
    public var pedestal: Float
    public var pedestalR: Float
    public var pedestalG: Float
    public var pedestalB: Float
    public var gammaTrim: Float
    public var gammaTrimR: Float
    public var gammaTrimB: Float
    public var gammaTrimG: Float
    public var saturation: Float
    public var hue: Float
    public var flipHorizontal: UInt32
    public var flipVertical: UInt32
    public var exposureIndexGain: Float
    /// 0-3 quarter turns clockwise, applied after both flips.
    public var rotationQuarterTurns: UInt32

    public static let identity = GradingUniforms(
        brightness: 0, gain: 1, gainR: 1, gainG: 1, gainB: 1,
        pedestal: 0, pedestalR: 0, pedestalG: 0, pedestalB: 0,
        gammaTrim: 1, gammaTrimR: 0, gammaTrimB: 0, gammaTrimG: 0,
        saturation: 1, hue: 0, flipHorizontal: 0, flipVertical: 0,
        exposureIndexGain: 1, rotationQuarterTurns: 0
    )

    public init(
        brightness: Float,
        gain: Float,
        gainR: Float,
        gainG: Float,
        gainB: Float,
        pedestal: Float,
        pedestalR: Float,
        pedestalG: Float,
        pedestalB: Float,
        gammaTrim: Float,
        gammaTrimR: Float,
        gammaTrimB: Float,
        gammaTrimG: Float,
        saturation: Float,
        hue: Float,
        flipHorizontal: UInt32,
        flipVertical: UInt32,
        exposureIndexGain: Float,
        rotationQuarterTurns: UInt32
    ) {
        self.brightness = brightness
        self.gain = gain
        self.gainR = gainR
        self.gainG = gainG
        self.gainB = gainB
        self.pedestal = pedestal
        self.pedestalR = pedestalR
        self.pedestalG = pedestalG
        self.pedestalB = pedestalB
        self.gammaTrim = gammaTrim
        self.gammaTrimR = gammaTrimR
        self.gammaTrimB = gammaTrimB
        self.gammaTrimG = gammaTrimG
        self.saturation = saturation
        self.hue = hue
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.exposureIndexGain = exposureIndexGain
        self.rotationQuarterTurns = rotationQuarterTurns
    }
}
