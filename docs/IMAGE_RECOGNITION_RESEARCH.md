# 画像認識モデル調査 — MIT 等の寛容ライセンスで軽量に動く選択肢

> 目的: MusicBook の「紙面検出」をさらに高精度化する、および将来の機能拡張
> (文字起こし / 楽譜認識など) に使える、**MIT・Apache-2.0 等の商用寛容ライセンス**で
> スマホ上で軽量に動く画像認識モデルとランタイムの選定記録。
> 調査日: 2026-09-24

## 1. 結論 (先に推奨)

| 用途 | 第 1 推奨 | ライセンス | 備考 |
|---|---|---|---|
| 推論ランタイム (Flutter) | **flutter_onnxruntime** | MIT | ONNX Runtime 本体も MIT。Android/iOS/デスクトップ/WEB 対応 |
| 推論ランタイム (代替) | tflite_flutter / flutter_litert (LiteRT) | Apache-2.0 | Android で NNAPI/GPU Delegate が使える |
| 紙面 (四隅) 検出の ML 強化 | **YOLOX-nano / PP-PicoDet** を「紙=1 クラス」で再学習 | Apache-2.0 | 入力 224〜416px・数 MB・数十 ms 推論 |
| セグメンテーション方式 | MobileNetV3 + U-Net を合成データでセルフ学習 | モデルは自作 (コード Apache-2.0) | 境界マスク→凸包→現行の四角形推定に流用可能 |
| OCR (将来: プリントの文字起こし) | **PaddleOCR** (mobile 系) / **docTR** | Apache-2.0 / Apache-2.0 | 日本語は PaddleOCR が有力 |
| 楽譜認識 (OMR, 参考) | Audiveris は **AGPL-3.0** のため非推奨 | — | 組み込みはライセンス違反リスク大 |

**採用しないもの (ライセンス理由)**

- **Ultralytics YOLO (v5 / v8 / v11)** — AGPL-3.0。アプリ組込みはソース開示義務が発生 (または有償ライセンス)。
- **YOLO-NAS** — コードは Apache-2.0 相当でも**重みがカスタムライセンス (非商用)**。
- **ML Kit Document Scanner** — OSS でなく Google 利用規約ベース。MIT 要件を満たさない。
- **DocTr / DocTr++ (fh2019ustc/DocScanner)** — 研究発表由来で**ライセンス条件要確認**。商用組込みは見送り。

## 2. 現状の実装と位置づけ

本アプリの紙面検出は現状 **OpenCV 等に依存しない純 Dart 実装**
(`lib/services/detector.dart`: 大津二値化 → 最大白連結成分 → 凸包 → 最大面積四角形)。
画像サイズ 320px 幅で数 ms 〜 数十 ms と十分軽量で、**明るい紙 × 暗い背景**では高精度。

ML モデルを入れる価値があるケース:

- 白い机の上の白い紙など、**輝度コントラストに頼れない場面**
- 紙が画面端に切れている/複数の紙がある場面
- 影や照明ムラで二値化が崩れる場面

→ セグメンテーション or 検出モデルで「紙領域」をロバストに推定し、
その後処理 (凸包→最大面積四角形) は現行実装を再利用するのが最小変更。

## 3. ランタイム比較 (Flutter から使えるもの)

