import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'db_service.dart';

/// GitHub Releases の最新版。
class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.pageUrl});

  /// タグ名 (例 v1.0.1)。
  final String tag;

  /// リリースのページ (APK はここからダウンロードする)。
  final String pageUrl;

  /// 表示用のバージョン (先頭の v を外したもの)。
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

/// 更新の確認 (GitHub Releases で配る APK だけの機能)。
///
/// CI が `--dart-define=FUTOJI_DIST=github` を付けてビルドした APK だけが持つ。
/// ストア版は Play 以外から自分を更新する仕組みを持てないうえ、通信もしない
/// (docs/PRIVACY_POLICY.md) ので、この機能ごと無効にする。通信権限も
/// GitHub 配布のリリースビルドにだけ付く (android/app/build.gradle.kts)。
class UpdateChecker {
  static const bool _githubDist = String.fromEnvironment('FUTOJI_DIST') == 'github';

  /// この端末・ビルドで更新確認を使えるか。
  static bool get available => _githubDist && Platform.isAndroid;

  static const String _latestApi =
      'https://api.github.com/repos/kjranyone/futoji/releases/latest';
  static const String _lastAutoCheckKey = 'update_last_auto_check';

  /// 起動時の自動確認の間隔。
  static const Duration autoInterval = Duration(days: 1);

  /// 最新のリリースを取得する。通信や応答の異常は例外。
  static Future<ReleaseInfo> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(_latestApi));
      // GitHub API は User-Agent が無いと拒否する
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'futoji-update-check')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub から応答がありません (${res.statusCode})');
      }
      final json = jsonDecode(body) as Map<String, Object?>;
      final tag = json['tag_name'] as String?;
      final url = json['html_url'] as String?;
      if (tag == null || url == null) {
        throw const FormatException('リリース情報を読めませんでした');
      }
      return ReleaseInfo(tag: tag, pageUrl: url);
    } finally {
      client.close(force: true);
    }
  }

  /// 最新版を確認し、いまのバージョンより新しければそれを、最新なら null を返す。
  static Future<ReleaseInfo?> check() async {
    final latest = await fetchLatest();
    final current = (await PackageInfo.fromPlatform()).version;
    return isNewerVersion(latest.version, current) ? latest : null;
  }

  /// 起動時の自動確認。前回から [autoInterval] 経っていなければ確認しない。
  /// 失敗は黙って無視する (オフラインでも普段の利用を邪魔しない)。
  static Future<ReleaseInfo?> autoCheck({DateTime? now}) async {
    if (!available) return null;
    final t = now ?? DateTime.now();
    final last = DbService.settings.get(_lastAutoCheckKey) as int?;
    if (last != null &&
        t.difference(DateTime.fromMillisecondsSinceEpoch(last)) < autoInterval) {
      return null;
    }
    await DbService.settings.put(_lastAutoCheckKey, t.millisecondsSinceEpoch);
    try {
      return await check();
    } catch (_) {
      return null;
    }
  }
}

/// [latest] が [current] より新しいか ("1.0.10" > "1.0.9")。
/// 数字以外の部分 (例 "-beta"、"+3001") は無視して数字の並びで比べる。
bool isNewerVersion(String latest, String current) {
  List<int> parse(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[-+]')).first;
    return <int>[for (final p in core.split('.')) int.tryParse(p) ?? 0];
  }

  final a = parse(latest), b = parse(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
