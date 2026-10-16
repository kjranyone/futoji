import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/services/update_checker.dart';

void main() {
  group('isNewerVersion', () {
    test('数字の並びで比べる (文字列比較ではない)', () {
      expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.99'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('同じか古ければ false', () {
      expect(isNewerVersion('1.0.1', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
    });

    test('タグの v やビルド番号は無視する', () {
      expect(isNewerVersion('v1.0.2', '1.0.1'), isTrue);
      expect(isNewerVersion('v1.0.1', '1.0.1+3001'), isFalse);
    });

    test('桁数が違っても足りない桁は 0 とみなす', () {
      expect(isNewerVersion('1.1', '1.0.5'), isTrue);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });
  });

  test('ReleaseInfo.version は先頭の v を外す', () {
    expect(const ReleaseInfo(tag: 'v1.2.3', pageUrl: '').version, '1.2.3');
    expect(const ReleaseInfo(tag: '1.2.3', pageUrl: '').version, '1.2.3');
  });

  test('ストア版 (FUTOJI_DIST なし) では使えない', () {
    expect(UpdateChecker.available, isFalse);
  });
}
