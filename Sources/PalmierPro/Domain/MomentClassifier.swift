import AVFoundation
import CoreGraphics
import Foundation

/// Visual moment prototypes compiled from labeled reference frames by
/// scripts/build_moment_prototypes.py and bundled next to the domain pack.
struct DomainPrototypes: Decodable, Sendable {
    let domain: String
    let model: String
    let dim: Int
    let marginFloor: Double
    let classes: [MomentClass]

    struct MomentClass: Decodable, Sendable {
        let moment: String
        let count: Int
        let threshold: Double
        let centroids: [[Float]]
    }
}

enum DomainPrototypeStore {
    @MainActor private static var cache: [String: DomainPrototypes?] = [:]

    @MainActor
    static func load(_ domain: String) -> DomainPrototypes? {
        if let hit = cache[domain] { return hit }
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
        let name = "DomainPacks/\(domain)_prototypes.json"
        let candidates = [
            root.appendingPathComponent(name),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(name)"),
            devRoot.appendingPathComponent("Sources/PalmierPro/Resources/\(name)"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let pack = try? JSONDecoder().decode(DomainPrototypes.self, from: data) {
                cache[domain] = pack
                return pack
            }
        }
        cache[domain] = DomainPrototypes?.none
        return nil
    }
}

/// One clip's on-device moment prediction.
struct MomentClassification: Sendable {
    let index: Int
    let moment: String?
    let confidence: Double
    let confident: Bool
    let usable: Bool
    let reason: String?
    let alternatives: [(name: String, score: Double)]
    let midFrameJPEG: Data?
    let method: String   // "prototype" | "zero-shot"
}

/// Classifies clips into domain moments on-device: prototype centroids from real
/// reference footage when bundled, else SigLIP text-cue zero-shot as fallback.
enum MomentClassifier {
    /// Fractions of the clip sampled for classification; midpoint drives the fallback JPEG.
    nonisolated static let framePositions: [Double] = [0.2, 0.5, 0.8]

    // Zero-shot fallback gate: top text-cue match must clear a floor and beat the
    // runner-up by a margin. Relative margin is more robust than an absolute cosine.
    nonisolated private static let zeroShotFloor = 0.10
    nonisolated private static let zeroShotMargin = 0.04

    // A clip is "not meaningful" when it matches one of these throwaway descriptions
    // better than any real moment (mic tests, lens caps, floor B-roll, empty setup).
    nonisolated static let junkCues: [(String, String)] = [
        ("floor/ground", "a close-up of the floor, carpet, or ground while walking, shaky and pointing down"),
        ("ceiling", "a shot pointing up at the ceiling or lights, no people"),
        ("black/lens-cap", "a black, dark, or covered frame, lens cap on, nothing visible"),
        ("test/setup", "a microphone or camera test, camera set down on a table, hands adjusting gear"),
        ("empty-room", "an empty room before the event, no people, setup in progress"),
        ("feet/legs", "only someone's feet, legs, or shoes, accidental shot"),
        ("blurry-test", "extremely blurry out-of-focus footage with no discernible subject"),
    ]
    // A clip's best real-moment cosine must clear this to count as meaningful at all.
    nonisolated private static let meaningfulFloor = 0.06

    /// Batch-classifies clips. Returns [:] when the search model isn't ready (LLM fallback).
    @MainActor
    static func classify(
        clips: [(index: Int, url: URL, duration: Double)],
        domain: String,
        cues: [(String, String)]
    ) async -> [Int: MomentClassification] {
        guard VisualModelLoader.shared.isReady,
              let embedder = VisualModelLoader.shared.embedder,
              !clips.isEmpty else { return [:] }
        if let prototypes = DomainPrototypeStore.load(domain) {
            return await classifyWithPrototypes(clips: clips, prototypes: prototypes, cues: cues, embedder: embedder)
        }
        guard !cues.isEmpty else { return [:] }
        return await classifyZeroShot(clips: clips, cues: cues, embedder: embedder)
    }

    // MARK: - Prototype path

