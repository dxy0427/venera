import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

/// The reader page slider must not emit a page jump on every drag tick.
/// It commits exactly once, when the drag ends (or immediately on tap).
void main() {
  Future<void> pumpSlider(
    WidgetTester tester,
    List<double> calls, {
    double value = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomSlider(
            focusNode: FocusNode(),
            min: 1,
            max: 11,
            value: value,
            divisions: 10,
            onChanged: calls.add,
          ),
        ),
      ),
    );
  }

  testWidgets('dragging emits no jumps and commits once at drag end', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    // Slider track: padded 24px each side => track width 752, gap 75.2.
    // Start at track x = 80 (global x = 104).
    final gesture = await tester.startGesture(const Offset(104, 12));
    for (var i = 0; i < 20; i++) {
      // Mostly-vertical movement so the vertical drag recognizer wins.
      await gesture.moveBy(const Offset(4, 24));
      await tester.pump();
    }
    expect(calls, isEmpty, reason: 'drag ticks must not jump pages');
    await gesture.up();
    await tester.pump();
    // Final track x = 80 + 80 = 160 => round(160 / 75.2) = 2 => 1 + 2.
    expect(calls, [3.0]);
  });

  testWidgets('tapping the track jumps immediately', (tester) async {
    final calls = <double>[];
    await pumpSlider(tester, calls);
    // Track x = 376 (global x = 400) => round(376 / 75.2) = 5 => 1 + 5.
    await tester.tapAt(const Offset(400, 12));
    await tester.pump();
    expect(calls, [6.0]);
  });

  testWidgets('value callback updates thumb from the outside', (
    tester,
  ) async {
    final calls = <double>[];
    await pumpSlider(tester, calls, value: 1);
    await pumpSlider(tester, calls, value: 11);
    // Slider still renders with the new external value (max position).
    expect(find.byType(CustomSlider), findsOneWidget);
    await tester.tapAt(const Offset(400, 12));
    await tester.pump();
    expect(calls, [6.0]);
  });
}
