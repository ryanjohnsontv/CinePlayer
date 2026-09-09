import Foundation
import Metal
import CineKit
import CinePlayerCore

// Independent regression check (reviewer-written, not the implementer's):
// for each real sample .cine file, open it through the REAL, post-task
// CineDocumentModel.open(url:) public API (colorTempKelvin/wbcc at their
// defaults, 6500/0), and compare the resulting uniforms.wbGainR/G/B/
// colorMatrix against the UNMODIFIED ExposureUniforms(cineFile:frame:
// debayerMode:) convenience init (verified via `git diff --exit-code` to
// be byte-identical to pre-task source), which is the same "old code path"
// cine-diagnostic itself already used before this task existed.

guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("no Metal device")
}

let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    fatalError("usage: wb-verify <path.cine> [more paths...]")
}

func fmt(_ x: Float) -> String { String(format: "%.10f", x) }

for path in paths {
    let url = URL(fileURLWithPath: path)
    print("=== \(url.lastPathComponent) ===")

    // Old/reference path: exactly what cine-diagnostic has always used.
    let cineFile = try CineFile(url: url)
    let frame = try cineFile.decodeFrame(at: 0)
    let refUniforms = ExposureUniforms(cineFile: cineFile, frame: frame, debayerMode: .bilinear)

    // New path: the real, post-task CineDocumentModel public API, defaults untouched.
    let model = CineDocumentModel(device: device)
    try await model.open(url: url)

    print("colorTempKelvin default = \(model.colorTempKelvin), wbcc default = \(model.wbcc)")
    print("colorMatrixEnabled = \(model.colorMatrixEnabled), vetoed = \(model.colorCalibrationVetoed)")

    let rMatch = refUniforms.wbGainR == model.uniforms.wbGainR
    let gMatch = refUniforms.wbGainG == model.uniforms.wbGainG
    let bMatch = refUniforms.wbGainB == model.uniforms.wbGainB
    let matMatch = refUniforms.colorMatrix == model.uniforms.colorMatrix

    print("ref  wbGain = (\(fmt(refUniforms.wbGainR)), \(fmt(refUniforms.wbGainG)), \(fmt(refUniforms.wbGainB)))")
    print("new  wbGain = (\(fmt(model.uniforms.wbGainR)), \(fmt(model.uniforms.wbGainG)), \(fmt(model.uniforms.wbGainB)))")
    print("bit-exact match: R=\(rMatch) G=\(gMatch) B=\(bMatch) matrix=\(matMatch)")

    // Now dial Color Temp/WBCC away and back, to independently prove
    // temperatureMultiplier(6500)==(1,1,1) and wbccMultiplier(0)==1 are
    // true no-ops through the REAL public API (setColorTemp/setWBCC), not
    // just by reading the source.
    let beforeR = model.uniforms.wbGainR
    let beforeG = model.uniforms.wbGainG
    let beforeB = model.uniforms.wbGainB
    model.setColorTemp(3000)
    model.setWBCC(17.743)
    print("after dialing away: wbGain = (\(fmt(model.uniforms.wbGainR)), \(fmt(model.uniforms.wbGainG)), \(fmt(model.uniforms.wbGainB)))")
    model.setColorTemp(6500)
    model.setWBCC(0)
    let roundTripMatch = model.uniforms.wbGainR == beforeR && model.uniforms.wbGainG == beforeG && model.uniforms.wbGainB == beforeB
    print("round-trip back to defaults bit-exact: \(roundTripMatch) -> (\(fmt(model.uniforms.wbGainR)), \(fmt(model.uniforms.wbGainG)), \(fmt(model.uniforms.wbGainB)))")
    print("")
}
