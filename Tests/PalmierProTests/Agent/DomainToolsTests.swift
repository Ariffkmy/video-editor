import Foundation
import Testing
@testable import PalmierPro

@Suite("DomainPack — decode + lookups")
struct DomainPackDecodeTests {

    private static let json = """
    {
      "domain": "malay_wedding",
      "culture": "Malay",
      "typicalPacing": "slow",
      "audioPatterns": "silent during akad",
      "moments": {
        "akad_nikah": { "category": "ceremony", "importance": "core",
          "audioPolicy": "feature-original", "preferredShots": ["clear_faces"],
          "avoidQualities": ["blurry"], "classificationCues": "akad", "referenceCount": 125 },
        "venue_establishing": { "category": "scene", "importance": "core",
          "audioPolicy": "music-bed-ok", "preferredShots": ["wide"],
          "avoidQualities": ["shaky"], "classificationCues": "venue", "referenceCount": 53 }
      },
      "ceremonies": { "nikah": ["venue_establishing", "akad_nikah"] }
    }
    """

    private func pack() throws -> DomainPack {
        try JSONDecoder().decode(DomainPack.self, from: Data(Self.json.utf8))
    }

    @Test func decodesMomentsAndCeremonies() throws {
        let p = try pack()
        #expect(p.domain == "malay_wedding")
        #expect(p.momentNames.count == 2)
        #expect(p.moment("akad_nikah")?.audioPolicy == "feature-original")
        #expect(p.moment("akad_nikah")?.importance == "core")
    }

    @Test func ceremonyReturnsOrderedSlots() throws {
        let p = try pack()
        #expect(p.ceremony("nikah") == ["venue_establishing", "akad_nikah"])
        #expect(p.ceremony("NIKAH") == ["venue_establishing", "akad_nikah"])  // case-insensitive
        #expect(p.ceremony("unknown") == nil)
    }
}

@Suite("DomainPack — bundled pack")
@MainActor
struct DomainPackBundleTests {

    @Test func bundledMalayWeddingPackLoadsAndCoversAllMoments() throws {
        guard let pack = DomainPackStore.load("malay_wedding") else {
            Issue.record("malay_wedding domain pack not found in bundle")
            return
        }
        // At least the original 15 (the taxonomy grows as more scenes are labeled).
        #expect(pack.moments.count >= 15)
        #expect(pack.moment("editorial_transition") == nil)   // transition artifact, excluded
        #expect(pack.ceremony("nikah")?.isEmpty == false)
        // Akad audio must be featured; it's the signature audio-crucial moment.
        #expect(pack.moment("akad_nikah")?.audioPolicy == "feature-original")
        #expect(pack.moment("akad_nikah")?.importance == "core")
    }
}

@Suite("Domain tools — guidance / classify / tag")
@MainActor
struct DomainToolsTests {

    private func textPayload(_ result: ToolResult) -> [String: Any]? {
        for block in result.content {
            if case let .text(s) = block,
               let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    @Test func referenceGuidanceReturnsOrderedTimeline() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("get_reference_guidance", args: ["ceremonyType": "nikah"])
        #expect(result.isError == false)
        let json = textPayload(result)
        let timeline = json?["timeline"] as? [[String: Any]]
        #expect(timeline?.isEmpty == false)
        // Every slot carries importance + audioPolicy.
        #expect(timeline?.allSatisfy { $0["importance"] != nil && $0["audioPolicy"] != nil } == true)
    }

    @Test func referenceGuidanceIncludesLearnedSequences() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("get_reference_guidance", args: ["ceremonyType": "nikah"])
        let json = textPayload(result)
        let learned = json?["learnedSequences"] as? [String: Any]
        #expect(learned?["openingMoments"] is [Any])
        #expect(learned?["commonNext"] is [String: Any])
    }

