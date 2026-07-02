import AVFoundation
import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let defaultDomain = "malay_wedding"
    private static let classifyMaxClips = 24
    private static let classifyDefaultClips = 16

    // MARK: - get_reference_guidance

    private static let getReferenceGuidanceAllowedKeys: Set<String> = ["domain", "ceremonyType", "momentType"]

    func getReferenceGuidance(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getReferenceGuidanceAllowedKeys, path: "get_reference_guidance")
        let domain = args.string("domain") ?? Self.defaultDomain
        guard let pack = DomainPackStore.load(domain) else {
            throw ToolError("get_reference_guidance: no domain pack for '\(domain)'. Bundled domains: malay_wedding.")
        }

        var payload: [String: Any] = ["domain": pack.domain]
        if let culture = pack.culture { payload["culture"] = culture }
        if let pacing = pack.typicalPacing { payload["typicalPacing"] = pacing }
        if let audio = pack.audioPatterns { payload["audioPatterns"] = audio }

        if let momentType = args.string("momentType") {
            guard let moment = pack.moment(momentType) else {
                throw ToolError("get_reference_guidance: unknown momentType '\(momentType)'. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            payload["moment"] = Self.momentJSON(momentType, moment)
        } else if let ceremonyType = args.string("ceremonyType") {
            guard let slots = pack.ceremony(ceremonyType) else {
                throw ToolError("get_reference_guidance: unknown ceremonyType '\(ceremonyType)'. Known: \(pack.ceremonyNames.joined(separator: ", ")).")
            }
            payload["ceremonyType"] = ceremonyType.lowercased()
            payload["timeline"] = slots.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Slots are in canonical edit order. Place core slots; include optional when good footage exists; drop filler."
        } else {
            payload["ceremonies"] = pack.ceremonyNames
            payload["moments"] = pack.momentNames.compactMap { name in pack.moment(name).map { Self.momentJSON(name, $0) } }
            payload["note"] = "Pass ceremonyType for an ordered timeline, or momentType for one moment's guidance."
        }

        // How real editors actually sequence shots — available alongside any branch.
        if args.string("momentType") == nil, let ls = pack.learnedSequences {
            payload["learnedSequences"] = Self.learnedJSON(ls)
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("get_reference_guidance: failed to encode result.")
        }
        return .ok(json)
    }

    private static func momentJSON(_ name: String, _ m: DomainPack.Moment) -> [String: Any] {
        var out: [String: Any] = [
            "momentType": name,
            "category": m.category,
            "importance": m.importance,
            "audioPolicy": m.audioPolicy,
            "preferredShots": m.preferredShots,
            "avoidQualities": m.avoidQualities,
            "cues": m.classificationCues,
        ]
        if let dur = m.typicalDurationSec { out["typicalDurationSec"] = dur }
        return out
    }

    private static func learnedJSON(_ ls: DomainPack.LearnedSequences) -> [String: Any] {
        func pairs(_ list: [DomainPack.MomentFraction]) -> [[String: Any]] {
            list.map { ["moment": $0.moment, "fraction": $0.fraction] }
        }
        var out: [String: Any] = [:]
        if let v = ls.videosAnalyzed { out["videosAnalyzed"] = v }
        if let o = ls.openingMoments { out["openingMoments"] = pairs(o) }
        if let n = ls.commonNext { out["commonNext"] = n.mapValues(pairs) }
        if let note = ls.note { out["note"] = note }
        return out
    }

    // MARK: - classify_moments

    private static let classifyMomentsAllowedKeys: Set<String> = ["domain", "ceremonyType", "mediaRefs", "maxClips"]

    func classifyMoments(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.classifyMomentsAllowedKeys, path: "classify_moments")
        let domain = args.string("domain") ?? Self.defaultDomain
        let pack = DomainPackStore.load(domain)

        // Resolve the target video assets.
        let assets: [MediaAsset]
        let explicit = args.stringArray("mediaRefs")
        if !explicit.isEmpty {
            assets = try explicit.map { try asset($0, editor: editor) }
        } else {
            assets = editor.mediaAssets.filter { $0.type == .video && !$0.isStyleReference }
        }
        let videos = assets.filter { $0.type == .video }
        guard !videos.isEmpty else {
            throw ToolError("classify_moments: no video assets to classify.")
        }
        let limit = min(max(args.int("maxClips") ?? Self.classifyDefaultClips, 1), Self.classifyMaxClips)

        // Incremental sweep: clips tagged earlier (import pass or a previous call) are
        // reported as-is; only untagged clips are classified. Explicit mediaRefs force
        // re-classification.
        let alreadyTagged = explicit.isEmpty ? videos.filter { $0.momentTag != nil } : []
        let pending = explicit.isEmpty ? videos.filter { $0.momentTag == nil } : videos
        let batch = Array(pending.prefix(limit))

        // Candidate moments the agent should choose from.
        let ceremonyType = args.string("ceremonyType")
        let candidateNames: [String]
        if let pack, let ct = ceremonyType, let slots = pack.ceremony(ct) {
            candidateNames = slots
        } else if let pack {
            candidateNames = pack.momentNames
        } else {
            candidateNames = []
        }
        let candidates: [[String: Any]] = candidateNames.compactMap { name in
            pack?.moment(name).map { ["momentType": name, "cues": $0.classificationCues, "importance": $0.importance] }
        }

        // On-device pass: prototype centroids from real reference footage (or text-cue
        // zero-shot fallback) predict each clip's moment locally. Only the clips the
        // local match is unsure about get a frame image sent to the model — the
        // confident ones come back as predictions the agent tags with no vision round-trip.
        let cueList: [(String, String)] = candidates.compactMap {
            guard let n = $0["momentType"] as? String, let c = $0["cues"] as? String else { return nil }
            return (n, c)
        }
        let clipInputs: [(index: Int, url: URL, duration: Double)] = batch.enumerated().compactMap { offset, asset in
            FileManager.default.fileExists(atPath: asset.url.path) ? (offset, asset.url, asset.duration) : nil
        }
        let localByIndex = await MomentClassifier.classify(clips: clipInputs, domain: domain, cues: cueList)

        // Parallel-sample frames only for the clips that still need the model's eyes.
        let needImage = clipInputs.filter { localByIndex[$0.index]?.confident != true && localByIndex[$0.index]?.midFrameJPEG == nil }
        let sampled = await Self.sampleJPEGs(needImage)

        var imageBlocks: [ToolResult.Block] = []
        var clipMeta: [[String: Any]] = []
        for (index, asset) in batch.enumerated() {
            var meta: [String: Any] = [
                "index": index,
                "mediaRef": asset.id,
                "name": asset.name,
                "durationSeconds": (asset.duration * 100).rounded() / 100,
                "filenameSequenceHint": Self.filenameSequenceHint(asset.name),
            ]
            if let tag = asset.momentTag { meta["existingTag"] = tag.momentType }

            let local = localByIndex[index]
            if let local, let best = local.moment {
                meta["predictedMomentType"] = best
                meta["confidence"] = (local.confidence * 100).rounded() / 100
                meta["usable"] = local.usable
                if let reason = local.reason { meta["notUsableReason"] = reason }
                meta["alternatives"] = local.alternatives.prefix(3).map {
                    ["momentType": $0.name, "score": ($0.score * 1000).rounded() / 1000]
                }
            }

            if local?.confident == true {
                meta["frame"] = "not needed (confident local match)"
            } else if let jpeg = local?.midFrameJPEG ?? sampled[index] {
                imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
                meta["frame"] = "image #\(imageBlocks.count)"
            } else {
                meta["frame"] = "unavailable"
            }
            clipMeta.append(meta)
        }

        var payload: [String: Any] = [
            "domain": domain,
            "clips": clipMeta,
            "candidateMoments": candidates,
            "instructions": "predictedMomentType is an on-device visual match against real reference footage. usable:false marks throwaway/test footage (see notUsableReason — e.g. floor, ceiling, lens cap, mic test, empty room, feet): do NOT tag or place these on the timeline; skip them. For usable clips whose frame is 'not needed (confident local match)', pass predictedMomentType straight to tag_moments. Clips with an attached 'frame' image are low-confidence — decide those (including whether they're junk) from the image + filenameSequenceHint + cues. Clips under alreadyTagged were classified earlier (at import or a previous call) and need no work; pass explicit mediaRefs to force re-classification. Do NOT call inspect_media during bulk classification (it triggers expensive transcription).",
        ]
        if !alreadyTagged.isEmpty {
            payload["alreadyTagged"] = alreadyTagged.map {
                ["mediaRef": $0.id, "name": $0.name, "momentType": $0.momentTag?.momentType ?? ""]
            }
        }
        if let ceremonyType { payload["ceremonyType"] = ceremonyType.lowercased() }
        if batch.count < pending.count {
            payload["truncated"] = ["shown": batch.count, "total": pending.count, "note": "Pass mediaRefs or raise maxClips to classify the rest."]
        }

        guard let json = Self.jsonString(payload) else {
            throw ToolError("classify_moments: failed to encode result.")
        }
        return ToolResult(content: imageBlocks + [.text(json)], isError: false)
    }

    // MARK: - tag_moments

    private static let tagMomentsAllowedKeys: Set<String> = ["tags"]
    private static let tagEntryAllowedKeys: Set<String> = ["mediaRef", "momentType", "ceremonyType", "confidence"]

    func tagMoments(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.tagMomentsAllowedKeys, path: "tag_moments")
        guard let rawTags = args["tags"] as? [[String: Any]], !rawTags.isEmpty else {
            throw ToolError("tag_moments: 'tags' must be a non-empty array.")
        }
        let pack = DomainPackStore.load(Self.defaultDomain)

        var applied: [[String: Any]] = []
        for (i, entry) in rawTags.enumerated() {
            try validateUnknownKeys(entry, allowed: Self.tagEntryAllowedKeys, path: "tags[\(i)]")
            let mediaRef = try entry.requireString("mediaRef")
            let momentType = try entry.requireString("momentType")
            if let pack, pack.moment(momentType) == nil {
                throw ToolError("tag_moments: unknown momentType '\(momentType)' in tags[\(i)]. Known: \(pack.momentNames.joined(separator: ", ")).")
            }
            let asset = try asset(mediaRef, editor: editor)
            let tag = MomentTag(
                momentType: momentType,
                ceremonyType: entry.string("ceremonyType"),
                confidence: min(max(entry.double("confidence") ?? 1.0, 0), 1),
                source: "agent"
            )
            asset.momentTag = tag
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].momentTag = tag
            }
            applied.append(["mediaRef": asset.id, "momentType": momentType, "confidence": tag.confidence])
        }

        guard let json = Self.jsonString(["tagged": applied.count, "tags": applied]) else {
            throw ToolError("tag_moments: failed to encode result.")
        }
        return .ok(json)
    }

    // MARK: - Helpers

    /// Reports digit groups in a filename so the agent can infer shoot order (e.g. "C0023" -> ["0023"]).
    static func filenameSequenceHint(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        var groups: [String] = []
        var current = ""
        for ch in stem {
            if ch.isNumber { current.append(ch) }
            else if !current.isEmpty { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.isEmpty ? "none" : groups.joined(separator: ",")
    }

    nonisolated private static func sampleJPEGs(_ clips: [(index: Int, url: URL, duration: Double)]) async -> [Int: Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for c in clips {
                group.addTask {
                    let cg = await MomentClassifier.sampleImage(url: c.url, duration: c.duration, position: 0.5)
                    return (c.index, cg.flatMap { ImageEncoder.encodeJPEG($0, quality: 0.6) })
                }
            }
            var out: [Int: Data] = [:]
            for await (i, d) in group { if let d { out[i] = d } }
            return out
        }
    }
}
