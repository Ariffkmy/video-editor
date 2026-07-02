import Foundation

/// A reference video's extracted editing style, produced by StyleAnalyzer and
/// cached as JSON. Absent aspects (nil) mean the reference doesn't teach them.
struct StyleProfile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var sourceName: String
    var durationSeconds: Double
    var analyzedAt: Date

    // Structure — nil when too few shots were detected to learn from.
    var shots: [Shot]?
    var momentSequence: [String]?
    var cutStats: CutStats?

    // Tempo — nil when no confident music track was found.
    var music: Music?
    var cutsOnBeatFraction: Double?

    // Color — always present.
    var color: ColorSignature

    // Vibe — written by the agent after viewing representative frames.
    var vibeNotes: String?

    struct Shot: Codable, Sendable {
        var startSec: Double
        var endSec: Double
        var moment: String?
        var momentConfidence: Double?
    }

    struct CutStats: Codable, Sendable {
        var shotCount: Int
        var medianShotSec: Double
        var p25ShotSec: Double
        var p75ShotSec: Double
        var shotsPerMinute: Double
    }

    struct Music: Codable, Sendable {
        var bpm: Double
        var confidence: Double
    }
}

/// Codable mirror of `Scopes` so profiles persist and blend; bridges keep the
/// existing gap/correction math in ToolExecutor+Color usable unchanged.
struct ColorSignature: Codable, Sendable, Equatable {
    var lumaMean, lumaBlack, lumaWhite, clipLow, clipHigh: Float
    var lumaHistogram: [Float]
    var meanRGB, blackRGB, whiteRGB, shadowRGB, midRGB, highRGB: [Float]  // [r,g,b]
    var saturationMean, warmCoolBias, greenMagentaBias: Float
    var hueHistogram: [Float]
    var colorfulPct: Float

    init(_ s: Scopes) {
        func a(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
        lumaMean = s.lumaMean; lumaBlack = s.lumaBlack; lumaWhite = s.lumaWhite
        clipLow = s.clipLow; clipHigh = s.clipHigh
        lumaHistogram = s.lumaHistogram
        meanRGB = a(s.meanRGB); blackRGB = a(s.blackRGB); whiteRGB = a(s.whiteRGB)
        shadowRGB = a(s.shadowRGB); midRGB = a(s.midRGB); highRGB = a(s.highRGB)
        saturationMean = s.saturationMean
        warmCoolBias = s.warmCoolBias; greenMagentaBias = s.greenMagentaBias
        hueHistogram = s.hueHistogram
        colorfulPct = s.colorfulPct
    }

    var scopes: Scopes {
        func v(_ a: [Float]) -> SIMD3<Float> {
            a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : .zero
        }
        return Scopes(
            lumaMean: lumaMean, lumaBlack: lumaBlack, lumaWhite: lumaWhite,
            clipLow: clipLow, clipHigh: clipHigh, lumaHistogram: lumaHistogram,
            meanRGB: v(meanRGB), blackRGB: v(blackRGB), whiteRGB: v(whiteRGB),
            shadowRGB: v(shadowRGB), midRGB: v(midRGB), highRGB: v(highRGB),
            saturationMean: saturationMean,
            warmCoolBias: warmCoolBias, greenMagentaBias: greenMagentaBias,
            hueHistogram: hueHistogram, colorfulPct: colorfulPct
        )
    }

    /// Element-wise mean of several signatures (equal weights).
    static func average(_ sigs: [ColorSignature]) -> ColorSignature? {
        guard var acc = sigs.first else { return nil }
        guard sigs.count > 1 else { return acc }
        let n = Float(sigs.count)
        func mean(_ get: (ColorSignature) -> Float) -> Float { sigs.map(get).reduce(0, +) / n }
        func meanA(_ get: (ColorSignature) -> [Float]) -> [Float] {
            let arrays = sigs.map(get)
            guard let len = arrays.map(\.count).min(), len > 0 else { return [] }
            return (0..<len).map { i in arrays.map { $0[i] }.reduce(0, +) / n }
        }
        acc.lumaMean = mean(\.lumaMean); acc.lumaBlack = mean(\.lumaBlack); acc.lumaWhite = mean(\.lumaWhite)
        acc.clipLow = mean(\.clipLow); acc.clipHigh = mean(\.clipHigh)
        acc.lumaHistogram = meanA(\.lumaHistogram)
        acc.meanRGB = meanA(\.meanRGB); acc.blackRGB = meanA(\.blackRGB); acc.whiteRGB = meanA(\.whiteRGB)
        acc.shadowRGB = meanA(\.shadowRGB); acc.midRGB = meanA(\.midRGB); acc.highRGB = meanA(\.highRGB)
        acc.saturationMean = mean(\.saturationMean)
        acc.warmCoolBias = mean(\.warmCoolBias); acc.greenMagentaBias = mean(\.greenMagentaBias)
        acc.hueHistogram = meanA(\.hueHistogram)
        acc.colorfulPct = mean(\.colorfulPct)
        return acc
    }
}