    nonisolated private static func classifyWithPrototypes(
        clips: [(index: Int, url: URL, duration: Double)],
        prototypes: DomainPrototypes,
        cues: [(String, String)],
        embedder: VisualEmbedder
    ) async -> [Int: MomentClassification] {
        await Task.detached(priority: .userInitiated) { () -> [Int: MomentClassification] in
            let junkVecs: [(String, [Float])] = junkCues.compactMap { name, cue in
                (try? embedder.encode(text: cue)).map { (name, normalize($0)) }
            }
            let momentTextVecs: [[Float]] = cues.compactMap { _, cue in
                (try? embedder.encode(text: cue)).map(normalize)
            }
            let results = await withTaskGroup(of: MomentClassification?.self) { group in
                for clip in clips {
                    group.addTask {
                        await classifyOne(
                            clip: clip, prototypes: prototypes,
                            junkVecs: junkVecs, momentTextVecs: momentTextVecs, embedder: embedder
                        )
                    }
                }
                var out: [MomentClassification] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            return Dictionary(uniqueKeysWithValues: results.map { ($0.index, $0) })
        }.value
    }

    nonisolated private static func classifyOne(
        clip: (index: Int, url: URL, duration: Double),
        prototypes: DomainPrototypes,
        junkVecs: [(String, [Float])],
        momentTextVecs: [[Float]],
        embedder: VisualEmbedder
    ) async -> MomentClassification? {
        // A current search index means embeddings already exist — no frame decoding.
        var vectors = storedVectors(url: clip.url, duration: clip.duration, spec: embedder.spec) ?? []
        var midImage: CGImage?
        if vectors.isEmpty {
            let frames = await sampleFrames(url: clip.url, duration: clip.duration)
            guard !frames.isEmpty else { return nil }
            vectors = frames.compactMap { (try? embedder.encode(image: $0.image)).map(normalize) }
            midImage = frames.min { abs($0.position - 0.5) < abs($1.position - 0.5) }?.image
        }
        guard !vectors.isEmpty else { return nil }

        // Per frame: best cosine per class over its centroids; mean across frames.
        var classScores: [(name: String, score: Double, threshold: Double)] = []
        for cls in prototypes.classes {
            var total = 0.0
            for v in vectors {
                var best = -1.0
                for centroid in cls.centroids { best = max(best, dot(v, centroid)) }
                total += best
            }
            classScores.append((cls.moment, total / Double(vectors.count), cls.threshold))
        }
        classScores.sort { $0.score > $1.score }
        guard let top = classScores.first else { return nil }
        let margin = classScores.count >= 2 ? top.score - classScores[1].score : top.score
        let confident = top.score >= top.threshold && margin >= prototypes.marginFloor

        // Junk check on the text↔image scale (image↔prototype cosines aren't comparable
        // to text↔image junk cosines): does any real-moment cue beat every junk cue?
        var usable = true
        var reason: String?
        if let mid = vectors.count >= 2 ? vectors[vectors.count / 2] : vectors.first,
           !junkVecs.isEmpty, !momentTextVecs.isEmpty {
            let bestMoment = momentTextVecs.map { dot(mid, $0) }.max() ?? 0
            let junkScored = junkVecs.map { ($0.0, dot(mid, $0.1)) }.sorted { $0.1 > $1.1 }
            if let bestJunk = junkScored.first,
               bestMoment < meaningfulFloor || bestMoment < bestJunk.1 {
                usable = false
                reason = "looks like \(bestJunk.0)"
            }
        }

        return MomentClassification(
            index: clip.index,
            moment: top.name,
            confidence: softmaxTop(classScores.map(\.score)),
            confident: confident,
            usable: usable,
            reason: reason,
            alternatives: classScores.map { (name: $0.name, score: $0.score) },
            midFrameJPEG: midImage.flatMap { ImageEncoder.encodeJPEG($0, quality: 0.6) },
            method: "prototype"
        )
    }

    /// Scores one frame against the prototype centroids — used by StyleAnalyzer to
    /// label reference-video shots without the full clip pipeline.
    nonisolated static func scoreFrame(
        _ image: CGImage, prototypes: DomainPrototypes, embedder: VisualEmbedder
    ) -> (moment: String, score: Double, confident: Bool)? {
        guard let raw = try? embedder.encode(image: image) else { return nil }
        let v = normalize(raw)
        var best: (String, Double, Double)?   // moment, score, threshold
        var second = -1.0
        for cls in prototypes.classes {
            var score = -1.0
            for centroid in cls.centroids { score = max(score, dot(v, centroid)) }
            if score > (best?.1 ?? -1) {
                second = best?.1 ?? -1
                best = (cls.moment, score, cls.threshold)
            } else if score > second {
                second = score
            }
        }
        guard let best else { return nil }
        let confident = best.1 >= best.2 && (best.1 - max(second, 0)) >= prototypes.marginFloor
        return (best.0, best.1, confident)
    }

    /// Embeddings nearest the sample positions from a current search index, or nil.
    nonisolated private static func storedVectors(
        url: URL, duration: Double, spec: VisualEmbedder.Spec
    ) -> [[Float]]? {
        guard let key = EmbeddingStore.key(for: url),
              EmbeddingStore.isCurrent(
                  key: key, model: spec.model, modelVersion: spec.version,
                  samplerVersion: FrameSampler.samplerVersion
              ),
              let index = try? EmbeddingStore.load(key: key),
              index.header.count > 0, index.header.dim > 0 else { return nil }
        let dim = index.header.dim
        let positions = duration >= 2 ? framePositions : [0.5]
        var out: [[Float]] = []
        var seen: Set<Int> = []
        for p in positions {
            let t = duration * p
            var bestRow = 0
            var bestDist = Double.infinity
            for (i, row) in index.rows.enumerated() where abs(row.time - t) < bestDist {
                bestDist = abs(row.time - t)
                bestRow = i
            }
            guard seen.insert(bestRow).inserted, (bestRow + 1) * dim <= index.vectors.count else { continue }
            out.append(normalize(Array(index.vectors[bestRow * dim..<(bestRow + 1) * dim])))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Zero-shot fallback (text cues)

    nonisolated private static func classifyZeroShot(
        clips: [(index: Int, url: URL, duration: Double)],
        cues: [(String, String)],
        embedder: VisualEmbedder
    ) async -> [Int: MomentClassification] {
        await Task.detached(priority: .userInitiated) { () -> [Int: MomentClassification] in
            let textVecs: [(String, [Float])] = cues.compactMap { name, cue in
                (try? embedder.encode(text: cue)).map { (name, normalize($0)) }
            }
            guard !textVecs.isEmpty else { return [:] }
            let junkVecs: [(String, [Float])] = junkCues.compactMap { name, cue in
                (try? embedder.encode(text: cue)).map { (name, normalize($0)) }
            }

            let results = await withTaskGroup(of: MomentClassification?.self) { group in
                for clip in clips {
                    group.addTask {
                        guard let cg = await sampleImage(url: clip.url, duration: clip.duration, position: 0.5),
                              let raw = try? embedder.encode(image: cg) else { return nil }
                        let v = normalize(raw)
                        let scored = textVecs.map { ($0.0, dot(v, $0.1)) }.sorted { $0.1 > $1.1 }
                        guard let top = scored.first else { return nil }
                        let margin = scored.count >= 2 ? top.1 - scored[1].1 : top.1
                        let confident = top.1 >= zeroShotFloor && margin >= zeroShotMargin

                        let junkScored = junkVecs.map { ($0.0, dot(v, $0.1)) }.sorted { $0.1 > $1.1 }
                        let bestJunk = junkScored.first
                        let usable = top.1 >= meaningfulFloor && top.1 >= (bestJunk?.1 ?? 0)
                        let reason = usable ? nil : (bestJunk.map { "looks like \($0.0)" } ?? "no clear subject")

                        return MomentClassification(
                            index: clip.index,
                            moment: top.0,
                            confidence: softmaxTop(scored.map(\.1)),
                            confident: confident,
                            usable: usable,
                            reason: reason,
                            alternatives: scored.map { (name: $0.0, score: $0.1) },
                            midFrameJPEG: ImageEncoder.encodeJPEG(cg, quality: 0.6),
                            method: "zero-shot"
                        )
                    }
                }
                var out: [MomentClassification] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            return Dictionary(uniqueKeysWithValues: results.map { ($0.index, $0) })
        }.value
    }

    // MARK: - Frame sampling

    nonisolated private static func sampleFrames(
        url: URL, duration: Double
    ) async -> [(position: Double, image: CGImage)] {
        let positions = duration >= 2 ? framePositions : [0.5]
        var out: [(Double, CGImage)] = []
        for p in positions {
            if let cg = await sampleImage(url: url, duration: duration, position: p) {
                out.append((p, cg))
            }
        }
        return out
    }

    nonisolated static func sampleImage(url: URL, duration: Double, position: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let t = CMTime(seconds: max(duration, 0) * position, preferredTimescale: 600)
        return try? await generator.image(at: t).image
    }

    // MARK: - Math

    nonisolated static func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return Double(s)
    }

    /// Softmax top probability over cosine scores — a rough confidence for display.
    nonisolated static func softmaxTop(_ xs: [Double]) -> Double {
        guard let mx = xs.max() else { return 0 }
        let exps = xs.map { exp(($0 - mx) * 15) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? (exps.map { $0 / sum }.max() ?? 0) : 0
    }
}
