"""Render a contact sheet of image and draft-mask overlays for visual review."""

from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1] / "training_data" / "paper_photos"


def main() -> None:
    groups = [("ordinary", range(1, 51)), ("challenging", range(101, 151))]
    for name, numbers in groups:
        sheet = np.full((10 * 180, 5 * 220, 3), 255, np.uint8)
        for index, number in enumerate(numbers):
            stem = f"{number:04d}.png"
            image = cv2.imread(str(ROOT / "images" / stem))
            mask = cv2.imread(str(ROOT / "loss_masks_draft" / stem), cv2.IMREAD_GRAYSCALE)
            if image is None or mask is None:
                raise FileNotFoundError(stem)
            if image.shape[:2] != mask.shape:
                raise ValueError(f"Mask size differs: {stem}")
            edge = cv2.morphologyEx(mask, cv2.MORPH_GRADIENT, np.ones((7, 7), np.uint8))
            display = image.copy()
            display[edge > 0] = (0, 0, 255)
            scale = min(210 / image.shape[1], 150 / image.shape[0])
            display = cv2.resize(display, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            row, col = divmod(index, 5)
            x = col * 220 + (220 - display.shape[1]) // 2
            y = row * 180
            sheet[y:y + display.shape[0], x:x + display.shape[1]] = display
            cv2.putText(sheet, stem[:4], (col * 220 + 5, row * 180 + 171),
                        cv2.FONT_HERSHEY_SIMPLEX, .48, (0, 0, 0), 1, cv2.LINE_AA)
        out = ROOT / f"loss_mask_review_{name}.jpg"
        cv2.imwrite(str(out), sheet, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(out)


if __name__ == "__main__":
    main()
