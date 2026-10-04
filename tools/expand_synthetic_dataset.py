# -*- coding: utf-8 -*-
"""合成データを条件別に増やし、全ペアの検査と一覧画像を保存する。"""

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np

from train_paper_net_v2 import ROOT, export_synthetic, synthesis_options


GROUPS = {
    "ordinary": {},
    "printed_layouts": dict(p_procedural=0.80, p_panel=0.70),
    "overlap_occlusion": dict(p_multi=0.35, p_stack=0.30, p_occluder=0.30,
                              p_panel=0.45),
    "clipped_pages": dict(p_multi=0.05, p_stack=0.10, p_clipped=0.65,
                          p_occluder=0.10, p_procedural=0.50),
    "negative_heavy": dict(p_negative=0.45, p_procedural=0.40),
}


def verify_group(directory, seen_hashes):
    with (directory / "manifest.jsonl").open(encoding="utf-8") as fp:
        records = [json.loads(line) for line in fp]
    config = json.loads((directory / "config.json").read_text(encoding="utf-8"))
    positives = clipped = duplicates = 0
    fractions = []
    for record in records:
        image_path = directory / record["image"]
        image = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
        mask = cv2.imread(str(directory / record["mask"]), cv2.IMREAD_GRAYSCALE)
        if image is None or mask is None or image.shape != (256, 256) or mask.shape != image.shape:
            raise ValueError(f"invalid image/mask: {image_path}")
        if not np.isin(mask, [0, 255]).all():
            raise ValueError(f"non-binary mask: {image_path}")
        present = bool(mask.any())
        if present != record["paper_present"] or record["split"] != "train":
            raise ValueError(f"invalid label/split: {image_path}")
        if record["corners"] is None:
            if present:
                raise ValueError(f"missing corners: {image_path}")
        else:
            quad = np.asarray(record["corners"], np.float32)
            if quad.shape != (4, 2) or not np.isfinite(quad).all() or not cv2.isContourConvex(quad):
                raise ValueError(f"invalid corners: {image_path}")
            if not present:
                raise ValueError(f"empty positive mask: {image_path}")
            clipped += int(((quad < 0) | (quad > 1)).any())
        positives += int(present)
        fractions.append(float((mask > 0).mean()))
        digest = hashlib.sha256(image_path.read_bytes()).hexdigest()
        duplicates += int(digest in seen_hashes)
        seen_hashes.add(digest)
    if len(records) != config["count"] or positives != config["positive"]:
        raise ValueError(f"config count mismatch: {directory}")
    if duplicates:
        raise ValueError(f"duplicate images: {directory}: {duplicates}")
    if len(list((directory / "images").glob("*.png"))) != len(records) or \
            len(list((directory / "masks").glob("*.png"))) != len(records):
        raise ValueError(f"file count mismatch: {directory}")
    # 保存済みデータから均等に16枚抽出。生成条件の比率は群名と区別する。
    tiles = []
    for i in np.linspace(0, len(records) - 1, min(16, len(records))).astype(int):
        record = records[int(i)]
        image = cv2.imread(str(directory / record["image"]), cv2.IMREAD_COLOR)
        mask = cv2.imread(str(directory / record["mask"]), cv2.IMREAD_GRAYSCALE)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(image, contours, -1, (40, 40, 240), 2)
        tiles.append(image)
    sheet = np.zeros((4 * 256, 4 * 256, 3), np.uint8)
    for i, tile in enumerate(tiles):
        y, x = divmod(i, 4)
        sheet[y * 256:(y + 1) * 256, x * 256:(x + 1) * 256] = tile
    if not cv2.imwrite(str(directory / "preview.jpg"), sheet):
        raise OSError(f"cannot write preview: {directory}")
    return dict(count=len(records), positive=positives, negative=len(records) - positives,
                clipped_positive=clipped, duplicate_images=duplicates,
                mask_area_min=min(fractions), mask_area_max=max(fractions),
                seed=config["seed"], options=config["options"],
                source_papers=config["source_papers"],
                source_backgrounds=config["source_backgrounds"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--per-group", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=20261002)
    args = parser.parse_args()
    if args.per_group <= 0:
        parser.error("--per-group must be > 0")
    args.out.mkdir(parents=True, exist_ok=False)
    cv2.setNumThreads(1)
    # 前回の256組との完全重複も検査する。
    previous = Path(ROOT) / "training_data" / "synthetic_diverse_2026-10-02" / "images"
    seen = {hashlib.sha256(p.read_bytes()).hexdigest() for p in previous.glob("*.png")}
    groups = {}
    for i, (name, overrides) in enumerate(GROUPS.items()):
        print(f"group {i + 1}/{len(GROUPS)}: {name}", flush=True)
        options = synthesis_options("diverse", **overrides)
        directory = args.out / name
        export_synthetic(args.per_group, str(directory), seed=args.seed + i, **options)
        groups[name] = verify_group(directory, seen)
        print(f"verified: {name}: {groups[name]['positive']} positive, "
              f"{groups[name]['negative']} negative", flush=True)
    summary = dict(count=sum(g["count"] for g in groups.values()),
                   positive=sum(g["positive"] for g in groups.values()),
                   negative=sum(g["negative"] for g in groups.values()),
                   groups=groups, verification="all_pairs_checked",
                   split="train", duplicate_images=0,
                   previous_batch_compared=str(previous.relative_to(Path(ROOT))),
                   label_policy="full_main_page_including_occlusion_clipped_to_frame")
    (args.out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
                                            encoding="utf-8")
    print(f"complete: {summary['count']} pairs ({summary['positive']} positive, "
          f"{summary['negative']} negative): {args.out}", flush=True)


if __name__ == "__main__":
    main()
