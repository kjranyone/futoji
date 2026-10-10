# リリース手順

## Android

### 署名鍵 (アップロード鍵)

- 鍵ストア: `%USERPROFILE%\.keystores\futoji-upload.jks` (PKCS12, alias `upload`, RSA 2048, 有効期限 10000 日)
- 設定: `android/key.properties` (git 管理外。パスワードはここにだけある)

  ```properties
  storePassword=...
  keyPassword=...
  keyAlias=upload
  storeFile=C:/Users/<you>/.keystores/futoji-upload.jks
  ```

- **鍵ストアと key.properties は必ず別の場所にもバックアップする** (パスワード管理ツールなど)。
  Play App Signing を使えば、アップロード鍵をなくしても Play Console から再設定できるが、
  手続きに時間がかかる。
- key.properties が無いと release のビルドは `GradleException` で止まる (debug 署名での出荷防止)。
  debug ビルドには影響しない。
- 署名が変わったので、以前 debug 署名で入れた端末には上書きインストールできない。
  一度アンインストールしてから `./dev.ps1 install` する (端末内のデータは消える)。

### ビルド

```powershell
# バージョン: pubspec.yaml の version (例 1.0.0+3000)。ビルド番号 (+ の後) は毎回増やす
flutter build appbundle --release --target-platform android-arm64   # Play 提出用 .aab
./dev.ps1 install                                                    # 実機確認用 (release APK)
```

### 提出前チェック

- [ ] `./dev.ps1 analyze` と `./dev.ps1 test` が通る
- [ ] 実機で 撮影 → 切り抜き → 保存 → 閲覧 → 手書き → PDF 共有 を一通り確認
- [ ] 設定画面の「開発者向け」がすべてオフの状態で通常利用に問題がない
- [ ] 設定 → オープンソースライセンス が開ける
- [ ] 設定 → バックアップを書き出す → 保存先を選んで保存 (Download / Google ドライブ) → アンインストール →
      再インストール → バックアップから復元 で教材・手書き・タグが戻る
      (2026-10-04 HiPad で Download 経由を確認済み。Drive アプリの無い端末だったため Drive は未確認)
- [ ] プライバシーポリシー ([PRIVACY_POLICY.md](PRIVACY_POLICY.md)) を公開 URL に置き、Play Console に登録

### ストア掲載画像

`docs/store/` に提出用の画像がある (JPEG 品質 95。README には幅 540 の WebP を載せている)。

| フォルダ | サイズ | 用途 |
|---|---|---|
| `phone/01..07` | 1080×1920 | Google Play スマホ用スクリーンショット (9:16、2〜8 枚) |
| `tablet/01..05` | 1620×2880 | Google Play 10 インチタブレット用 |
| `iphone/01..07` | 1290×2796 | App Store 6.7 インチ (git 管理外。下の手順で再生成) |
| `ipad/01..05` | 2048×2732 | App Store 12.9 インチ (同上) |
| `feature_graphic.png` | 1024×500 | Google Play の宣伝用画像 (必須) |

楽譜の写真は `training_data/paper_photos/images/` の生成画像 (imagegen で作ったもので、
権利関係の心配がない) を使っている。実写の教師データ (train_real / eval_*) には市販の楽譜が
写っているので、ストア画像には使わない。

作り直す手順 (実機は HiPad 1600×2560 / 320dpi):

```powershell
python tools/make_store_samples.py      # 生成写真を台形補正してサンプル教材の zip を作る (build/store_samples)
adb push build/store_samples/futoji_backup_promo.zip /sdcard/Download/
# アプリ: 設定 → バックアップから復元 → ファイルを選ぶ → Download の zip
#   (一覧に出ないときは picker の検索で "futoji")。既存の教材はそのまま残る
# タブレットの画面を撮る: home / doc / viewer / draw / camera (自動 ON) / crop
adb exec-out screencap -p > shots/home_promo2.png   # ファイル名は tools/make_store_images.py の SHOTS
# スマホ向けは表示サイズを変えて撮る (アプリが 2 列レイアウトになる)
adb shell wm size 1080x2340; adb shell wm density 440
adb exec-out screencap -p > shots/p_home.png        # ... p_ で始まる各画面
adb shell wm size reset; adb shell wm density reset
python tools/make_store_images.py --shots shots --pages build/store_samples/pages
```

- カメラ・切り抜き画面は、実機のカメラの前に楽譜を置けないので、UI だけ実機のキャプチャを使い、
  プレビュー部分を生成写真に差し替えてアプリと同じ描き方で検出枠を描いている
  (`camera_composite` / `crop_composite`)。合成結果は `build/store_screens/` で確認できる
- 撮り終えたら端末のサンプル教材 (promo_*) を消す (ホームで長押し → 削除)

### Play Console のデータ安全性 (回答の根拠)

- データの収集: **なし** (通信を行わず、開発者のサーバーもない。AndroidManifest に INTERNET 権限なし)
- データの共有: **なし** (PDF・バックアップ zip は利用者の操作で OS の共有シートに渡すだけ)
- 端末内に保存するデータ: 撮影画像・教材メタデータ・手書きメモ (アプリ専用領域)
- 権限: CAMERA (紙資料の撮影のみ)

## iOS

紙面検出の ONNX Runtime は CocoaPods の `onnxruntime-c` (1.20.0, Android 側と同じ版) を
静的リンクし、`AppDelegate.swift` が `OrtGetApiBase()` のアドレスを MethodChannel
(`futoji/ort`) で Dart に渡す (`lib/services/ort_ffi.dart` の `preparePlatform`)。
ORT が使えない場合は従来のヒューリスティック検出に自動で切り替わる。

**未検証 (2026-10-04 時点)**: 実装は Windows 上で行い、iOS のビルド・実機確認はしていない。
macOS で次を確認すること。

- [ ] `flutter pub get && cd ios && pod install` が通る (Podfile は `ios/Podfile`)
- [ ] `flutter build ios --release` が通る (ブリッジングヘッダの `onnxruntime_c_api.h` が見つかる)
- [ ] 実機で起動ログに `PaperNet: model unavailable` が出ず、紙面の自動検出が動く
- [ ] カメラ権限の説明文 (`Info.plist` の `NSCameraUsageDescription`) が表示される
