import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

void main() {
  Future<void> pumpSlider(
    WidgetTester tester,
    List<double> calls, {
    double value = 1,
    bool reversed = false,
    double max = 11,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              height: 48,
              child: CustomSlider(
                focusNode: null,
                min: 1,
                max: max,
                value: value,
                reversed: reversed,
                divisions: (max - 1).toInt().clamp(1, 100),
                onChanged: calls.add,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Rect track(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(CustomSlider),
      matching: find.byType(GestureDetector),
    ),
  );

  Offset point(WidgetTester tester, double fraction) {
    final rect = track(tester);
    return Offset(rect.left + rect.width * fraction, rect.center.dy);
  }

  double thumbX(WidgetTester tester) => tester
      .getCenter(
        find.descendant(
          of: find.byType(CustomSlider),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container && widget.constraints?.maxWidth == 22,
          ),
        ),
      )
      .dx;

  testWidgets('horizontal drag previews locally and commits once on release', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    final gesture = await tester.startGesture(point(tester, 0.1));
    for (final fraction in [0.3, 0.5, 0.7]) {
      await gesture.moveTo(point(tester, fraction));
      await tester.pump();
      expect(calls, isEmpty, reason: 'drag ticks must not jump pages');
    }
    expect(thumbX(tester), closeTo(point(tester, 0.7).dx, 0.1));
    await gesture.up();
    await tester.pump();
    expect(calls, [8.0]);
  });

  testWidgets('holding the track before dragging does not jump early', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    final gesture = await tester.startGesture(point(tester, 0.2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, isEmpty);
    await gesture.moveTo(point(tester, 0.6));
    await tester.pump();
    expect(calls, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(calls, [7.0]);
  });

  testWidgets('tapping the track commits exactly once', (tester) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    await tester.tapAt(point(tester, 0.5));
    await tester.pump();
    expect(calls, [6.0]);
    expect(thumbX(tester), closeTo(point(tester, 0.5).dx, 0.1));
  });

  testWidgets('cancelled drag restores the committed value without jumping', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls, value: 3);
    final gesture = await tester.startGesture(point(tester, 0.2));
    await gesture.moveTo(point(tester, 0.7));
    await tester.pump();
    expect(thumbX(tester), closeTo(point(tester, 0.7).dx, 0.1));
    await gesture.cancel();
    await tester.pump();
    expect(calls, isEmpty);
    expect(thumbX(tester), closeTo(point(tester, 0.2).dx, 0.1));
  });

  testWidgets('reverse reading maps drag positions to the correct page', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls, reversed: true);
    final gesture = await tester.startGesture(point(tester, 0.8));
    await gesture.moveTo(point(tester, 0.3));
    await tester.pump();
    expect(calls, isEmpty);
    expect(thumbX(tester), closeTo(point(tester, 0.3).dx, 0.1));
    await gesture.up();
    await tester.pump();
    expect(calls, [8.0]);
  });

  testWidgets('dragging beyond track bounds clamps to first and last pages', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    for (final fraction in [-0.2, 1.2]) {
      final gesture = await tester.startGesture(point(tester, 0.5));
      await gesture.moveTo(point(tester, fraction));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }
    expect(calls, [1.0, 11.0]);
  });

  testWidgets('external page and chapter range changes update the thumb', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    await pumpSlider(tester, calls, value: 11);
    expect(thumbX(tester), closeTo(point(tester, 1).dx, 0.1));
    await pumpSlider(tester, calls, value: 11, max: 21);
    expect(thumbX(tester), closeTo(point(tester, 0.5).dx, 0.1));
    expect(calls, isEmpty);
  });

  testWidgets('reader updates during a drag do not overwrite the chosen page', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    final gesture = await tester.startGesture(point(tester, 0.1));
    await gesture.moveTo(point(tester, 0.7));
    await tester.pump();
    await pumpSlider(tester, calls, value: 2);
    expect(thumbX(tester), closeTo(point(tester, 0.7).dx, 0.1));
    await gesture.up();
    await tester.pump();
    expect(calls, [8.0]);
  });

  testWidgets('changing chapters cancels a pending slider selection', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    final gesture = await tester.startGesture(point(tester, 0.1));
    await gesture.moveTo(point(tester, 0.7));
    await tester.pump();
    await pumpSlider(tester, calls, value: 1, max: 21);
    await gesture.up();
    await tester.pump();
    expect(calls, isEmpty);
    expect(thumbX(tester), closeTo(point(tester, 0).dx, 0.1));
  });

  testWidgets('a single-page chapter has no active slider', (tester) async {
    final calls = <double>[];
    await pumpSlider(tester, calls, max: 1);
    await tester.tapAt(tester.getCenter(find.byType(CustomSlider)));
    await tester.pump();
    expect(calls, isEmpty);
  });
}
