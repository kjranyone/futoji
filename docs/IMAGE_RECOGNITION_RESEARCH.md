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

## 6a-3. 実写データの収集と評価 (2026-09-28)

合成データ・生成画像・BiRefNet 擬似ラベルでは実写での精度が測れないため、
アプリの手修正を正解として貯め、アプリと同一の推論経路で評価する。

**収集** (アプリ)
- ホーム右上メニュー「検出改善用に切り抜き結果を保存」を ON にする (既定 OFF、設定は Hive に保存)
- 切り抜き画面で確定するたびに、表示していた正立画像 (長辺 1000px) と四隅を保存
  (`lib/services/training_capture.dart`)。形式は `<id>.jpg` + `<id>.json` (`QuadLabel`)
  - `corners`: 確定した四隅 (正解) / `predicted`: そのときのモデル出力 (未検出は null) / `edited`: 手で動かしたか
- 取り出し (Android):
  `adb pull /sdcard/Android/data/com.kjranyone.mymusicbook/files/training_captures training_data/eval`

**評価** (PC)
```
pwsh tools/setup_ort_windows.ps1              # 初回のみ ORT 1.20 (MIT) を tools/ort/ へ
flutter test test/paper_net_eval_test.dart     # training_data/eval を評価
```
- 推論は `OrtSessionBundle.detectPaperQuad` をそのまま使う (前処理・穴埋め・四角形推定までアプリと同一)
- 指標: 角誤差 (対応角の距離 / 画像対角線, 4 角平均)、四角形 IoU、成功率 @1% / 2% / 5%、検出率
- 出力: `build/paper_eval/report.md`, `summary.json`, 正解 (緑) / 予測 (赤) のオーバーレイ画像
- 環境変数 `PAPER_EVAL_DIR` / `PAPER_MODEL` / `ORT_DYLIB` / `PAPER_EVAL_OUT` で切り替え可能
  (新モデルの比較は `PAPER_MODEL` を差し替えて同じデータで回す)

注意: `detectLuminance` は四角形を外側へ短辺比 2% 広げる (`_padCorners`)。
手修正の正解が紙の縁ぴったりなら、この分が誤差の下限として乗る。

## 6a-4. v2 モデル: 貼り付け合成 + 事前学習エンコーダ (2026-09-28)

v1 の精度不足の主因は「学習データと実際の撮影の違い」(生成画像は紙が中央に大きく写った単純な構図) と
「BiRefNet 擬似ラベルの誤り」だった。既存データだけで次のように作り直した。

- ラベル: `tools/prepare_quad_labels.py` で BiRefNet マスクに四角形を当てはめ、
  マスクとの IoU ≥ 0.93 の 100 枚だけ採用 (残りはマスク自体が壊れていた)。マスクは四隅から作る
- データ: `tools/train_paper_net_v2.py` で、紙を四隅で切り出し、実写の散らかった机
  (紙領域を除いた部分) や手続き背景へ、大きさ 4〜70% / 任意回転 / 射影 / はみ出し / 影で貼り付け。
  紙なしサンプル 5%、90 度回転、4:3・16:9 を 256x256 へ縦横比無視で縮小 (アプリと同じ)
- モデル: ImageNet 事前学習済み MobileNetV3-Small (BSD-3) + 軽量 U-Net デコーダ。
  1/2 解像度でロジットを出して 256 へ拡大。約 109 万パラメータ / fp32 4.3MB。
  入出力は v1 と同じ (1x1x256x256 グレー → ロジット) なのでアプリ側は差し替えのみ
- 学習: BCE + Dice, AdamW, 2500 step, batch 16, CPU 約 47 分
- 結果 (2026-09-28 再検証。当初の報告は評価データの漏れがあったため差し替え):
  - **実写・学習に一切未使用** (`training_data/eval_heldout`: 紙あり 4 枚 + 紙なし 8 枚。四隅は目視で手付け。
    紙なし 8 枚のうち 6 枚はほぼ同じ場面で実質 3 場面、紙ありも同じチラシ・同じ机で多様性は低い)。
    アプリと同一経路の Dart ハーネス (`./dev.ps1 eval -Data training_data/eval_heldout`) で:

    | 条件 | モデル | 角誤差中央値 | 平均 IoU | 成功@2% | 紙なし誤検出 |
    |---|---|---|---|---|---|
    | 横 (撮影そのまま) | v1 | 7.07% | 0.74 | 25% | 0/8 |
    | 横 | v2 (pad 0) | 1.46% | 0.94 | 100% | 0/8 |
    | 縦 (90 度回転版 `eval_heldout_rot90`) | v1 | 12.65% | 0.56 | 0% | 1/8 |
    | 縦 | v2 (pad 0) | 1.82% | 0.91 | 50% | 0/8 |

  - 合成テスト (チェックポイント選択に使っていない別シード 256 枚): IoU v1 0.53 → v2 0.98。
    ただし背景素材は学習と共通なので参考値
  - 以前記載した「実写 4 枚で 2.71% → 1.68%」は、背景素材として学習に使った画像での評価
    (かつ BiRefNet 由来の不正確なラベル) だったため撤回
  - 四隅の外側パディング: v2 はマスクが紙の縁に合うため 0.02 → 0 (`DocumentDetector.netCornerPad`)。
    上表は pad 0。pad 0.02 では横 1.80% / 縦 2.20%
  - 紙なし判定しきい値 2% → 5% (`DocumentDetector.minPaperMaskFraction`)
