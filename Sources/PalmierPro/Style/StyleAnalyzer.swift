import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Extracts a StyleProfile from a reference video: shot boundaries (FrameSampler),
/// per-shot moments (prototype classifier), cut pacing, music tempo (BeatDetector),
/// and an averaged color signature (ColorScopes).
enum StyleAnalyzer {
    enum AnalyzerError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Could not read the reference video." }
    }

    @MainActor
    static func analyze(url: URL) async throws -> StyleProfile {
        let avAsset = AVURLAsset(url: url)
        let duration = (try? await avAsset.load(.duration).seconds) ?? 0
        guard duration > 0 else { throw AnalyzerError.unreadable }
        let hasAudio = ((try? await avAsset.loadTracks(withMediaType: .audio))?.isEmpty == false)

        // Snapshot main-actor state; the heavy pass runs off-actor.
        let embedder = VisualModelLoader.shared.isReady ? VisualModelLoader.shared.embedder : nil
        let prototypes = DomainPrototypeStore.load(SearchIndexCoordinator.autoTagDomain)
        let name = url.deletingPathExtension().lastPathComponent

        return try await Task.detached(priority: .utility) {
            try await extract(
                url: url, duration: duration, hasAudio: hasAudio,
                name: name, embedder: embedder, prototypes: prototypes
            )
        }.value
    }

    // MARK: - Heavy pass

    nonisolated private static func extract(
        url: URL, duration: Double, hasAudio: Bool,
        name: String, embedder: VisualEmbedder?, prototypes: DomainPrototypes?
    ) async throws -> StyleProfile {
        // Shots: FrameSampler flags a new shot on luma scene changes; the flagged
        // frame is the shot's representative image for moment scoring.
        var boundaries: [Double] = []
        var shotFrames: [CGImage] = []
        for try await frame in FrameSampler.frames(url: url, duration: duration) {
            try Task.checkCancellation()
            if frame.isNewShot {
                boundaries.append(boundaries.isEmpty ? 0 : frame.time)
                shotFrames.append(frame.image)
            }
        }

        var shots: [StyleProfile.Shot] = []
        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : duration
            var shot = StyleProfile.Shot(startSec: start, endSec: end)
            if let embedder, let prototypes, i < shotFrames.count,
               let scored = MomentClassifier.scoreFrame(shotFrames[i], prototypes: prototypes, embedder: embedder) {
                shot.moment = scored.moment
                shot.momentConfidence = (scored.score * 100).rounded() / 100
            }
            shots.append(shot)
        }

        // Tempo.
        var music: StyleProfile.Music?
        var cutsOnBeat: Double?
        if hasAudio, let analysis = try? await BeatDetector.analyze(url: url) {
            if analysis.confidence >= 0.4 {
                music = StyleProfile.Music(bpm: analysis.bpm, confidence: analysis.confidence)
                cutsOnBeat = cutsOnBeatFraction(cutTimes: Array(boundaries.dropFirst()), beats: analysis.beats)
            }
        }

        // Color: average scopes over 9 evenly spaced frames.
        var signatures: [ColorSignature] = []
        for i in 1...9 {
            let t = duration * Double(i) / 10
            if let image = await ciFrame(url: url, atSeconds: t),
               let scopes = ColorScopes.measure(image) {
                signatures.append(ColorSignature(scopes))
            }
        }
        guard let color = ColorSignature.average(signatures) else { throw AnalyzerError.unreadable }

        let enoughShots = shots.count >= 8
        return StyleProfile(
            version: StyleProfile.currentVersion,
            sourceName: name,
            durationSeconds: (duration * 10).rounded() / 10,
            analyzedAt: Date(),
            shots: enoughShots ? shots : nil,
            momentSequence: enoughShots ? collapsedMoments(shots) : nil,
            cutStats: enoughShots ? cutStats(shots) : nil,
            music: music,
            cutsOnBeatFraction: cutsOnBeat,
            color: color
        )
    }

    // MARK: - Pure helpers (unit-tested)

    /// Adjacent duplicate moments collapse into one step of the edit's sequence.
    nonisolated static func collapsedMoments(_ shots: [StyleProfile.Shot]) -> [String]? {
        var out: [String] = []
        for m in shots.compactMap(\.moment) where m != out.last {
            out.append(m)
        }
        return out.isEmpty ? nil : out
    }

    nonisolated static func cutStats(_ shots: [StyleProfile.Shot]) -> StyleProfile.CutStats? {
        let lengths = shots.map { $0.endSec - $0.startSec }.filter { $0 > 0 }.sorted()
        guard !lengths.isEmpty else { return nil }
        let total = lengths.reduce(0, +)
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return StyleProfile.CutStats(
            shotCount: lengths.count,
            medianShotSec: r1(lengths[lengths.count / 2]),
            p25ShotSec: r1(lengths[lengths.count / 4]),
            p75ShotSec: r1(lengths[(lengths.count * 3) / 4]),
            shotsPerMinute: r1(Double(lengths.count) / max(total / 60, 0.01))
        )
    }

    /// Fraction of cuts landing within ±tolerance of a beat.
    nonisolated static func cutsOnBeatFraction(
        cutTimes: [Double], beats: [Double], tolerance: Double = 0.15
    ) -> Double? {
        guard !cutTimes.isEmpty, !beats.isEmpty else { return nil }
        let sorted = beats.sorted()
        var hits = 0
        for cut in cutTimes {
            var lo = 0, hi = sorted.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < cut { lo = mid + 1 } else { hi = mid }
            }
            let nearest = min(
                abs(sorted[lo] - cut),
                lo > 0 ? abs(sorted[lo - 1] - cut) : .infinity
            )
            if nearest <= tolerance { hits += 1 }
        }
        return (Double(hits) / Double(cutTimes.count) * 100).rounded() / 100
    }

    nonisolated private static func ciFrame(url: URL, atSeconds: Double) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let cg = try? await generator.image(
            at: CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)).image else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }
}
