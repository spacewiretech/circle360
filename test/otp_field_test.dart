import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/widgets/otp_field.dart';

/// `tester.enterText` replaces the whole value in one go, exactly the way a paste or an iOS
/// one-time-code autofill does — which is the path that used to be truncated to one character.
void main() {
  const length = 6;

  late String changed;
  late List<String> completions;
  late OtpFieldController controller;

  Future<void> pump(WidgetTester tester) async {
    changed = '';
    completions = [];
    controller = OtpFieldController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: OtpField(
              length: length,
              controller: controller,
              onChanged: (value) => changed = value,
              onCompleted: completions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The digit each box is currently painting, '' for an empty one.
  List<String> boxes(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .toList();

  testWidgets('a full paste fills every box and completes once', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();

    expect(changed, '123456');
    expect(boxes(tester), ['1', '2', '3', '4', '5', '6']);
    expect(completions, ['123456']);
  });

  testWidgets('a pasted code with letters and spaces is filtered to digits',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'OTP 12 34-56');
    await tester.pump();

    expect(changed, '123456');
    expect(boxes(tester), ['1', '2', '3', '4', '5', '6']);
  });

  testWidgets('a longer paste is truncated to the field length', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '1234567890');
    await tester.pump();

    expect(changed, '123456');
    expect(boxes(tester), ['1', '2', '3', '4', '5', '6']);
  });

  testWidgets('a short paste fills the leading boxes and does not complete',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '123');
    await tester.pump();

    expect(changed, '123');
    expect(boxes(tester), ['1', '2', '3', '', '', '']);
    expect(completions, isEmpty);
  });

  testWidgets('typing digit by digit still advances and completes', (tester) async {
    await pump(tester);

    for (final code in ['1', '12', '123', '1234', '12345', '123456']) {
      await tester.enterText(find.byType(TextField), code);
      await tester.pump();
    }

    expect(boxes(tester), ['1', '2', '3', '4', '5', '6']);
    expect(completions, ['123456']);
  });

  testWidgets('backspacing back through the code empties the boxes', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();

    expect(changed, '12345');
    expect(boxes(tester), ['1', '2', '3', '4', '5', '']);

    // Refilling fires completion again, so a corrected code still auto-submits.
    await tester.enterText(find.byType(TextField), '123459');
    await tester.pump();
    expect(completions, ['123456', '123459']);
  });

  testWidgets('clear() empties every box and reports the empty code', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();

    controller.clear();
    await tester.pump();

    expect(changed, '');
    expect(boxes(tester), ['', '', '', '', '', '']);
  });

  testWidgets('the field advertises itself for one-time-code autofill', (tester) async {
    await pump(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
    // The hint only takes effect inside a group.
    expect(find.byType(AutofillGroup), findsOneWidget);
    // Long-press Paste depends on interactive selection staying on.
    expect(field.enableInteractiveSelection, isTrue);
  });
}
