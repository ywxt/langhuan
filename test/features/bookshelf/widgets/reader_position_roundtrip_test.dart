import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/bookshelf/widgets/reader_core.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/src/rust/api/types.dart';

List<ParagraphContent> _paragraphs(String chapterId) {
  return [
    ParagraphContent_Text(
      id: ParagraphId.id('${chapterId}_p1'),
      content: 'paragraph one',
    ),
    ParagraphContent_Text(
      id: ParagraphId.id('${chapterId}_p2'),
      content: 'paragraph two',
    ),
  ];
}

void main() {
  test(
    'canonical position round-trips across repeated mode switch simulation',
    () async {
      final core = ReaderCore(
        loader: (chapterId) async => _paragraphs(chapterId),
        normalizeError: (e) => e.toString(),
      );

      final chapters = const [
        ChapterInfoModel(id: 'c1', title: 'C1'),
        ChapterInfoModel(id: 'c2', title: 'C2'),
      ];

      core.setSource(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        initialChapterId: 'c1',
        initialParagraphId: 'c1_p2',
        initialParagraphOffset: 120,
      );
      await core.initCenter();

      expect(core.pendingJumpParagraphId, 'c1_p2');
      expect(core.pendingJumpParagraphOffset, 120);

      // Simulate first mode switch by consuming and setting a new canonical anchor.
      core.consumePendingJump();
      core.setPendingJumpPosition(paragraphId: 'c1_p1', paragraphOffset: 40);
      expect(core.pendingJumpParagraphId, 'c1_p1');
      expect(core.pendingJumpParagraphOffset, 40);

      // Simulate second mode switch and reopen restore command.
      core.setSource(
        feedId: 'f1',
        bookId: 'b1',
        chapters: chapters,
        initialChapterId: 'c1',
        initialParagraphId: core.pendingJumpParagraphId,
        initialParagraphOffset: core.pendingJumpParagraphOffset,
        clearCache: false,
      );
      await core.initCenter();

      expect(core.centerChapterId, 'c1');
      expect(core.pendingJumpParagraphId, 'c1_p1');
      expect(core.pendingJumpParagraphOffset, 40);
    },
  );
}
