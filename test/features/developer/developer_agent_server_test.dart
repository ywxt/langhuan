import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/developer/developer_agent_server.dart';
import 'package:langhuan/src/rust/api/comments.dart';
import 'package:langhuan/src/rust/api/debug.dart';

void main() {
  test('catalogue advertises consistent routes and HTTP mode names', () async {
    final server = DeveloperAgentServer(currentScript: () => 'source');
    addTearDown(server.stop);
    await server.start();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      server.baseUri!.resolve('/v1/operations'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.token}',
    );
    final response = await request.close();
    final body =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    expect(response.statusCode, HttpStatus.ok);

    // Every endpoint carries its method, path, and body guidance.
    final endpoints = body['endpoints'] as Map<String, dynamic>;
    expect(endpoints.keys, unorderedEquals(['run', 'load', 'reload']));
    for (final name in endpoints.keys) {
      final endpoint = endpoints[name] as Map<String, dynamic>;
      expect(endpoint['method'], 'POST');
      expect(endpoint['path'], startsWith('/v1/'));
      expect(endpoint['body'], isNotEmpty);
    }
    expect(endpoints['run']!['path'], '/v1/run');
    expect(
      (endpoints['run']!['body'] as Map).keys,
      unorderedEquals([
        'operation',
        'input',
        'mode',
        'cursor',
        'script',
        'feed_id',
      ]),
    );

    // The example is a runnable body: its operation is in the catalogue.
    final example = endpoints['run']!['example'] as Map<String, dynamic>;
    final names = [
      for (final operation in body['operations'] as List)
        (operation as Map<String, dynamic>)['name'] as String,
    ];
    expect(example['operation'], isIn(names));
    expect(example['input'], isA<Map<String, dynamic>>());

    // Auth guidance covers every route except health.
    expect((body['auth'] as Map<String, dynamic>)['unauthenticated_paths'], [
      '/v1/health',
    ]);

    // Failure modes are documented as status codes.
    expect(
      (body['errors'] as Map).keys,
      unorderedEquals(['400', '401', '404', '409', '413', '500']),
    );

    expect(
      (body['modes'] as Map).keys,
      unorderedEquals(['pipeline', 'single_page']),
    );
    final oldRoute = await client.postUrl(
      server.baseUri!.resolve('/v1/operations/run'),
    );
    oldRoute.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.token}',
    );
    final oldResponse = await oldRoute.close();
    expect(oldResponse.statusCode, HttpStatus.notFound);
    await oldResponse.drain<void>();
  });

  test('the copy-ready example asks the discovery endpoint first', () {
    final command = DeveloperAgentRoutes.curlExample(
      Uri.parse('http://127.0.0.1:49152'),
      'token',
    );
    // The dialog's example sends agents to the catalogue first — its
    // response points back at /v1/run and the script endpoints — instead
    // of walking them straight into a run request.
    expect(
      command,
      "curl -s 'http://127.0.0.1:49152/v1/operations' "
      "-H 'Authorization: Bearer token'",
    );
    expect(command, isNot(contains('/v1/run')));
  });

  Future<(int, Map<String, dynamic>)> post(
    DeveloperAgentServer server,
    String path, [
    Map<String, Object?>? body,
    bool authorized = true,
  ]) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(server.baseUri!.resolve(path));
      request.headers.contentType = ContentType.json;
      if (authorized) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${server.token}',
        );
      }
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>,
      );
    } finally {
      client.close(force: true);
    }
  }

  test(
    'loading excludes concurrent runs and loads until the editor is updated',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      var editor = 'old';
      final server = DeveloperAgentServer(
        currentScript: () => editor,
        editorScriptWriter: (script) async {
          started.complete();
          await finish.future;
          editor = script;
        },
      );
      addTearDown(server.stop);
      await server.start();
      final load = post(server, '/v1/load', {'script': 'new'});
      await started.future;
      expect(
        (await post(server, '/v1/run', {
          'operation': 'search',
          'input': {'keyword': 'book'},
        })).$1,
        HttpStatus.conflict,
      );
      expect(
        (await post(server, '/v1/load', {'script': 'other'})).$1,
        HttpStatus.conflict,
      );
      expect(editor, 'old');
      finish.complete();
      expect((await load).$1, HttpStatus.ok);
      expect(editor, 'new');
    },
  );

  test(
    'loading and reloading a file changes editor source used by subsequent runs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'langhuan-agent-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/source.js');
      await file.writeAsString('version one');
      var editor = 'old source';
      String? executed;
      final server = DeveloperAgentServer(
        currentScript: () => editor,
        editorScriptWriter: (source) async {
          editor = source;
        },
        runner: ({required script, required stage}) async {
          executed = script;
          return const DebugRunResult(
            auth: DebugAuthUse.notSupported,
            trace: [],
            droppedEntries: 0,
            steps: [],
            droppedSteps: 0,
            durationMs: 0,
          );
        },
      );
      addTearDown(server.stop);
      await server.start();
      expect(
        (await post(server, '/v1/load', {'path': file.path}, false)).$1,
        HttpStatus.unauthorized,
      );
      expect(editor, 'old source');
      expect((await post(server, '/v1/reload')).$1, HttpStatus.badRequest);
      final loaded = await post(server, '/v1/load', {'path': file.path});
      expect(loaded.$1, HttpStatus.ok);
      expect(loaded.$2['source'], 'path');
      expect(editor, 'version one');
      await file.writeAsString('version two');
      expect((await post(server, '/v1/reload')).$1, HttpStatus.ok);
      expect(editor, 'version two');
      expect(
        (await post(server, '/v1/run', {
          'operation': 'search',
          'input': {'keyword': 'book'},
        })).$1,
        HttpStatus.ok,
      );
      expect(executed, 'version two');
      await file.writeAsBytes([0xff]);
      expect((await post(server, '/v1/reload')).$1, HttpStatus.badRequest);
      expect(editor, 'version two');
      await file.writeAsString('x' * (2 * 1024 * 1024 + 1));
      expect(
        (await post(server, '/v1/reload')).$1,
        HttpStatus.requestEntityTooLarge,
      );
      expect(editor, 'version two');
    },
  );

  test(
    'script loading validates sources and respects workspace activity',
    () async {
      var editor = 'unchanged';
      var busy = false;
      var installed = 'installed version one';
      final server = DeveloperAgentServer(
        currentScript: () => editor,
        workspaceBusy: () => busy,
        editorScriptWriter: (source) async {
          editor = source;
        },
        installedScriptLoader: ({required feedId}) async => installed,
      );
      addTearDown(server.stop);
      await server.start();
      for (final body in <Map<String, Object?>>[
        {},
        {'script': ''},
        {'script': 1},
        {'script': 'a', 'feed_id': 'b'},
        {'path': 'relative.js'},
      ]) {
        expect(
          (await post(server, '/v1/load', body)).$1,
          HttpStatus.badRequest,
        );
        expect(editor, 'unchanged');
      }
      busy = true;
      expect(
        (await post(server, '/v1/load', {'script': 'new'})).$1,
        HttpStatus.conflict,
      );
      busy = false;
      expect(
        (await post(server, '/v1/load', {'feed_id': 'source'})).$1,
        HttpStatus.ok,
      );
      expect(editor, installed);
      installed = 'installed version two';
      expect((await post(server, '/v1/reload')).$1, HttpStatus.ok);
      expect(editor, installed);
      expect(
        (await post(server, '/v1/load', {'script': 'inline source'})).$1,
        HttpStatus.ok,
      );
      expect(editor, 'inline source');
    },
  );

  test(
    'agent API is loopback-only, authenticated, and runs an operation',
    () async {
      String? receivedScript;
      DebugStage? receivedStage;
      final server = DeveloperAgentServer(
        currentScript: () => 'export default {}',
        runner: ({required script, required stage}) async {
          receivedScript = script;
          receivedStage = stage;
          return const DebugRunResult(
            auth: DebugAuthUse.notSupported,
            trace: [],
            droppedEntries: 0,
            steps: [
              DebugStepTraceEntry(
                operation: 'search',
                round: 0,
                kind: 'complete',
                summary: '0 item(s)',
              ),
            ],
            droppedSteps: 0,
            durationMs: 3,
          );
        },
      );
      addTearDown(server.stop);
      await server.start();

      expect(server.baseUri!.host, '127.0.0.1');

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final unauthorized = await client.postUrl(
        server.baseUri!.resolve('/v1/run'),
      );
      unauthorized.headers.contentType = ContentType.json;
      unauthorized.write(
        jsonEncode({
          'operation': 'search',
          'input': {'keyword': 'book'},
        }),
      );
      expect((await unauthorized.close()).statusCode, HttpStatus.unauthorized);

      final request = await client.postUrl(server.baseUri!.resolve('/v1/run'));
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${server.token}');
      request.write(
        jsonEncode({
          'operation': 'search',
          'input': {'keyword': 'book'},
        }),
      );
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join());

      expect(response.statusCode, HttpStatus.ok);
      expect(body['ok'], true);
      expect(body['steps'], hasLength(1));
      expect(receivedScript, 'export default {}');
      expect(receivedStage, isA<DebugStage_Search>());
      expect((receivedStage! as DebugStage_Search).keyword, 'book');
    },
  );

  test('single_page mode forwards raw input and cursor', () async {
    DebugStage? receivedStage;
    final server = DeveloperAgentServer(
      currentScript: () => 'export default {}',
      runner: ({required script, required stage}) async {
        receivedStage = stage;
        return const DebugRunResult(
          auth: DebugAuthUse.notSupported,
          output: DebugStageOutput.manual(
            resultJson: '[{"id":"2"}]',
            nextCursorJson: '{"page":3}',
          ),
          trace: [],
          droppedEntries: 0,
          steps: [],
          droppedSteps: 0,
          durationMs: 1,
        );
      },
    );
    addTearDown(server.stop);
    await server.start();

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(server.baseUri!.resolve('/v1/run'));
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${server.token}');
    request.write(
      jsonEncode({
        'mode': 'single_page',
        'operation': 'search',
        'input': {'keyword': 'book'},
        'cursor': {'page': 2},
      }),
    );
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join());

    expect(response.statusCode, HttpStatus.ok);
    expect(receivedStage, isA<DebugStage_Manual>());
    final stage = receivedStage! as DebugStage_Manual;
    expect(stage.operation, 'search');
    expect(jsonDecode(stage.inputJson), {'keyword': 'book'});
    expect(jsonDecode(stage.cursorJson), {'page': 2});
    expect(body['output']['result'], [
      {'id': '2'},
    ]);
    expect(body['output']['next_cursor'], {'page': 3});
    expect(body['output']['type'], 'single_page');
  });

  test('comments operations run as a pipeline by default', () async {
    DebugStage? receivedStage;
    final server = DeveloperAgentServer(
      currentScript: () => 'export default {}',
      runner: ({required script, required stage}) async {
        receivedStage = stage;
        return const DebugRunResult(
          auth: DebugAuthUse.notSupported,
          output: DebugStageOutput.comments(items: []),
          trace: [],
          droppedEntries: 0,
          steps: [],
          droppedSteps: 0,
          durationMs: 1,
        );
      },
    );
    addTearDown(server.stop);
    await server.start();

    final (status, body) = await post(server, '/v1/run', {
      'operation': 'comments.paragraph',
      'input': {
        'bookId': 'b',
        'chapterId': 'c',
        'paragraphId': '839',
        'parentId': null,
      },
    });

    expect(status, HttpStatus.ok);
    expect(body['ok'], true);
    // No mode given: a comments operation is a regular pipeline stage now.
    expect(receivedStage, isA<DebugStage_Comments>());
    final stage = receivedStage! as DebugStage_Comments;
    expect(stage.bookId, 'b');
    expect(stage.chapterId, 'c');
    expect(stage.paragraphId, '839');
    expect(stage.parentId, isNull);
    expect(body['output'], {
      'type': 'comments',
      'items': [],
    });

    // Chapter comments accept an optional parentId for reply threads.
    await post(server, '/v1/run', {
      'operation': 'comments.chapter',
      'input': {'bookId': 'b', 'chapterId': 'c', 'parentId': 'c7'},
    });
    final replyStage = receivedStage! as DebugStage_Comments;
    expect(replyStage.paragraphId, isNull);
    expect(replyStage.parentId, 'c7');

    // The single-page escape hatch still steps one page at a time.
    await post(server, '/v1/run', {
      'mode': 'single_page',
      'operation': 'comments.chapter',
      'input': {'bookId': 'b', 'chapterId': 'c'},
      'cursor': {'page': 2},
    });
    expect(receivedStage, isA<DebugStage_Manual>());
  });

  test('comments pipeline output serializes every comment field', () async {
    final server = DeveloperAgentServer(
      currentScript: () => 'export default {}',
      runner: ({required script, required stage}) async {
        return DebugRunResult(
          auth: DebugAuthUse.notSupported,
          output: DebugStageOutput.comments(items: [
            CommentItem(
              id: 'c7',
              author: const CommentAuthor(name: 'Reader', avatarUrl: null),
              text: 'An interesting paragraph.',
              createdAtMs: null,
              likeCount: 12,
              replies: const CommentReplies(totalCount: 3),
            ),
          ]),
          trace: const [],
          droppedEntries: 0,
          steps: const [],
          droppedSteps: 0,
          durationMs: 1,
        );
      },
    );
    addTearDown(server.stop);
    await server.start();

    final (status, body) = await post(server, '/v1/run', {
      'operation': 'comments.chapter',
      'input': {'bookId': 'b', 'chapterId': 'c'},
    });

    expect(status, HttpStatus.ok);
    expect(body['output'], {
      'type': 'comments',
      'items': [
        {
          'id': 'c7',
          'author': {'name': 'Reader', 'avatar_url': null},
          'text': 'An interesting paragraph.',
          'created_at_ms': null,
          'like_count': 12,
          'replies': {'total_count': 3},
        },
      ],
    });
  });

  test('comments operations validate their input', () async {
    final server = DeveloperAgentServer(
      currentScript: () => 'export default {}',
      runner: ({required script, required stage}) async {
        throw StateError('the runner must not be reached');
      },
    );
    addTearDown(server.stop);
    await server.start();

    // comments.paragraph without a paragraphId cannot run.
    expect(
      (await post(server, '/v1/run', {
        'operation': 'comments.paragraph',
        'input': {'bookId': 'b', 'chapterId': 'c'},
      })).$1,
      HttpStatus.badRequest,
    );
    // An empty parentId is rejected like any other empty string.
    expect(
      (await post(server, '/v1/run', {
        'operation': 'comments.chapter',
        'input': {'bookId': 'b', 'chapterId': 'c', 'parentId': '  '},
      })).$1,
      HttpStatus.badRequest,
    );
  });
}