    @Test func tagMomentsPersistsOntoAssetAndManifest() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(id: "vid1")
        h.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))

        let result = await h.runRaw("tag_moments", args: [
            "tags": [["mediaRef": "vid1", "momentType": "akad_nikah", "confidence": 0.9]],
        ])
        #expect(result.isError == false)
        #expect(asset.momentTag?.momentType == "akad_nikah")
        #expect(asset.momentTag?.confidence == 0.9)
        let entry = h.editor.mediaManifest.entries.first { $0.id == "vid1" }
        #expect(entry?.momentTag?.momentType == "akad_nikah")
    }

    @Test func tagMomentsRejectsUnknownMoment() async {
        let h = ToolHarness()
        h.addAsset(id: "vid1")
        let result = await h.runRaw("tag_moments", args: [
            "tags": [["mediaRef": "vid1", "momentType": "not_a_real_moment"]],
        ])
        #expect(result.isError)
    }

    @Test func classifyMomentsReportsClipsAndFilenameHint() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(id: "vidA")
        asset.name = "C0023.mov"   // files don't exist on disk, so no frame — payload still lists clips
        let result = await h.runRaw("classify_moments", args: ["ceremonyType": "nikah"])
        #expect(result.isError == false)
        let json = textPayload(result)
        let clips = json?["clips"] as? [[String: Any]]
        #expect(clips?.count == 1)
        #expect(clips?.first?["filenameSequenceHint"] as? String == "0023")
    }

    @Test func classifyMomentsSkipsAlreadyTaggedClips() async throws {
        let h = ToolHarness()
        let tagged = h.addAsset(id: "vidTagged")
        tagged.momentTag = MomentTag(momentType: "akad_nikah", ceremonyType: nil, confidence: 0.9, source: "local")
        h.addAsset(id: "vidNew")

        let result = await h.runRaw("classify_moments", args: [:])
        #expect(result.isError == false)
        let json = textPayload(result)
        let clips = json?["clips"] as? [[String: Any]]
        #expect(clips?.count == 1)
        #expect(clips?.first?["mediaRef"] as? String == "vidNew")
        let already = json?["alreadyTagged"] as? [[String: Any]]
        #expect(already?.count == 1)
        #expect(already?.first?["mediaRef"] as? String == "vidTagged")
        #expect(already?.first?["momentType"] as? String == "akad_nikah")
    }

    @Test func classifyMomentsExplicitRefsForceReclassification() async throws {
        let h = ToolHarness()
        let tagged = h.addAsset(id: "vidTagged")
        tagged.momentTag = MomentTag(momentType: "akad_nikah", ceremonyType: nil, confidence: 0.9, source: "local")

        let result = await h.runRaw("classify_moments", args: ["mediaRefs": ["vidTagged"]])
        #expect(result.isError == false)
        let json = textPayload(result)
        let clips = json?["clips"] as? [[String: Any]]
        #expect(clips?.count == 1)
        #expect(clips?.first?["existingTag"] as? String == "akad_nikah")
        #expect(json?["alreadyTagged"] == nil)
    }
}

@Suite("Moment prototypes — decode + bundled resource")
@MainActor
struct MomentPrototypeTests {

    @Test func decodesPrototypeJSON() throws {
        let json = """
        {
          "domain": "malay_wedding", "model": "siglip2-base-patch16-256",
          "dim": 4, "marginFloor": 0.02,
          "classes": [
            { "moment": "akad_nikah", "count": 40, "threshold": 0.55,
              "centroids": [[0.5, 0.5, 0.5, 0.5], [1, 0, 0, 0]] }
          ]
        }
        """
        let p = try JSONDecoder().decode(DomainPrototypes.self, from: Data(json.utf8))
        #expect(p.dim == 4)
        #expect(p.classes.first?.centroids.count == 2)
        #expect(p.classes.first?.threshold == 0.55)
    }

    @Test func bundledPrototypesLoadAndMatchPackMoments() throws {
        guard let prototypes = DomainPrototypeStore.load("malay_wedding") else {
            Issue.record("malay_wedding prototypes not found in bundle")
            return
        }
        #expect(prototypes.model == "siglip2-base-patch16-256")
        #expect(!prototypes.classes.isEmpty)
        #expect(prototypes.classes.allSatisfy { $0.centroids.allSatisfy { $0.count == prototypes.dim } })
        #expect(prototypes.classes.allSatisfy { $0.threshold > 0 && $0.threshold < 1 })
        // Every prototype class must be a moment the domain pack knows (tag_moments validates against the pack).
        if let pack = DomainPackStore.load("malay_wedding") {
            #expect(prototypes.classes.allSatisfy { pack.moment($0.moment) != nil })
        }
    }

    @Test func cosineMathBehaves() {
        let v = MomentClassifier.normalize([3, 4])
        #expect(abs(MomentClassifier.dot(v, v) - 1) < 1e-5)
        #expect(MomentClassifier.dot([1, 0], [0, 1]) == 0)
        #expect(MomentClassifier.softmaxTop([0.9, 0.1, 0.1]) > 0.9)
    }
}

@Suite("Footage exposure")
struct FootageExposureTests {

    private func plane(_ value: Float) -> [[Float]] { [[Float](repeating: value, count: 64)] }

    @Test func darkFrameIsUnderexposed() {
        #expect(FootageExposure.classify(planes: plane(10)).label == "underexposed")
    }

    @Test func brightFrameIsOverexposed() {
        #expect(FootageExposure.classify(planes: plane(250)).label == "overexposed")
    }

    @Test func midFrameIsOk() {
        let r = FootageExposure.classify(planes: plane(120))
        #expect(r.label == "ok")
        #expect(r.mean == 120)
    }

    @Test func emptyPlanesAreOk() {
        #expect(FootageExposure.classify(planes: []).label == "ok")
    }
}
