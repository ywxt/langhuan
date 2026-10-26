// Aggregated (all-feeds) search integration test.
//
// Runs the real Rust hub (via Native Assets) against an isolated app-data
// directory, two self-contained JavaScript feeds and local HTTP servers, so
// no real data or network is involved. One source fails mid-test to prove
// that a single feed's failure neither ends the merged stream nor sticks to
// later runs.
//
// On Android, `flutter test integration_test/...` UNINSTALLS the app (and
// with it all app data) when the run finishes. Always pass --no-uninstall
// when a device carries data you care about:
//
//     flutter test integration_test/aggregated_search_test.dart \
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

import 'fixture_feed.dart';

const _feedAId = 'fixture-a';
const _feedBId = 'fixture-b';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('aggregated search merges feeds and isolates failures', (
    tester,
  ) async {
    await RustLib.init();

    // ── Fixture sources ────────────────────────────────────────────────────
    // Source A always serves two results; source B serves one result unless
    // [feedBFails] flips it to a 500 with an empty body, which makes the
    // script's search parser error.
    var feedBFails = false;
    final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await serverA.close(force: true);
      await serverB.close(force: true);
    });
    serverA.listen((request) async {
      request.response.write('2');
      await request.response.close();
    });
    serverB.listen((request) async {
      if (feedBFails) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response.write('1');
      }
      await request.response.close();
    });

    // ── Fresh, isolated app data directory (own database) ─────────────────
    final tmp = await getTemporaryDirectory();
    final dataDir = Directory(
      '${tmp.path}/aggregated-search-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    await dataDir.create(recursive: true);
    final loadedFeeds = await AppService.instance.setAppDataDirectory(
      dataDir.path,
    );
    expect(loadedFeeds, 0, reason: 'a fresh data directory has no feeds');

    // ── Install both fixture feeds ─────────────────────────────────────────
    await installFixtureFeed(
      id: _feedAId,
      name: 'Fixture Source A',
      port: serverA.port,
      dataDir: dataDir,
    );
    await installFixtureFeed(
      id: _feedBId,
      name: 'Fixture Source B',
      port: serverB.port,
      dataDir: dataDir,
    );
    final feeds = await FeedService.instance.listFeeds();
    expect(feeds.map((feed) => feed.id), containsAll([_feedAId, _feedBId]));

    // ── Source B fails: A still delivers, B reports inline ────────────────
    feedBFails = true;
    final events = await FeedService.instance
        .searchAll(keyword: 'fixture')
        .toList();

    final aItems = events
        .where((event) => event.feedId == _feedAId && event.item != null)
        .toList();
    expect(aItems, hasLength(2));
    expect(aItems.first.feedName, 'Fixture Source A');
    expect(aItems.first.item!.title, 'Fixture Book 1');
    expect(aItems.last.item!.id, '1002');

    final bEvents = events.where((event) => event.feedId == _feedBId);
    expect(bEvents, hasLength(1));
    expect(bEvents.single.error, isNotNull);
    expect(bEvents.single.feedName, 'Fixture Source B');

    // Only the two installed sources contribute.
    expect(
      events.map((event) => event.feedId).toSet(),
      equals({_feedAId, _feedBId}),
    );

    // ── The failure is not sticky: B recovers on the next run ──────────────
    feedBFails = false;
    final recovered = await FeedService.instance
        .searchAll(keyword: 'fixture')
        .toList();
    expect(
      recovered.where((event) => event.error != null),
      isEmpty,
      reason: 'no source fails once B is healthy again',
    );
    expect(
      recovered.where(
        (event) => event.feedId == _feedBId && event.item != null,
      ),
      hasLength(1),
    );
    expect(
      recovered.where(
        (event) => event.feedId == _feedAId && event.item != null,
      ),
      hasLength(2),
    );

    // ── Single-source search still works alongside the aggregate ──────────
    final single = await FeedService.instance
        .search(feedId: _feedAId, keyword: 'fixture')
        .toList();
    expect(single, hasLength(2));
    expect(single.first.id, '1001');
  });
}
