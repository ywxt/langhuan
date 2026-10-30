import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:langhuan/features/developer/developer_agent_server.dart';
import 'package:langhuan/src/rust/api/debug.dart';

void main() {
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

  test('singlePage mode forwards raw input and cursor', () async {
    DebugStage? receivedStage;
    final server = DeveloperAgentServer(
      currentScript: () => 'export default {}',
      runner: ({required script, required stage}) async {
        receivedStage = stage;
        return const DebugRunResult(
          auth: DebugAuthUse.notSupported,
          output: DebugStageOutput.manual(
            itemsJson: '[{"id":"2"}]',
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
        'mode': 'singlePage',
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
    expect(body['output']['items'], [
      {'id': '2'},
    ]);
    expect(body['output']['next_cursor'], {'page': 3});
  });
}
