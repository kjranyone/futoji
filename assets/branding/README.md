# Futoji ロゴ

開いた本と音符を合わせたマーク。アプリのテーマカラー（藍色 #3B4A9F）を基調にしています。

| ファイル | 用途 | 仕様 |
| --- | --- | --- |
| futoji-master.png | 生成元画像 | オリジナル解像度 |
| app-store-1024.png | App Store / iOS | 1024×1024、RGB PNG、アルファチャンネルなし |
| google-play-512.png | Google Play | 512×512、32-bit RGBA PNG、全画素不透明、1,024 KB以下 |

外周の角丸・ドロップシャドウは画像に焼き込まず、ストア側の処理に任せています。
Android の各密度のランチャー画像と iOS の既存アセットカタログ各サイズにも書き出しています。既存の Flutter アイコン画像は残し、新規ファイルを参照します。

再出力（Windows PowerShell）: `./tools/export_app_icons.ps1`

## 公式仕様（2026-09-25確認）

- [Apple: Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Google Play: Icon design specifications](https://developer.android.com/distribute/google-play/resources/icon-design-specifications)

## 生成記録

内蔵 image_gen を使用。以下のプロンプトで生成後、System.Drawing でサイズ・PNGカラーモードを変換。

```text
Use case: logo-brand. Create a finished app icon for MusicBook, an app to scan and organize sheet music and music lesson notes into digital books. Square 1024x1024 PNG. Full-bleed solid deep indigo background matching #3B4A9F, all corners filled, no rounded outer corners. One bold, elegant ivory-white symbol integrating an open book with a musical eighth note, clear simple geometric silhouette readable at 32 pixels, centered with ample margin, symbol occupies approximately 60 percent of canvas width. Flat graphic design, crisp smooth edges, minimal detail, warm approachable music education character. No text, no letters, no border, no gradients, no shadows, no mockup, no extra objects, fully opaque background. Save the generated file and return its local file path.
```
