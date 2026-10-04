// ビューアのページめくり: 20% 以上ドラッグして離せばめくる (標準は半分以上必要)。
import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/widgets/snappy_page_physics.dart';

void main() {
  const p = SnappyPageScrollPhysics();
  const w = 1000.0; // 1 ページの幅

  test('次のページへ 25% 引いて離すと次へ、15% なら戻る', () {
    expect(p.targetPixels(250, w, 100), 1000);
    expect(p.targetPixels(150, w, 100), 0);
  });

  test('前のページへ 25% 引いて離すと前へ、15% なら戻る', () {
    // 2 ページ目 (1000px) から左へ戻す方向
    expect(p.targetPixels(750, w, -100), 0);
    expect(p.targetPixels(850, w, -100), 1000);
  });

  test('止めて離したら近いページに揃える', () {
    expect(p.targetPixels(400, w, 0), 0);
    expect(p.targetPixels(600, w, 0), 1000);
  });
}
