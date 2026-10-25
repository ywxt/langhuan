// Bookshelf update-check integration test.
//
// Runs the real Rust hub (via Native Assets) against an isolated app-data
// directory, a self-contained Lua feed script and a local HTTP server, so
// no real data or network is involved.
//
// On Android, `flutter test integration_test/...` UNINSTALLS the app (and
// with it all app data) when the run finishes. Always pass --no-uninstall
// when a device carries data you care about:
//
//     flutter test integration_test/update_check_test.dart \
//       -d emulator-5554 --no-uninstall
//
// (On NixOS the Android target additionally needs the read-only-SDK plugin
// mirror from flake.nix; see flutter-native-plugin-loader-nix.gradle.kts.)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:langhuan/features/feeds/feed_service.dart';
import 'package:langhuan/shared/app_service.dart';
import 'package:langhuan/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

const _feedId = 'fixture-test';
const _bookId = '1001';

/// Lua feed script backed by the test's local HTTP server. Any request is
/// answered with the current chapter count as the body; the script turns
/// that number into the chapter list, so the test controls "publications"
/// by changing what the server serves.
String _fixtureFeedScript(int port) => '''
-- ==Feed==
-- @id           fixture-test
-- @name         Fixture Test Source
-- @version      1.0.0
-- @author       integration-test
-- @description  Hermetic fixture feed backed by a local HTTP server
-- @base_url     http://127.0.0.1:$port
-- @access_domain 127.0.0.1
-- @schema_version 1
-- ==/Feed==

return {
    search = {
        request = function(keyword, cursor)
            return {
                url = meta.base_url .. "/search",
                method = "GET",
                headers = {},
            }
        end,
        parse = function(resp)
            return {
                items = {
                    {
                        id = "1001",
                        title = "Fixture Book",
                        author = "Fixture Author",
                        description = "Hermetic fixture book.",
                    },
                },
                next_cursor = nil,
            }
        end,
    },

    book_info = {
        request = function(id)
            return {
                url = meta.base_url .. "/book/" .. tostring(id),
                method = "GET",
                headers = {},
            }
        end,
        parse = function(resp)
            return {
                id = "1001",
                title = "Fixture Book",
                author = "Fixture Author",
                description = "Hermetic fixture book.",
            }
        end,
    },

    chapters = {
        request = function(book_id, cursor)
            return {
                url = meta.base_url .. "/chapters/" .. tostring(book_id),
                method = "GET",
                headers = {},
            }
        end,
        parse = function(resp)
            local count = tonumber(resp.body or "")
            if count == nil then
                error("fixture: invalid chapter count: " .. tostring(resp.body))
            end
            local items = {}
            for i = 1, count do
                table.insert(items, {
                    id = tostring(i),
                    title = "Chapter " .. tostring(i),
                })
            end
            return {
                items = items,
                next_cursor = nil,
            }
        end,
    },

    paragraphs = {
        request = function(book_id, chapter_id, cursor)
            return {
                url = meta.base_url .. "/paragraphs/" .. tostring(book_id)
                    .. "/" .. tostring(chapter_id),
                method = "GET",
                headers = {},
            }
        end,
        parse = function(resp)
            return {
                items = {
                    { type = "text", content = "Fixture paragraph." },
                },
                next_cursor = nil,
            }
        end,
    },
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('update check baselines, reports and clears new chapters', (
    tester,
  ) async {
    await RustLib.init();

    // ── Fixture source ────────────────────────────────────────────────────
    var chapterCount = 42;
    var failRequests = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((request) async {
      if (failRequests) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response.write('$chapterCount');
      }
      await request.response.close();
    });

    // ── Fresh, isolated app data directory (own database) ─────────────────
    final tmp = await getTemporaryDirectory();
    final dataDir = Directory(
      '${tmp.path}/update-check-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    await dataDir.create(recursive: true);
    final loadedFeeds = await AppService.instance.setAppDataDirectory(
      dataDir.path,
    );
    expect(loadedFeeds, 0, reason: 'a fresh data directory has no feeds');

    // ── Install the fixture feed ──────────────────────────────────────────
    final scriptFile = File('${dataDir.path}/fixture-feed.lua')
      ..writeAsStringSync(_fixtureFeedScript(server.port));
    final preview = await FeedService.instance.previewFromFile(
      scriptFile.path,
    );
    expect(preview.id, _feedId);
    await FeedService.instance.installFeed(preview.requestId);
    final feeds = await FeedService.instance.listFeeds();
    expect(feeds.map((feed) => feed.id), contains(_feedId));

    // ── Search and shelve the fixture book ────────────────────────────────
    final results = await FeedService.instance
        .search(feedId: _feedId, keyword: 'fixture')
        .toList();
    expect(results, hasLength(1));
    expect(results.first.id, _bookId);
    expect(results.first.title, 'Fixture Book');

    final outcome = await FeedService.instance.addToBookshelf(
      feedId: _feedId,
      sourceBookId: results.first.id,
      title: results.first.title,
      author: results.first.author,
    );
    expect(outcome, isA<BookshelfOperationOutcomeAdded>());

    // ── First check: a never-seen book adopts the fresh count silently ────
    var updates = await FeedService.instance.bookshelfUpdates().toList();
    expect(updates, hasLength(1));
    expect(updates.first.feedId, _feedId);
    expect(updates.first.sourceBookId, _bookId);
    expect(updates.first.newChapters, 0);
    expect(updates.first.error, isNull);

    // ── The source publishes three new chapters ───────────────────────────
    chapterCount = 45;
    updates = await FeedService.instance.bookshelfUpdates().toList();
    expect(updates.first.newChapters, 3);
    expect(updates.first.error, isNull);

    // ── Marking the book seen clears the badge ────────────────────────────
    await FeedService.instance.markBookshelfSeen(
      feedId: _feedId,
      sourceBookId: _bookId,
      chapterCount: 45,
    );
    updates = await FeedService.instance.bookshelfUpdates().toList();
    expect(updates.first.newChapters, 0);
    expect(updates.first.error, isNull);

    // ── A dead source fails that book's check without a badge ─────────────
    failRequests = true;
    updates = await FeedService.instance.bookshelfUpdates().toList();
    expect(updates.first.newChapters, 0);
    expect(updates.first.error, isNotNull);
  });
}
