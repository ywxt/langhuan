import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/shared/widgets/chapter_scrollbar.dart';

void main() {
  testWidgets('a visible directory thumb supports a finger drag', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ChapterScrollbar(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  itemExtent: 72,
                  itemCount: 1000,
                  itemBuilder: (_, i) => ListTile(title: Text('Chapter $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    final before = controller.offset;
    final rect = tester.getRect(find.byType(ChapterScrollbar));
    // The thumb is still near the top of this 1,000-chapter directory.
    final finger = await tester.startGesture(
      rect.topRight + const Offset(-10, 40),
    );
    await tester.pump();
    await finger.moveBy(const Offset(0, 180));
    await tester.pump();
    expect(controller.offset, greaterThan(before + 1000));
    await finger.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
