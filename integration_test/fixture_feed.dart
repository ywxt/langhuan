// Shared hermetic fixture for the integration tests: a Lua feed script
// backed by a local HTTP server, plus the install helper.
//
// The script is count-driven: the search and chapters endpoints answer with
// a plain number and the script turns it into that many items, so a test
// controls a source's output (or failure, via a non-numeric body) by
// changing what its server serves. book_info and paragraphs are static.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:langhuan/features/feeds/feed_service.dart';

/// Lua feed script backed by one of the test's local HTTP servers.
String fixtureFeedScript({
  required String id,
  required String name,
  required int port,
}) =>
    '''
-- ==Feed==
-- @id           $id
-- @name         $name
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
            local count = tonumber(resp.body or "")
            if count == nil then
                error("fixture: invalid search count: " .. tostring(resp.body))
            end
            local items = {}
            for i = 1, count do
                table.insert(items, {
                    id = tostring(1000 + i),
                    title = "Fixture Book " .. tostring(i),
                    author = "Fixture Author",
                    description = "Hermetic fixture book.",
                })
            end
            return {
                items = items,
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
                title = "Fixture Book 1",
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

/// Install a fixture feed script into [dataDir] and register it.
Future<void> installFixtureFeed({
  required String id,
  required String name,
  required int port,
  required Directory dataDir,
}) async {
  final scriptFile = File('${dataDir.path}/$id.lua')
    ..writeAsStringSync(fixtureFeedScript(id: id, name: name, port: port));
  final preview = await FeedService.instance.previewFromFile(scriptFile.path);
  expect(preview.id, id);
  await FeedService.instance.installFeed(preview.requestId);
}
