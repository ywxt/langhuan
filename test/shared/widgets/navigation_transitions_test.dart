import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/shared/theme/fade_slide_page_transitions_builder.dart';
import 'package:langhuan/shared/widgets/animated_branch_container.dart';

void main() {
  test('fade-slide builder declares visible route durations', () {
    const builder = FadeSlidePageTransitionsBuilder();

    expect(builder.transitionDuration, const Duration(milliseconds: 300));
    expect(
      builder.reverseTransitionDuration,
      const Duration(milliseconds: 240),
    );
  });

  testWidgets('branch switch cross-fades instead of changing instantly', (
    tester,
  ) async {
    Widget host(int currentIndex) {
      return MaterialApp(
        home: AnimatedBranchContainer(
          currentIndex: currentIndex,
          children: const [
            ColoredBox(key: ValueKey('first-branch'), color: Colors.red),
            ColoredBox(key: ValueKey('second-branch'), color: Colors.blue),
          ],
        ),
      );
    }

    double opacityOf(Key key) {
      final opacity = find.descendant(
        of: find.ancestor(
          of: find.byKey(key),
          matching: find.byType(AnimatedOpacity),
        ),
        matching: find.byType(FadeTransition),
      );
      return tester.widget<FadeTransition>(opacity).opacity.value;
    }

    await tester.pumpWidget(host(0));
    expect(opacityOf(const ValueKey('first-branch')), 1);
    expect(opacityOf(const ValueKey('second-branch')), 0);

    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 120));

    expect(opacityOf(const ValueKey('first-branch')), inExclusiveRange(0, 1));
    expect(opacityOf(const ValueKey('second-branch')), inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(opacityOf(const ValueKey('first-branch')), 0);
    expect(opacityOf(const ValueKey('second-branch')), 1);
  });
}
