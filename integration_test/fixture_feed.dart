// Shared hermetic JavaScript feed fixture for integration tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/feed_service.dart';

String fixtureFeedScript({
  required String id,
  required String name,
  required int port,
}) =>
    '''
// ==Feed==
// @id           $id
// @name         $name
// @version      3.0.0
// @author       integration-test
// @description  Hermetic fixture feed backed by a local HTTP server
// @base_url     http://127.0.0.1:$port
// @access_domain 127.0.0.1
// @schema_version 3
// ==/Feed==

(() => {
  "use strict";

  function request(path, next_state = { requested: true }) {
    return {
      type: "request",
      request: { url: meta.base_url + path, method: "GET", headers: {} },
      next_state,
    };
  }

  function countItems(body, kind) {
    const raw = String(body ?? "").trim();
    const count = raw === "" ? Number.NaN : Number(raw);
    if (!Number.isInteger(count) || count < 0) {
      throw new Error(`fixture: invalid \${kind} count: \${body}`);
    }
    return count;
  }

  function search(event) {
    if (event.state == null) return request("/search");
    const count = countItems(event.response?.body ?? "", "search");
    return {
      type: "complete",
      items: Array.from({ length: count }, (_, index) => ({
        id: String(1001 + index),
        title: `Fixture Book \${index + 1}`,
        author: "Fixture Author",
        description: "Hermetic fixture book.",
      })),
    };
  }

  function bookInfo(event) {
    if (event.state == null) return request(`/book/\${event.input.bookId}`);
    return {
      type: "complete",
      value: {
        id: "1001",
        title: "Fixture Book 1",
        author: "Fixture Author",
        description: "Hermetic fixture book.",
      },
    };
  }

  function chapters(event) {
    if (event.state == null) return request(`/chapters/\${event.input.bookId}`);
    const count = countItems(event.response?.body ?? "", "chapter");
    return {
      type: "complete",
      items: Array.from({ length: count }, (_, index) => ({
        id: String(index + 1),
        title: `Chapter \${index + 1}`,
      })),
    };
  }

  function paragraphs(event) {
    if (event.state == null) {
      return request(`/paragraphs/\${event.input.bookId}/\${event.input.chapterId}`);
    }
    return {
      type: "complete",
      items: [{ type: "text", content: "Fixture paragraph." }],
    };
  }

  return { search, bookInfo, chapters, paragraphs };
})()
''';

Future<void> installFixtureFeed({
  required String id,
  required String name,
  required int port,
  required Directory dataDir,
}) async {
  final scriptFile = File('${dataDir.path}/$id.js')
    ..writeAsStringSync(fixtureFeedScript(id: id, name: name, port: port));
  final preview = await FeedService.instance.previewFromFile(scriptFile.path);
  expect(preview.id, id);
  await FeedService.instance.installFeed(preview.requestId);
}
