"""Create draft paper masks for selected generated photographs.

Requires: uv run --python 3.10 --with opencv-python-headless python tools/create_loss_masks.py
The output is a pseudo-label and must be reviewed before use as loss ground truth.
"""

from pathlib import Path
import argparse

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1] / "training_data" / "paper_photos"


def make_mask(image: np.ndarray, number: int) -> np.ndarray:
    height, width = image.shape[:2]
    scale = min(1.0, 384 / max(height, width))
    small = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    h, w = small.shape[:2]

    # A narrow image border is background; the middle of the dominant page is foreground.
    # GrabCut then follows color and edge transitions around the sheet.
    seed = np.full((h, w), cv2.GC_PR_BGD, np.uint8)
    border = max(3, int(min(h, w) * 0.025))
    seed[:border, :] = cv2.GC_BGD
    seed[-border:, :] = cv2.GC_BGD
    seed[:, :border] = cv2.GC_BGD
    seed[:, -border:] = cv2.GC_BGD
    seed[int(h * .29):int(h * .71), int(w * .29):int(w * .71)] = cv2.GC_FGD
    seed[int(h * .10):int(h * .90), int(w * .10):int(w * .90)] = np.where(
        seed[int(h * .10):int(h * .90), int(w * .10):int(w * .90)] == cv2.GC_FGD,
        cv2.GC_FGD, cv2.GC_PR_FGD,
    )
    bg = np.zeros((1, 65), np.float64)
    fg = np.zeros((1, 65), np.float64)
    cv2.grabCut(small, seed, None, bg, fg, 5, cv2.GC_INIT_WITH_MASK)
    mask = np.isin(seed, (cv2.GC_FGD, cv2.GC_PR_FGD)).astype(np.uint8) * 255
    if number in {7, 17, 27, 37, 47, 105, 115, 125, 135, 145}:
        blue = small[:, :, 0].astype(np.int16)
        green = small[:, :, 1].astype(np.int16)
        red = small[:, :, 2].astype(np.int16)
        color_mask = ((blue - red > 13) & (blue - green > 2)).astype(np.uint8) * 255
        color_mask = cv2.morphologyEx(color_mask, cv2.MORPH_CLOSE, np.ones((13, 13), np.uint8))
        if .20 < np.count_nonzero(color_mask) / color_mask.size < .88:
            mask = color_mask

    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    count, labels, stats, centers = cv2.connectedComponentsWithStats(mask)
    if count > 1:
        candidates = list(range(1, count))
        central = [i for i in candidates if
                   abs(centers[i][0] - w / 2) < w * .25 and
                   abs(centers[i][1] - h / 2) < h * .25]
        chosen = max(central or candidates, key=lambda i: stats[i, cv2.CC_STAT_AREA])
        mask = (labels == chosen).astype(np.uint8) * 255
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if contours:
        hull = cv2.convexHull(max(contours, key=cv2.contourArea))
        mask = np.zeros_like(mask)
        cv2.fillConvexPoly(mask, hull, 255)
    return cv2.resize(mask, (width, height), interpolation=cv2.INTER_NEAREST)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ids", nargs="*", type=int)
    args = parser.parse_args()
    ids = args.ids or (list(range(1, 51)) + list(range(101, 151)))
    out = ROOT / "loss_masks_draft"
    out.mkdir(exist_ok=True)
    for number in ids:
        name = f"{number:04d}.png"
        image = cv2.imread(str(ROOT / "images" / name))
        if image is None:
            raise FileNotFoundError(name)
        mask = make_mask(image, number)
        if not cv2.imwrite(str(out / name), mask):
            raise OSError(f"Could not write {name}")
        print(f"{name} {np.count_nonzero(mask) / mask.size:.3f}")


if __name__ == "__main__":
    main()
