import Foundation

/// The four tone-curve channels: master (applied to all channels) plus
/// independent per-channel curves.
public enum ToneCurveChannel: Int, CaseIterable, Sendable, Hashable {
    case master, red, green, blue

    public var displayName: String {
        switch self {
        case .master: return "Master"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

/// One `ToneCurve` per `ToneCurveChannel`.
public struct ToneCurveSet: Equatable, Sendable {
    public var master: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve

    public static let identity = ToneCurveSet()

    public init(
        master: ToneCurve = .identity,
        red: ToneCurve = .identity,
        green: ToneCurve = .identity,
        blue: ToneCurve = .identity
    ) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: ToneCurveChannel) -> ToneCurve {
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
}
