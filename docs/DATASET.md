# training_data — 紙面検出モデルのデータセットと改善サイクル

`training_data/` は容量が大きいため git 管理外 (.gitignore)。この文書がレイアウトと
運用の唯一の定義。サイクルを 1 周するたびに `./dev.ps1 check` を通しておくこと。

## レイアウト

```
training_data/
├── paper_photos/            学習: 紙素材 (生成写真 200+ 枚 + 四隅ラベル quads.json)
│   ├── images/  masks/  qa_overlays/  loss_masks_draft/
│   └── quads_manual.json    手検証の四隅 (目視・意図ベース)。prepare_quad_labels.py
│                            が自動当てはめより優先する (再生成で消えない)
├── real_captures/           学習: 実写キャプチャ (合成の背景として使用 + BiRefNet マスク)
├── train_real/              学習: 直接学習ペア (紙なし = 空マスク も含む)
│   ├── images/<id>.jpg      promote が eval/ から移動 / ネガティブは tools/add_imagegen_negatives.py
│   ├── masks/<id>_mask.png  補正四隅をラスタライズ (ネガティブは空マスク)
│   └── manifest.json        由来・昇格日時
├── synthetic_diverse_2026-10-02/   保存合成 256 組   ┐ 奇数 id = 学習 (--synth-ratio で混合)
├── synthetic_expanded_2026-10-02/  保存合成 5,000 組 ┘ 偶数 id = 評価専用
│                            tools/eval_synthetic.py -M <model.onnx> --split holdout
├── synthetic_negpool*_2026-10-02/  紙なし合成プール (中身は train_real に取り込み済み)
├── eval/                    評価のステージング: アプリの「検出改善用に保存」→ pull
│                            (promote で学習に昇格すると消える。評価レポートにも使う)
├── eval_heldout/            評価: 学習未使用の実写 (横持ち)      ← 主指標
├── eval_heldout_rot90/      評価: 同上を 90 度回転 (縦持ち相当)
├── eval_hard/               評価: 楽譜の難例 (重なり・折れ・はみ出し、主指標は IoU)
│                            ※ corners はフレームからはみ出た難例で 0..1 を超え得る
├── eval_web/                評価: Web 収集の OOD キャナリー (出典は SOURCES.md)
│                            ← アプリ分布への過適合を検知する番人
└── quarantine_heldout_dup/  使わない: eval_heldout と重複していた実写 (学習禁止)
                             (check_dataset.py の漏れチェックで隔離された分。経緯は中の README)
```

**鉄則**: `eval_*` に入れた画像・ラベルは二度と学習に使わない (train_paper_net_v2.py
の背景素材にも含めない)。`check_dataset.py` がバイト列の重複 (漏れ) を検出する。

## 改善サイクル

```
① アプリで使う        カメラ → 切り抜き画面で四隅を直す → 「検出改善用に保存」を ON
② 取り込み    ./dev.ps1 pull                     → training_data/eval
③ 昇格        ./dev.ps1 promote [--IncludeUnedited]
              edited=true (四隅を手で直した) のみ昇格。昇格すると eval/ からは移動
④ 学習        ./dev.ps1 train                    → 保存合成の奇数 id (--synth-ratio 0.4) と
                                                   train_real (--real-ratio) を自動混合。
                                                   内訳は build/<モデル名>.data.json
⑤ 評価        ./dev.ps1 eval -Model build/paper_seg_v2.onnx -Data training_data/eval_heldout
               (eval_heldout_rot90 / eval_hard / eval_web も。現行モデルと必ず比較)
               合成の条件別内訳: tools/eval_synthetic.py -M assets/models/paper_seg.onnx
⑥ 実機診断    ./dev.ps1 install → ./dev.ps1 selftest (切り抜き経路とライブ検出経路)
⑦ 採用        Copy-Item build/paper_seg_v2.onnx assets/models/paper_seg.onnx → install
```

- ③ の `--IncludeUnedited` は「モデル予測のままで OK だった」場面の学習にも使えるが、
  誤ったラベルを注入するリスクがある。まずは修正済みのみで回すのが安全。
- ⑤ で eval_web (OOD キャナリー) が大きく崩れたら、アプリ分布に過適合している兆候。
  eval_web は学習に使えないので、汎化を上げたい場合は合成条件 (p_multi / p_occluder /
  p_panel / p_clipped / p_stack) や実写キャプチャの追加で対応する。

## 各評価セットの見方

| セット | 主指標 | 基準の目安 |
|---|---|---|
| eval_heldout / _rot90 | 角誤差中央値・成功@5% | 現行 v4: 実写角誤差中央値 0.76% (辺直線当てはめ後) |
| eval_hard | 平均 IoU | v2 0.875 → v4 0.936 (成功@5% 62% → 100%) |
| eval_web | 検出率・誤検出率 | 現行 v4: 紙ありクリーン成功 0/5・ネガティブ 3/3 拒否 (既知の OOD 限界) |

eval_web の正解ラベルは画像解析モデルによる目視推定 (±2〜3%)。細かい数値の
トレンドより「全滅 ↔ 数枚救える」の大きな変化を見るために使う。

## データ追加のガイドライン

- **アプリ実写** (最も価値が高い): 失敗場面を切り抜き画面で直して保存する。10 枚でも効く
- **Web 画像**: ライセンスを確認し eval_web/SOURCES.md に記録してから追加 (評価専用)
- **合成**: train_paper_net_v2.py の既定 `diverse` 条件で、背景・紙面・小物・撮影条件を
  毎回変えて生成する。条件と保存方法は [合成バリエーション](datasets/synthetic_variations.md) を参照
- 追加後は `./dev.ps1 check` で整合性と漏れを必ず確認

## これまでに check が見つけた問題

- 2026-10: eval_heldout の 10 枚が real_captures/ (学習側) とバイト一致 →
  quarantine_heldout_dup/ に隔離。現行の v2 学習 (REAL_BG 背景 6 枚) は使っていなかった
  ため挙動は不変。legacy finetune_real.py を使う場合は eval_heldout を作り直すこと
