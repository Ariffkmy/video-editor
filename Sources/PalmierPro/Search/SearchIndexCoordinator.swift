import Foundation

/// Per-project indexing queue and search
@MainActor
@Observable
final class SearchIndexCoordinator {
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }
    /// Persists an auto-classified moment tag (asset + manifest). Set by EditorViewModel.
    var momentTagWriter: ((MediaAsset, MomentTag) -> Void)?

    /// Domain used for the fast auto-tag pass at import.
    static let autoTagDomain = "malay_wedding"

    private var queue: [String] = []
    private var failedIds: Set<String> = []
    /// Clips classified this session without a confident tag — don't retry every sweep.
    private var autoTagAttempted: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Bumped whenever `worker` is replaced or cancelled, so a stale worker's
    /// exit path can't clobber the reference to a newer one.
    private var workerGeneration = 0
    private var loadedIndexes: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]

    private static let registry = NSHashTable<SearchIndexCoordinator>.weakObjects()
    private static var live: [SearchIndexCoordinator] { registry.allObjects }

    init() {
        Self.registry.add(self)
    }

    // MARK: - App-level fan-out

    static func sweepAll() { for c in live { c.sweep() } }
    static func cancelAll() async { for c in live { await c.cancelIndexing() } }
    static func resetAll() async {
        for c in live {
            await c.cancelIndexing()
            c.loadedIndexes.removeAll()
            c.failedIds.removeAll()
            c.autoTagAttempted.removeAll()
        }
    }

    static func clearIndexGlobally() async {
        await resetAll()
        EmbeddingStore.clearAll()
        sweepAll()
    }

    // MARK: - Triggers

    func projectOpened() {
        Log.search.notice(
            "index project opened enabled=\(VisualModelLoader.shared.enabled)",
            telemetry: "Search index project opened",
            data: ["enabled": VisualModelLoader.shared.enabled]
        )
        Task {
            await VisualModelLoader.shared.prepare()
            sweep()
        }
    }

    /// Enqueue all current assets that need (re)indexing.
    /// Failed assets get a fresh chance; failedIds only dedupes within a batch.
    func sweep() {
        guard VisualModelLoader.shared.enabled, VisualModelLoader.shared.isReady else { return }
        failedIds.removeAll()
        let assets = assetsProvider()
        Log.search.notice(
            "index sweep assets=\(assets.count) queuedBefore=\(queue.count)",
            telemetry: "Search index sweep",
            data: [
                "assets": assets.count,
                "ready": VisualModelLoader.shared.isReady,
                "queuedBefore": queue.count
            ]
        )
        for asset in assets {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        guard VisualModelLoader.shared.enabled, let model = VisualModelLoader.shared.embedder, !asset.isGenerating else { return }
        guard !queue.contains(asset.id), !failedIds.contains(asset.id) else { return }
        let needsVisual = (asset.type == .video || asset.type == .image)
            && VisualIndexer.needsIndex(url: asset.url, spec: model.spec)
        guard needsVisual || needsMomentTag(asset) else { return }
        queue.append(asset.id)
        batchTotal += 1
        ensureWorker()
    }

    /// Transcription is never pre-warmed: captions and agent tools transcribe on demand.
    static func wantsTranscript(_ asset: MediaAsset) -> Bool {
        asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    /// Auto-tagging only runs on the prototype classifier — text-cue zero-shot is too
    /// weak to write tags unattended.
    private func needsMomentTag(_ asset: MediaAsset) -> Bool {
        asset.type == .video && asset.momentTag == nil && !asset.isStyleReference
            && !autoTagAttempted.contains(asset.id)
            && DomainPrototypeStore.load(Self.autoTagDomain) != nil
    }

    /// Stops the worker and waits for the in-flight asset to actually stop.
    private func cancelIndexing() async {
        let current = worker
        workerGeneration += 1
        worker = nil
        queue.removeAll()
        resetBatch()
        current?.cancel()
        await current?.value
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        Log.search.notice(
            "index worker start generation=\(generation) depth=\(queue.count)",
            telemetry: "Search index worker started",
            data: ["generation": generation, "queueDepth": queue.count, "batchTotal": batchTotal]
        )
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let asset = self.dequeue() {
                while ExportCoordinator.isExportActive, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                }
                self.currentAssetFraction = 0
                await self.indexOne(asset)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> MediaAsset? {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let asset = assetsProvider().first(where: { $0.id == id }) { return asset }
            batchCompleted += 1
        }
        resetBatch()
        return nil
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(_ asset: MediaAsset) async {
        defer { batchCompleted += 1 }
        guard let model = VisualModelLoader.shared.embedder else { return }
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.currentAssetFraction = fraction }
        }
        let url = asset.url
        let start = ContinuousClock.now
        do {
            // Fast moment tag first, so the agent can edit before the full index lands.
            await autoTagIfNeeded(asset)
            switch asset.type {
            case .image:
                try await VisualIndexer.indexImage(url: url, model: model)
            case .video:
                try await VisualIndexer.index(
                    url: url, duration: asset.duration, model: model, progress: onProgress
                )
            default:
                break
            }
            loadedIndexes[asset.id] = nil
            let totalSeconds = start.duration(to: .now).seconds
            Log.search.notice("indexed \(asset.id.prefix(8)) visual=\(String(format: "%.1f", totalSeconds))s")
        } catch is CancellationError {
            Log.search.notice("index cancelled asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)")
        } catch {
            failedIds.insert(asset.id)
            Log.search.warning("index failed asset=\(asset.id.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Classifies the clip against the bundled moment prototypes and persists the tag
    /// when the local match is confident and the clip isn't junk. Uncertain clips stay
    /// untagged for the agent's classify_moments pass.
    private func autoTagIfNeeded(_ asset: MediaAsset) async {
        guard needsMomentTag(asset) else { return }
        guard FileManager.default.fileExists(atPath: asset.url.path) else { return }
        autoTagAttempted.insert(asset.id)
        let domain = Self.autoTagDomain
        let cues = DomainPackStore.load(domain).map { pack in
            pack.momentNames.compactMap { name in
                pack.moment(name).map { (name, $0.classificationCues) }
            }
        } ?? []
        let result = await MomentClassifier.classify(
            clips: [(index: 0, url: asset.url, duration: asset.duration)],
            domain: domain, cues: cues
        )[0]
        guard let result, result.confident, result.usable, let moment = result.moment else { return }
        momentTagWriter?(asset, MomentTag(
            momentType: moment, ceremonyType: nil,
            confidence: result.confidence, source: "local"
        ))
        Log.search.notice("auto-tagged \(asset.id.prefix(8)) as \(moment)")
    }

    // MARK: - Query

    func search(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> [VisualSearch.Hit] {
        guard let model = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Snapshot on main; stat/SHA256/file reads, encode, and ranking happen off-actor.
        let candidates = assetsProvider()
            .filter { ($0.type == .video || $0.type == .image) && (ids?.contains($0.id) ?? true) }
            .map { ($0.id, $0.url) }
        let cached = loadedIndexes
        let minScore = SearchIndexConfig.visualMatchCosineFloor

        let (hits, loaded) = await Task.detached(priority: .userInitiated) {
            var indexes: [(String, EmbeddingStore.AssetIndex)] = []
            var loaded: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]
            for (assetID, url) in candidates {
                guard let key = EmbeddingStore.key(for: url) else { continue }
                if let hit = cached[assetID], hit.key == key {
                    indexes.append((assetID, hit.index))
                } else if let index = try? EmbeddingStore.load(key: key) {
                    loaded[assetID] = (key, index)
                    indexes.append((assetID, index))
                }
            }
            guard !indexes.isEmpty, let vector = try? model.encode(text: trimmed) else {
                return ([VisualSearch.Hit](), loaded)
            }
            return (VisualSearch.search(query: vector, indexes: indexes, limit: limit, minScore: minScore), loaded)
        }.value

        loadedIndexes.merge(loaded) { _, new in new }
        return hits
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
