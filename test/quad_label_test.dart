import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/services/quad_label.dart';
import 'package:mymusicbook/services/training_capture.dart';

const square = <Offset>[
  Offset(0.25, 0.25),
  Offset(0.75, 0.25),
  Offset(0.75, 0.75),
  Offset(0.25, 0.75),
];

void main() {
  group('QuadLabel', () {
    test('JSON 往復で値が保たれる', () {
      final label = QuadLabel(
        image: 'a.jpg',
        width: 750,
        height: 1000,
        corners: square,
        predicted: null,
        edited: true,
        createdAt: DateTime(2026, 9, 28, 3),
      );
      final back = QuadLabel.fromJson(label.toJson());
      expect(back.image, 'a.jpg');
      expect(back.width, 750);
      expect(back.height, 1000);
      expect(back.corners, square);
      expect(back.predicted, isNull);
      expect(back.edited, isTrue);
      expect(back.createdAt, DateTime(2026, 9, 28, 3));
    });

    test('corners=null は紙なしラベルとして往復できる', () {
      const label = QuadLabel(image: 'n.jpg', width: 4, height: 3, corners: null);
      final back = QuadLabel.fromJson(label.toJson());
      expect(back.corners, isNull);
      expect(back.isNegative, isTrue);
    });

    test('corners が 4 点でなければ FormatException', () {
      expect(
        () => QuadLabel.fromJson(<String, Object?>{
          'image': 'a.jpg',
          'width': 10,
          'height': 10,
          'corners': <Object>[
            <double>[0, 0],
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('QuadMetrics', () {
    test('同一なら誤差 0 / IoU 1', () {
      final e = QuadMetrics.cornerError(square, square, 800, 600);
      expect(e.mean, 0);
      expect(e.max, 0);
      expect(QuadMetrics.quadIoU(square, square, 800, 600), closeTo(1, 1e-9));
    });

    test('角の起点がずれていても誤差 0', () {
      final shifted = <Offset>[square[1], square[2], square[3], square[0]];
      expect(QuadMetrics.cornerError(shifted, square, 800, 600).mean, 0);
    });

    test('1 角だけ動かすと最大誤差はその移動量 / 対角線', () {
      final moved = List<Offset>.of(square)..[0] = const Offset(0.25, 0.35);
      // 600px × 0.1 = 60px、対角線 1000px → 6%
      final e = QuadMetrics.cornerError(moved, square, 800, 600);
      expect(e.max, closeTo(0.06, 1e-9));
      expect(e.mean, closeTo(0.015, 1e-9));
    });

    test('半分重なる矩形の IoU は 1/3', () {
      const right = <Offset>[
        Offset(0.5, 0.25),
        Offset(1.0, 0.25),
        Offset(1.0, 0.75),
        Offset(0.5, 0.75),
      ];
      expect(QuadMetrics.quadIoU(square, right, 512, 512), closeTo(1 / 3, 0.01));
    });
  });

  group('TrainingCapture.isEdited', () {
    test('予測なしは手修正扱い', () {
      expect(TrainingCapture.isEdited(null, square), isTrue);
    });

    test('予測のまま確定なら手修正なし', () {
      expect(TrainingCapture.isEdited(square, List<Offset>.of(square)), isFalse);
    });

    test('1 角でも動かせば手修正あり', () {
      final moved = List<Offset>.of(square)..[2] = const Offset(0.8, 0.8);
      expect(TrainingCapture.isEdited(square, moved), isTrue);
    });
  });
}
