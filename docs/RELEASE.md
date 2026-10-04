# リリース手順

## Android

### 署名鍵 (アップロード鍵)

- 鍵ストア: `%USERPROFILE%\.keystores\mymusicbook-upload.jks` (PKCS12, alias `upload`, RSA 2048, 有効期限 10000 日)
- 設定: `android/key.properties` (git 管理外。パスワードはここにだけある)

  ```properties
  storePassword=...
  keyPassword=...
  keyAlias=upload
  storeFile=C:/Users/<you>/.keystores/mymusicbook-upload.jks
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
- [ ] プライバシーポリシー ([PRIVACY_POLICY.md](PRIVACY_POLICY.md)) を公開 URL に置き、Play Console に登録

### Play Console のデータ安全性 (回答の根拠)

- データの収集: **なし** (通信を行わず、開発者のサーバーもない。AndroidManifest に INTERNET 権限なし)
- データの共有: **なし** (PDF 共有は利用者の操作で OS の共有シートに渡すだけ)
- 端末内に保存するデータ: 撮影画像・教材メタデータ・手書きメモ (アプリ専用領域)
- 権限: CAMERA (紙資料の撮影のみ)

## iOS

紙面検出の ONNX Runtime は CocoaPods の `onnxruntime-c` (1.20.0, Android 側と同じ版) を
静的リンクし、`AppDelegate.swift` が `OrtGetApiBase()` のアドレスを MethodChannel
(`mymusicbook/ort`) で Dart に渡す (`lib/services/ort_ffi.dart` の `preparePlatform`)。
ORT が使えない場合は従来のヒューリスティック検出に自動で切り替わる。

**未検証 (2026-10-04 時点)**: 実装は Windows 上で行い、iOS のビルド・実機確認はしていない。
macOS で次を確認すること。

- [ ] `flutter pub get && cd ios && pod install` が通る (Podfile は `ios/Podfile`)
- [ ] `flutter build ios --release` が通る (ブリッジングヘッダの `onnxruntime_c_api.h` が見つかる)
- [ ] 実機で起動ログに `PaperNet: model unavailable` が出ず、紙面の自動検出が動く
- [ ] カメラ権限の説明文 (`Info.plist` の `NSCameraUsageDescription`) が表示される
