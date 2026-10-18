import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/models/music_document.dart';

void main() {
  test('以前の仮の名前「無題の教材」は「無題のブック」として読む', () {
    expect(bookTitleFrom('無題の教材'), kUntitledBookTitle);
    expect(kUntitledBookTitle, '無題のブック');
  });

  test('名前が無ければ仮の名前、利用者が付けた名前はそのまま', () {
    expect(bookTitleFrom(null), kUntitledBookTitle);
    expect(bookTitleFrom('ソナチネ'), 'ソナチネ');
    expect(bookTitleFrom('教材プリント'), '教材プリント');
  });
}
