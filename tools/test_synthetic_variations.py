# -*- coding: utf-8 -*-
"""外部データ不要: 合成の教師ラベル・再現性・保存形式の回帰チェック。"""

import json
import os
import tempfile
import unittest
from unittest.mock import patch

import cv2
import numpy as np

import train_paper_net_v2 as training
from synthetic_variations import (BACKGROUND_KINDS, PAPER_KINDS, camera_effects,
                                  object_occluder, procedural_background, procedural_paper)


class SyntheticVariationsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cv2.setNumThreads(1)
        cls.papers = [procedural_paper(np.random.default_rng(7), kind="text")]
        bg = np.full((480, 640, 3), 60, np.uint8)
        cls.backgrounds = [("fixture", bg, np.zeros(bg.shape[:2], np.uint8))]

    def test_all_materials_and_camera_effects_are_finite(self):
        rng = np.random.default_rng(30)
        for kind in BACKGROUND_KINDS:
            with self.subTest(background=kind):
                img = procedural_background(rng, 288, 384, kind=kind)
                img = camera_effects(rng, img)
                self.assertEqual(img.shape, (384, 288, 3))
                self.assertEqual(img.dtype, np.float32)
                self.assertTrue(np.isfinite(img).all())
                self.assertTrue(((img >= 0) & (img <= 1)).all())
        for kind in PAPER_KINDS:
            with self.subTest(paper=kind):
                _, img, quad = procedural_paper(rng, kind=kind)
                self.assertEqual(img.dtype, np.uint8)
                h, w = img.shape[:2]
                self.assertTrue(((quad >= [0, 0]) & (quad <= [w - 1, h - 1])).all())
                canvas = np.full((384, 288, 3), 0.2, np.float32)
                _, mask, _ = training.paste_paper(rng, canvas, (kind, img, quad), False)
                self.assertGreater(mask.sum(), 0)

    def test_seed_reproduces_images_masks_and_corners(self):
        for profile in ("legacy", "diverse"):
            with self.subTest(profile=profile):
                a = training.make_composite(np.random.default_rng(80), self.papers,
                                            self.backgrounds, True, synth_profile=profile)
                b = training.make_composite(np.random.default_rng(80), self.papers,
                                            self.backgrounds, True, synth_profile=profile)
                for left, right in zip(a, b):
                    np.testing.assert_array_equal(left, right)

    def test_rotated_corners_match_masks_and_negative_examples_stay_empty(self):
        rng = np.random.default_rng(90)
        negatives = 0
        for _ in range(64):
            gray, mask, canvas, quad = training.make_composite(
                rng, self.papers, self.backgrounds, True, synth_profile="diverse")
            self.assertEqual(gray.shape, (256, 256))
            self.assertEqual(mask.dtype, np.float32)
            self.assertTrue(np.isfinite(gray).all())
            self.assertTrue(((gray >= 0) & (gray <= 1)).all())
            self.assertTrue(np.isin(mask, [0, 1]).all())
            if quad is None:
                self.assertFalse(mask.any())
                negatives += 1
                continue
            self.assertTrue(cv2.isContourConvex(quad.astype(np.float32)))
            expected = np.zeros(canvas.shape[:2], np.float32)
            cv2.fillPoly(expected, [quad.round().astype(np.int32)], 1)
            expected = cv2.resize(expected, (256, 256), interpolation=cv2.INTER_AREA) > 0.5
            union = (expected | (mask > 0)).sum()
            iou = (expected & (mask > 0)).sum() / union
            self.assertGreater(iou, 0.975)
        self.assertGreater(negatives, 0)

    def test_printed_panels_and_occlusion_keep_full_main_page(self):
        quad = np.array([[60, 50], [200, 50], [200, 200], [60, 200]], np.float64)
        canvas = np.full((256, 256, 3), 0.2, np.float32)
        with patch.object(training, "target_quad", return_value=quad):
            # 同じ主な紙に印刷ブロックを追加しても、穴や別領域に分割しない。
            plain, full, _ = training.paste_paper(np.random.default_rng(3), canvas,
                                                 self.papers[0], False, p_panel=0)
            printed, labeled, _ = training.paste_paper(np.random.default_rng(3), canvas,
                                                      self.papers[0], False, p_panel=1)
        np.testing.assert_array_equal(full, labeled)
        self.assertGreater(np.abs(plain - printed).sum(), 0)
        hidden = object_occluder(np.random.default_rng(5), plain, quad)
        self.assertGreater(np.abs(hidden - plain)[full > 0.5].sum(), 0)
        self.assertEqual(full[120, 120], 1)
        # paste_scene も遮蔽物の可視マスクで主な紙のマスクを上書きしない。
        with patch.object(training, "paste_paper", return_value=(plain, full, quad)), \
                patch.object(training, "object_occluder", return_value=hidden) as occlude:
            found = False
            for seed in range(20):
                _, mask, result_quad = training.paste_scene(
                    np.random.default_rng(seed), canvas, self.papers, 0, 1,
                    synth_profile="diverse")
                if occlude.called:
                    np.testing.assert_array_equal(mask, full)
                    np.testing.assert_array_equal(result_quad, quad)
                    found = True
                    break
            self.assertTrue(found)

    def test_export_can_be_read_and_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(training, "load_assets",
                             return_value=({"train": self.papers}, self.backgrounds)):
            out = os.path.join(temp, "dataset")
            training.export_synthetic(12, out, seed=8, synth_profile="diverse")
            with open(os.path.join(out, "manifest.jsonl"), encoding="utf-8") as fp:
                records = [json.loads(line) for line in fp]
            with open(os.path.join(out, "config.json"), encoding="utf-8") as fp:
                config = json.load(fp)
            self.assertEqual(len(records), 12)
            self.assertEqual(config["positive"] + config["negative"], 12)
            self.assertEqual(config["source_papers"], [self.papers[0][0]])
            for record in records:
                image = cv2.imread(os.path.join(out, record["image"]), cv2.IMREAD_GRAYSCALE)
                mask = cv2.imread(os.path.join(out, record["mask"]), cv2.IMREAD_GRAYSCALE)
                self.assertEqual(image.shape, (256, 256))
                self.assertEqual(mask.shape, image.shape)
                self.assertTrue(np.isin(mask, [0, 255]).all())
                self.assertEqual(bool(mask.any()), record["paper_present"])
                self.assertEqual(record["split"], "train")
            with self.assertRaises(FileExistsError):
                training.export_synthetic(12, out, seed=8)

    def test_invalid_sampling_probabilities_are_rejected(self):
        for options in (dict(p_negative=-0.1), dict(p_negative=0.9),
                        dict(p_panel=float("nan")), dict(p_procedural=1.1),
                        dict(p_multi=0.7, p_occluder=0.4)):
            with self.subTest(options=options), self.assertRaises(ValueError):
                training.synthesis_options("diverse", **options)

    def test_clipped_page_retry_keeps_best_available_mask(self):
        canvas = np.zeros((256, 256, 3), np.float32)
        quad = np.array([[-30, 0], [200, 0], [200, 200], [-30, 200]], np.float64)
        # 全候補が可視面積の範囲外でも、中央値0.5に最も近い候補を返す。
        candidates = [(canvas, np.full((256, 256), v, np.float32), quad)
                      for v in (0.99, 0.96, 0.98, 0.97)]
        with patch.object(training, "paste_paper", side_effect=candidates):
            _, mask, result_quad = training.paste_scene(
                np.random.default_rng(7), canvas, self.papers, 0, 0, p_clipped=1)
        np.testing.assert_array_equal(mask, candidates[1][1])
        np.testing.assert_array_equal(result_quad, quad)


if __name__ == "__main__":
    unittest.main()
