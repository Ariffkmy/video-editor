#!/usr/bin/env python3
"""Build visual moment prototypes for the Malay-wedding domain pack.

Reads the shot-level records in AI-reference/references_malay_wedding.jsonl,
fetches one midpoint frame per selected shot (resumable; low-res video is
downloaded once per source and deleted after frame extraction), embeds frames
with the same SigLIP2 checkpoint the app ships (google/siglip2-base-patch16-256),
k-means them into per-moment centroid vectors, calibrates accept thresholds on a
held-out split, and emits:

    Sources/PalmierPro/Resources/DomainPacks/malay_wedding_prototypes.json

Usage:
    python scripts/build_moment_prototypes.py                # fetch + embed + emit
    python scripts/build_moment_prototypes.py --no-fetch     # use cached frames only
    python scripts/build_moment_prototypes.py --max-videos 3 # limit fetching (trial run)

Re-runnable: frames cache under References/MalayWedding/frames_prototypes/,
embeddings cache alongside; only missing work is redone.

Parity note: the app runs a CoreML conversion of the same checkpoint
(palmier-io/siglip2-base-coreml). Normalized cosines drift only slightly across
the two runtimes; calibrated thresholds plus the LLM fallback band absorb it.
To spot-check on a Mac: embed one cached frame in-app and compare cosine ≥ 0.99.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
JSONL = ROOT / "AI-reference" / "references_malay_wedding.jsonl"
REF_DIR = ROOT / "References" / "MalayWedding"
FRAMES_DIR = REF_DIR / "frames_prototypes"
LEGACY_FRAMES = REF_DIR / "_temp_shotlabel"
PROGRESS = FRAMES_DIR / "_fetch_progress.json"
EMB_CACHE = FRAMES_DIR / "_embeddings.npz"
OUT = ROOT / "Sources" / "PalmierPro" / "Resources" / "DomainPacks" / "malay_wedding_prototypes.json"

MODEL_ID = "google/siglip2-base-patch16-256"

CONFIDENCE_MIN = 0.8
MAX_PER_CLASS = 120
MIN_PER_CLASS = 12          # classes thinner than this are left to the LLM fallback
EXCLUDE = {"editorial_transition"}
HOLDOUT_FRAC = 0.2
THRESHOLD_PERCENTILE = 20   # per-class accept threshold from correct-score distribution
MARGIN_FLOOR_DEFAULT = 0.02


def load_shots() -> list[dict]:
    shots = []
    for line in JSONL.open(encoding="utf-8"):
        r = json.loads(line)
        if "momentSequenceHint" not in r:
            continue
        m = r.get("primaryMoment") or (r.get("momentTypes") or [None])[0]
        if not m or m in EXCLUDE or m.startswith("new"):
            continue
        if r.get("labelConfidence", 0) < CONFIDENCE_MIN:
            continue
        vid = r.get("sourceVideoId")
        ts, te = r.get("timecodeStart"), r.get("timecodeEnd")
        if not vid or ts is None or te is None or te <= ts:
            continue
        idx = r["id"].rsplit("_", 1)[-1]
        shots.append({
            "vid": vid, "shot": idx, "moment": m,
            "mid": (float(ts) + float(te)) / 2,
            "url": r.get("sourceURL") or f"https://www.youtube.com/watch?v={vid}",
        })
    return shots


def select_shots(shots: list[dict]) -> list[dict]:
    """Cap each class at MAX_PER_CLASS, round-robin across videos for spread."""
    by_class: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for s in shots:
        by_class[s["moment"]][s["vid"]].append(s)
    selected = []
    for moment, vids in by_class.items():
        pools = [sorted(v, key=lambda s: s["mid"]) for v in vids.values()]
        picked: list[dict] = []
        i = 0
        while len(picked) < MAX_PER_CLASS and any(pools):
            for pool in pools:
                if i < len(pool) and len(picked) < MAX_PER_CLASS:
                    picked.append(pool[i])
            i += 1
            if i > max(len(p) for p in pools):
                break
        selected += picked
    return selected


def frame_path(s: dict) -> Path:
    return FRAMES_DIR / s["vid"] / f"shot{s['shot']}.jpg"


def adopt_legacy_frames(shots: list[dict]) -> int:
    """Copy frames the old labeling run left behind (<ytid>_shot<n>.jpg)."""
    adopted = 0
    for s in shots:
        dst = frame_path(s)
        if dst.exists():
            continue
        src = LEGACY_FRAMES / f"{s['vid']}_shot{s['shot']}.jpg"
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            adopted += 1
    return adopted


def load_progress() -> dict:
    if PROGRESS.exists():
        return json.loads(PROGRESS.read_text(encoding="utf-8"))
    return {}


def save_progress(p: dict) -> None:
    PROGRESS.parent.mkdir(parents=True, exist_ok=True)
    PROGRESS.write_text(json.dumps(p, indent=1), encoding="utf-8")


def fetch_frames(shots: list[dict], max_videos: int | None) -> None:
    """Per video: download lowest-res ≥360p once, extract all needed frames, delete."""
    progress = load_progress()
    by_vid: dict[str, list[dict]] = defaultdict(list)
    for s in shots:
        if not frame_path(s).exists():
            by_vid[s["vid"]].append(s)
    todo = {v: ss for v, ss in by_vid.items() if progress.get(v) != "failed"}
    if max_videos is not None:
        todo = dict(list(todo.items())[:max_videos])
    print(f"fetch: {len(todo)} videos need frames ({sum(len(v) for v in todo.values())} frames)")

    for n, (vid, need) in enumerate(todo.items(), 1):
        print(f"[{n}/{len(todo)}] {vid}: {len(need)} frames")
        with tempfile.TemporaryDirectory() as tmp:
            video = Path(tmp) / "v.mp4"
            dl = subprocess.run(
                ["yt-dlp", "-f", "worst[height>=360][ext=mp4]/worst[ext=mp4]/worst",
                 "--no-playlist", "-o", str(video), need[0]["url"]],
                capture_output=True, text=True,
            )
            if dl.returncode != 0 or not video.exists():
                print(f"  download failed: {dl.stderr.strip().splitlines()[-1] if dl.stderr else '?'}")
                progress[vid] = "failed"
                save_progress(progress)
                continue
            ok = 0
            for s in need:
                dst = frame_path(s)
                dst.parent.mkdir(parents=True, exist_ok=True)
                ex = subprocess.run(
                    ["ffmpeg", "-y", "-ss", f"{s['mid']:.2f}", "-i", str(video),
                     "-frames:v", "1", "-vf", "scale='min(512,iw)':-2", "-q:v", "3", str(dst)],
                    capture_output=True,
                )
                if ex.returncode == 0 and dst.exists():
                    ok += 1
            progress[vid] = "done"
            save_progress(progress)
            print(f"  extracted {ok}/{len(need)}")


def embed_frames(paths: list[Path]) -> dict[str, np.ndarray]:
    """Embeds frames with SigLIP2, caching by relative path in EMB_CACHE."""
    cache: dict[str, np.ndarray] = {}
    if EMB_CACHE.exists():
        loaded = np.load(EMB_CACHE)
        cache = {k: loaded[k] for k in loaded.files}
    keys = [str(p.relative_to(FRAMES_DIR)).replace("\\", "/") for p in paths]
    missing = [(k, p) for k, p in zip(keys, paths) if k not in cache and p.exists()]
    if missing:
        import torch
        from PIL import Image
        from transformers import AutoModel, AutoProcessor
        print(f"embedding {len(missing)} frames with {MODEL_ID} …")
        processor = AutoProcessor.from_pretrained(MODEL_ID)
        model = AutoModel.from_pretrained(MODEL_ID)
        model.eval()
        with torch.no_grad():
            for i in range(0, len(missing), 16):
                batch = missing[i:i + 16]
                images = [Image.open(p).convert("RGB") for _, p in batch]
                inputs = processor(images=images, return_tensors="pt")
                feats = model.get_image_features(**inputs)
                if not torch.is_tensor(feats):  # transformers 5.x wraps the output
                    feats = feats.pooler_output
                feats = torch.nn.functional.normalize(feats, dim=-1).cpu().numpy()
                for (k, _), v in zip(batch, feats):
                    cache[k] = v.astype(np.float32)
                print(f"  {min(i + 16, len(missing))}/{len(missing)}")
                if (i // 16) % 5 == 4:  # checkpoint so an interrupted run resumes
                    np.savez_compressed(EMB_CACHE, **cache)
        np.savez_compressed(EMB_CACHE, **cache)
    return {k: cache[k] for k in keys if k in cache}


def split_holdout(items: list[tuple[str, np.ndarray, str]]) -> tuple[list, list]:
    """Held-out split by video where possible (avoids same-video leakage)."""
    by_vid = defaultdict(list)
    for it in items:
        by_vid[it[2]].append(it)
    vids = sorted(by_vid)
    if len(vids) >= 5:
        n_hold = max(1, int(len(vids) * HOLDOUT_FRAC))
        hold_vids = set(vids[::max(1, len(vids) // n_hold)][:n_hold])
        train = [it for v in vids if v not in hold_vids for it in by_vid[v]]
        hold = [it for v in hold_vids for it in by_vid[v]]
        return train, hold
    items = sorted(items, key=lambda it: (it[2], it[0]))
    n_hold = max(1, int(len(items) * HOLDOUT_FRAC))
    return items[n_hold:], items[:n_hold]


def kmeans_centroids(vectors: np.ndarray) -> np.ndarray:
    k = 1 if len(vectors) < 12 else 2 if len(vectors) < 40 else 3
    if k == 1:
        c = vectors.mean(axis=0, keepdims=True)
    else:
        from sklearn.cluster import KMeans
        c = KMeans(n_clusters=k, n_init=10, random_state=0).fit(vectors).cluster_centers_
    return c / np.linalg.norm(c, axis=1, keepdims=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-fetch", action="store_true", help="use cached frames only")
    ap.add_argument("--max-videos", type=int, help="limit videos fetched this run")
    args = ap.parse_args()

    shots = load_shots()
    counts = Counter(s["moment"] for s in shots)
    kept_classes = {m for m, c in counts.items() if c >= MIN_PER_CLASS}
    # Only emit moments the bundled pack knows — tag_moments validates against it.
    pack_path = OUT.parent / "malay_wedding.json"
    if pack_path.exists():
        pack_moments = set(json.loads(pack_path.read_text(encoding="utf-8"))["moments"])
        kept_classes &= pack_moments
    shots = [s for s in shots if s["moment"] in kept_classes]
    selected = select_shots(shots)
    print(f"{len(shots)} labeled shots, {len(kept_classes)} classes, {len(selected)} selected")

    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    adopted = adopt_legacy_frames(selected)
    if adopted:
        print(f"adopted {adopted} legacy frames from _temp_shotlabel")
    if not args.no_fetch:
        fetch_frames(selected, args.max_videos)

    have = [s for s in selected if frame_path(s).exists()]
    print(f"{len(have)}/{len(selected)} selected shots have frames")
    if not have:
        sys.exit("no frames available — run without --no-fetch first")

    embs = embed_frames([frame_path(s) for s in have])
    items = []
    for s in have:
        k = str(frame_path(s).relative_to(FRAMES_DIR)).replace("\\", "/")
        if k in embs:
            items.append((s["moment"], embs[k], s["vid"]))

    per_class = Counter(m for m, _, _ in items)
    usable = {m for m, c in per_class.items() if c >= MIN_PER_CLASS}
    dropped = sorted(set(per_class) - usable)
    if dropped:
        print(f"dropped thin classes (<{MIN_PER_CLASS} frames): {', '.join(dropped)}")
    items = [it for it in items if it[0] in usable]
    if not usable:
        sys.exit("no class has enough frames yet — fetch more videos")

    train, hold = split_holdout(items)
    print(f"train {len(train)} / holdout {len(hold)} frames, {len(usable)} classes")

    classes = {}
    for moment in sorted(usable):
        vecs = np.stack([v for m, v, _ in train if m == moment])
        classes[moment] = kmeans_centroids(vecs)

    # Calibration: nearest-centroid over the holdout.
    names = sorted(classes)
    correct_scores: dict[str, list[float]] = defaultdict(list)
    margins_correct, margins_wrong = [], []
    confusion: Counter = Counter()
    for m, v, _ in hold:
        scores = sorted(((n, float(np.max(classes[n] @ v))) for n in names),
                        key=lambda x: -x[1])
        pred, top = scores[0]
        margin = top - scores[1][1] if len(scores) > 1 else top
        confusion[(m, pred)] += 1
        if pred == m:
            correct_scores[m].append(top)
            margins_correct.append(margin)
        else:
            margins_wrong.append(margin)

    total = sum(confusion.values())
    acc = sum(c for (a, b), c in confusion.items() if a == b) / total if total else 0
    print(f"\nholdout accuracy: {acc:.2%} ({total} frames)")
    print(f"{'true class':22s} acc    n   top confusion")
    for m in names:
        row = {b: c for (a, b), c in confusion.items() if a == m}
        n = sum(row.values())
        if not n:
            continue
        wrong = sorted(((b, c) for b, c in row.items() if b != m), key=lambda x: -x[1])
        note = f"→ {wrong[0][0]} ({wrong[0][1]})" if wrong else ""
        print(f"{m:22s} {row.get(m, 0) / n:5.0%} {n:4d}   {note}")

    global_floor = float(np.percentile(
        [s for ss in correct_scores.values() for s in ss], THRESHOLD_PERCENTILE
    )) if correct_scores else 0.5
    margin_floor = float(np.percentile(margins_correct, THRESHOLD_PERCENTILE)) \
        if margins_correct else MARGIN_FLOOR_DEFAULT

    out = {
        "_note": "Generated by scripts/build_moment_prototypes.py — do not edit by hand.",
        "domain": "malay_wedding",
        "model": "siglip2-base-patch16-256",
        "dim": int(next(iter(classes.values())).shape[1]),
        "framesUsed": len(items),
        "holdoutAccuracy": round(acc, 4),
        "marginFloor": round(margin_floor, 4),
        "classes": [
            {
                "moment": m,
                "count": int(per_class[m]),
                "threshold": round(
                    float(np.percentile(correct_scores[m], THRESHOLD_PERCENTILE))
                    if correct_scores.get(m) else global_floor, 4),
                "centroids": [[round(float(x), 5) for x in c] for c in classes[m]],
            }
            for m in names
        ],
    }
    OUT.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"\nwrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