- 実機 (Lenovo TB J716F, profile ビルド, `./dev.ps1 selftest`):
  - モデル読み込み 242ms、推論 105〜120ms (紙なし) / 200〜250ms (紙あり、四角形推定込み)
  - 角誤差は PC ハーネスとほぼ一致 (0.33% / 1.34% / 1.82% / 1.84%。差はデコーダの縮小方式の違い)
  - 切り抜き経路 (メイン isolate) とライブ検出ワーカー (別 isolate) で結果が一致
- 既知の限界: 背景まで完全に一様な人工画像 (単色の机に真っ白な矩形) では検出しない
  (実写の机の上の無地の紙は検出する)。実写の評価データが少なく同じ場面ばかりなので、
  アプリの「検出改善用に切り抜き結果を保存」で多様な場面を集めて `eval_heldout` を増やすこと

再学習: `pwsh` で `uv` 環境 (tools/.venv) を作り、
`tools/.venv/Scripts/python tools/prepare_quad_labels.py` → `tools/.venv/Scripts/python tools/train_paper_net_v2.py --steps 2500 --batch 16 --workers 3`
→ `build/paper_seg_v2.onnx` を `assets/models/paper_seg.onnx` へコピー。

## 6a-5. v4 モデル: 重なった楽譜への対応 (2026-09-28)

実写の評価セット (ラーメンのチラシ 1 種類) では楽譜の場面を測れていなかったため、
学習に未使用の生成写真から難例 13 枚 (重なり 6・折れ 5・普通 2) に四隅を手付けした
(`tools/hard_labels.json` → `training_data/eval_hard`、主指標 IoU)。

- v2 の最大の弱点: **重なった複数枚を 1 枚として塗る** (難例の重なり IoU 0.69〜0.86)
- v3: 合成に「奥に 1〜2 枚 + 手前に主な紙 (正解は手前の 1 枚だけ)」と「主な紙の上に小さな紙
  (正解は隠れた部分を含む主な紙全体)」を追加 → 難例 IoU 0.944。ただし副作用で、色付きチラシを
  色の境目で分割する失敗が実写に出た (eval_heldout_rot90 の fail_upright: IoU 0.63)
- v4 (採用): 紙の内側に色の帯・ブロックを描く合成 (正解は紙全体) を追加して v3 から追加学習

| 評価セット (切り抜き経路 1000px、アプリと同じ端末デコーダ) | v1 | v2 | v4 |
|---|---|---|---|
| 実写・横 (紙あり 4 / 紙なし 8) IoU | 0.707 | 0.937 | 0.932 |
| 実写・縦 (90 度回転) IoU | 0.539 | 0.916 | 0.928 |
| 難例 (楽譜 13) IoU | 0.809 | 0.875 | **0.936** |
| 難例 角誤差中央値 / 成功@5% | 4.34% / 54% | 3.62% / 62% | **2.37% / 100%** |
| 紙なし誤検出 | 0/8 | 0/8 | 0/8 |

評価ハーネスのデコードについて: 当初ハーネスは image パッケージで縮小していたが、アプリは端末の
デコーダ (fast_decode.dart) で縮小するため、折れのある画像などで結果がずれていた (実機の自己診断で発見。
例: hard_0111 PC 1.01% / 実機 3.01%)。ハーネスを decodeWorkImage に揃えた後は、実機の自己診断と
13 枚中 12 枚で角誤差が完全一致 (残り 1 枚も 2.94% / 3.01%)。上表はこの揃えた後の値。
6a-4 以前の表の数値は旧デコードでの値。

実機 (Lenovo TB J716F, v4, `./dev.ps1 selftest`): 実写・難例とも全件完走、切り抜き経路とライブ検出
ワーカー経路の結果は全件一致。モデル読み込み 0.24 秒、推論 0.11〜0.36 秒、保存 1.8〜4.2 秒 (紙あり)。

ライブ検出の入力 (長辺 480px, `PAPER_SIM_STREAM=1`) でも同傾向 (難例 v2 0.871 → v4 0.953)。

後処理の検討 (採用せず、評価ハーネスで切り替え可能):
- エッジ吸着 `snapQuadToEdges` (`PAPER_SNAP=1`): 実写は改善、難例は成功@5% が悪化
- マスクのオープニング `openMask` (`PAPER_OPEN=r`): v3 のはみ出し起因の未検出は救えたが、
  v4 では有無で差がない → `netMaskOpenRadius = 0`

学習: `tools/train_paper_net_v2.py --init-pth build/paper_seg_v3.pth --p-multi 0.3 --p-occluder 0.15
--p-panel 0.35 --steps 1500 --lr 8e-4` (v3 は v2 から `--p-multi 0.35 --p-occluder 0.15 --steps 2000 --lr 1e-3`)。
構造は v2 と同一。v4 の実機での自己診断は完了 (上記)。

残る弱点: 丸まった角・大きな折れ (0143, 0179 など IoU 0.84〜0.87)、評価データの少なさ。

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