| ランタイム / プラグイン | ライセンス | 対応 | 備考 |
|---|---|---|---|
| [flutter_onnxruntime](https://pub.dev/packages/flutter_onnxruntime) | **MIT** | Android / iOS / Linux / macOS / Windows / Web | ONNX Runtime (MIT) の薄いラッパ。エッジでは XNNPACK/NNAPI/CoreML |
| ONNX Runtime 本体 | **MIT** | — | モデルは PyTorch/TF からエクスポート |
| [tflite_flutter](https://pub.dev/packages/tflite_flutter) / flutter_litert (LiteRT) | Apache-2.0 | Android / iOS ほか | LiteRT (旧 TensorFlow Lite)。事前学習モデルが最も豊富 |
| MediaPipe Tasks (Vision) | Apache-2.0 | Android / iOS / Web | ObjectDetector / InteractiveSegmenter 等の完成タスク |
| opencv_dart | Apache-2.0 (OpenCV 4.5+) | Android / iOS / Desktop | 従来型 CV (Canny, findContours) も純 Dart 実装で代替済みのため今回は不要 |

目安: モデル 2〜10 MB (int8 量子化), 入力 224〜416px, 最新端末で 1 推論 10〜50 ms。
UI に支障のない範囲であり、撮影直後の 1 枚解析には十分。

## 4. モデル候補 (寛容ライセンスのもののみ)

| モデル | ライセンス | サイズ目安 | 本アプリでの使い方 |
|---|---|---|---|
| **YOLOX** (nano/tiny/s) | Apache-2.0 | 1〜10 MB | 「紙」1 クラス検出。四隅のバウンディング + コーナー回帰に改造例あり |
| **PP-PicoDet** (PaddleDetection) | Apache-2.0 | 1〜10 MB | 同上。モバイル特化で速い |
| **NanoDet / RTMDet-Nano** | Apache-2.0 | 2〜5 MB | 同上 |
| **MobileNet-SSD** (TF公式) | Apache-2.0 | ~5 MB | ベースライン。古いが安定 |
| **EfficientDet-Lite** (TF) | Apache-2.0 | 4〜15 MB | LiteRT 併用なら整備が良い |
| **RT-DETR / RF-DETR** (実時間 Transformer 検出) | Apache-2.0 | 20 MB〜 | 精度重視時。軽量版は nano 系 |
| **MobileNetV3 + U-Net** (セルフ学習) | コード Apache-2.0 | 2〜10 MB | 紙マスク推定 → 凸包 → 四角形 (現行後処理を再利用) |
| PaddleOCR (det+rec mobile) | Apache-2.0 | ~10 MB | 将来の OCR 機能 |
| docTR (mindee) | Apache-2.0 | — | 将来の OCR 機能 (英語中心。日本語は弱め) |

### 楽譜固有の注意 (OMR: 光学楽譜認識)

- [Audiveris](https://github.com/Audiveris/audiveris) — **AGPL-3.0**。アプリ組込みには不向き。
- oemer など研究実装はライセンス表記が甘いものが多く、組込み前に必ず LICENSE を確認すること。
- 楽譜の「認識」(音への変換) は要件が重い。本アプリは「紙資料の閲覧+手書きメモ」が主目的のため、OMR はスコープ外とするのが妥当。

## 5. 統合手順スケッチ (ONNX + flutter_onnxruntime)

1. **学習** (PC 側): 合成データ (白紙 A4 をランダム台形投影 + 背景写真合成) で
   YOLOX-nano に「紙」1 クラスを学習。
2. **変換**: `torch.onnx.export` → `onnxruntime.quantization.quantize_dynamic` で int8 化 (≈1/4 サイズ)。
3. **組込み**:
   ```yaml
   dependencies:
     flutter_onnxruntime: ^x.y.z   # MIT
   ```
   - モデルは `assets/models/paper_quad.onnx` として同梱 (または初回起動時にダウンロード)。
4. **推論**: 検出用に 320px に縮小したビットマップ → `OnnxRuntime.createSession` →
   出力ボックス/コーナーを現行 `_orderCorners`/`_padCorners` に渡す。
5. **フォールバック**: 推論失敗・低信頼度時は現行の純 Dart ヒューリスティックへ。
   (実装済みの `DocumentDetector.detect` はフォールバック経路としてそのまま残す)

## 6. ソース / 参照

- [flutter_onnxruntime (pub.dev, MIT)](https://pub.dev/packages/flutter_onnxruntime)
- [ONNX Runtime](https://onnxruntime.ai) / [onnx/models](https://github.com/onnx/models)
- [Ultralytics Docs (AGPL の確認)](https://docs.ultralytics.com)
- [LearnML: Apache-2.0 系オブジェクト検出まとめ](https://www.learnml.io)
- [Roboflow Blog: モバイル向け物体検出](https://blog.roboflow.com)
- [LeYOLO (arXiv)](https://arxiv.org)
- [fh2019ustc/DocScanner (DocTr / DocTr++)](https://github.com/fh2019ustc/DocScanner)
- [mindee/doctr (Apache-2.0 OCR)](https://github.com/mindee/doctr)
- [DewarpNet プロジェクトページ](https://sagniklp.github.io)
- [thomasjhuang/deep-learning-for-document-dewarping](https://github.com/thomasjhuang/deep-learning-for-document-dewarping)
- [TensorFlow Blog: TFLite Flutter プラグイン](https://blog.tensorflow.org)
- [LiteRT (旧 TensorFlow Lite)](https://ai.google.dev/edge/litert)

## 6a-2. 実装済み: 自前学習の紙面セグメンテーション (2026-09-25)

「紙を検出する寛容ライセンスの学習済み重みは存在しない」(§4) ため、**合成データで自前学習した重み**を採用した。

- 構成: TinyUNet (386k パラメータ / fp32 1.5MB) — 入力 グレースケール 256x256、出力 紙マスク
- 学習データ: ホモグラフィ合成を無限生成 (`tools/train_paper_net.py`)。
  照明ムラ / 白い机 (明背景) / ドロップシャドウ / 譜線テクスチャ / 枠外はみ出し / センサノイズを含む
- 学習: BCE、Adam、CPU (8スレッド) で 1500 step 約40分。合成検証 IoU は学習ログ参照
- 推論: flutter_onnxruntime (MIT) + ONNX Runtime。実機 1 回 50〜150ms (初回はウォームアップあり)
- 後処理: マスク → 既存の純 Dart 検出器 (`detectLuminance`) で連結成分→凸包→四角形
- フォールバック: モデル不在/推論失敗/マスク不成立時は大津ベースのヒューリスティックへ (精度劣化なしの安全設計)
- 改善ループ: アプリの四隅手修正 (実写+正解) を将来のファインチューニングデータにできる

## 6b. Index / 簡易 OCR の設計 (2026-09-24 追加)

### Index (= 実装済み)

- `MusicDocument.tags` (タグ) と `MusicPage.note` (ページメモ) を Hive に保存し、
  `DocSearch` (lib/services/search.dart) でタイトル/タグ/ページメモを横断検索する。
- 検索は空白区切り AND、大文字小文字を無視。ホームの検索窓から利用でき、
  一致理由 (タイトル/タグ/ページメモ) をカードに表示する。
- 手書きストロークはベクトルデータで OCR 対象外。音取りメモなどは「ページメモ」に記す運用。

### 簡易 OCR (未実装 — 実装パス)

フロー: ページ画像 → テキスト認識 → `MusicPage.ocrText` に保存 → `DocSearch` の
検索対象に追加するだけ (UI は既存の検索窓を流用)。

推奨構成 (ライセンス完全準拠):
1. **モデル**: PaddleOCR v4 mobile (det + rec, Apache-2.0) を ONNX へ変換、int8 量子化
2. **ランタイム**: flutter_onnxruntime (MIT) + NNAPI/XNNPACK
3. **前処理**: 検出済みの台形補正済みページをそのまま入力できる (本アプリの強み)
4. **後処理**: DB (Differentiable Binarization) の境界復元 + CTC/辞書デコード
5. **実行タイミング**: 保存直後のバックグラウンド (Isolate) + 手動「テキスト認識」ボタン
6. **サイズ**: det 4.7MB + rec 10MB 程度 → アセット同梱で +15MB

代替: ML Kit Text Recognition v2 は導入が圧倒的に容易で日本語精度も高いが、
SDK が OSS でないため MIT 要件がある場合は非採用。設計上 `OcrEngine` インターフェースを
切り出しておけば、まず ML Kit で価値検証 → PaddleOCR へ置換、という段階導入も可能。

楽譜の音符認識 (OMR) はスコープ外 (§4 参照)。

## 7. 更新方針

モデルを選定・組込みした際は、この文書に「採用モデル / 量子化 / 計測したレイテンシ /
端末」を追記する。ライセンスは時間とともに変わるため、組込み前に必ず当該リポジトリの
LICENSE を再確認する。
