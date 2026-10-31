import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../src/rust/api/debug.dart';
import '../../src/rust/api/types.dart';

typedef CurrentDebugScript = String Function();
typedef EditorScriptWriter = Future<void> Function(String script);
typedef DebugStageRunner =
    Future<DebugRunResult> Function({
      required String script,
      required DebugStage stage,
    });
typedef InstalledScriptLoader =
    Future<String> Function({required String feedId});

/// Loopback-only HTTP facade for local AI agents and editor integrations.
///
/// It exposes the same sandboxed runner as the UI. The server exists only
/// while the developer page owns it, accepts one run at a time, requires a
/// random bearer token, and never binds to a LAN interface.
class DeveloperAgentServer {
  DeveloperAgentServer({
    required CurrentDebugScript currentScript,
    DebugStageRunner runner = debugRunStage,
    InstalledScriptLoader installedScriptLoader = debugGetInstalledScript,
    EditorScriptWriter? editorScriptWriter,
    bool Function()? workspaceBusy,
  }) : _currentScript = currentScript,
       _runner = runner,
       _installedScriptLoader = installedScriptLoader,
       _editorScriptWriter = editorScriptWriter,
       _workspaceBusy = workspaceBusy ?? (() => false);

  static const _maxRequestBytes = 2 * 1024 * 1024;
  final CurrentDebugScript _currentScript;
  final DebugStageRunner _runner;
  final InstalledScriptLoader _installedScriptLoader;
  final EditorScriptWriter? _editorScriptWriter;
  final bool Function() _workspaceBusy;
  ({String kind, String value})? _loadedSource;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  bool _busy = false;

  String? _token;
  String? get token => _token;
  bool get isRunning => _server != null;
  Uri? get baseUri =>
      _server == null ? null : Uri.parse('http://127.0.0.1:${_server!.port}');

  Future<void> start() async {
    if (_server != null) return;
    _token = _newToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _subscription = server.listen(
      (request) => unawaited(_handle(request)),
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    await _subscription?.cancel();
    _subscription = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      _setResponseDefaults(request.response);
      if (request.method == 'GET' && request.uri.path == '/v1/health') {
        return _json(request.response, HttpStatus.ok, {
          'ok': true,
          'service': 'langhuan-feed-debug',
          'api_version': 1,
        });
      }

      if (!_authorized(request)) {
        return _json(request.response, HttpStatus.unauthorized, {
          'error': 'missing or invalid bearer token',
        });
      }

      if (request.method == 'GET' && request.uri.path == '/v1/operations') {
        return _json(request.response, HttpStatus.ok, {
          'modes': {
            'pipeline': 'default; follows next_cursor until complete',
            'singlePage':
                'runs one reducer operation with explicit input and cursor',
          },
          'operations': [
            {
              'name': 'search',
              'input': {'keyword': 'string'},
            },
            {
              'name': 'bookInfo',
              'input': {'bookId': 'string'},
            },
            {
              'name': 'chapters',
              'input': {'bookId': 'string'},
            },
            {
              'name': 'paragraphs',
              'input': {'bookId': 'string', 'chapterId': 'string'},
            },
            {'name': 'authStatus', 'input': <String, String>{}},
          ],
          'script_endpoints': {
            'load': '/v1/script/load',
            'reload': '/v1/script/reload',
          },
        });
      }

      if (request.method == 'POST' &&
          (request.uri.path == '/v1/script/load' ||
              request.uri.path == '/v1/script/reload')) {
        if (_busy || _workspaceBusy()) {
          return _json(request.response, HttpStatus.conflict, {
            'error': 'the debug workspace is busy',
          });
        }
        final writer = _editorScriptWriter;
        if (writer == null) {
          return _json(request.response, HttpStatus.notImplemented, {
            'error': 'editor loading is unavailable',
          });
        }
        _busy = true;
        try {
          final body = await _readJsonObject(request, allowEmpty: true);
          final source = request.uri.path.endsWith('/reload')
              ? _loadedSource
              : _parseScriptSource(body);
          if (source == null) {
            throw const _AgentRequestError(
              HttpStatus.badRequest,
              'load a script before reloading',
            );
          }
          final script = await _loadSource(source);
          if (script.trim().isEmpty) {
            throw const _AgentRequestError(
              HttpStatus.badRequest,
              'script must not be empty',
            );
          }
          final bytes = utf8.encode(script).length;
          if (bytes > _maxRequestBytes) {
            throw const _AgentRequestError(
              HttpStatus.requestEntityTooLarge,
              'script exceeds 2 MiB',
            );
          }
          if (_workspaceBusy() || _server == null) {
            throw const _AgentRequestError(
              HttpStatus.conflict,
              'the debug workspace is unavailable',
            );
          }
          await writer(script);
          _loadedSource = source;
          return _json(request.response, HttpStatus.ok, {
            'ok': true,
            'source': source.kind,
            if (source.kind != 'script') source.kind: source.value,
            'bytes': bytes,
          });
        } finally {
          _busy = false;
        }
      }

      if (request.method == 'POST' && request.uri.path == '/v1/run') {
        if (_busy || _workspaceBusy()) {
          return _json(request.response, HttpStatus.conflict, {
            'error': 'another debug run is active',
          });
        }
        _busy = true;
        try {
          final body = await _readJsonObject(request);
          final script = await _resolveScript(body);
          final stage = _parseStage(body);
          final result = await _runner(script: script, stage: stage);
          return _json(request.response, HttpStatus.ok, _resultJson(result));
        } finally {
          _busy = false;
        }
      }

      return _json(request.response, HttpStatus.notFound, {
        'error': 'route not found',
      });
    } on _AgentRequestError catch (error) {
      return _json(request.response, error.status, {'error': error.message});
    } catch (error) {
      return _json(request.response, HttpStatus.internalServerError, {
        'error': error.toString(),
      });
    }
  }

  bool _authorized(HttpRequest request) {
    final expected = _token;
    if (expected == null) return false;
    return request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $expected';
  }

  Future<Map<String, Object?>> _readJsonObject(
    HttpRequest request, {
    bool allowEmpty = false,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > _maxRequestBytes) {
        throw const _AgentRequestError(
          HttpStatus.requestEntityTooLarge,
          'request body exceeds 2 MiB',
        );
      }
    }
    Object? decoded;
    if (allowEmpty && builder.length == 0) return {};
    try {
      decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    } on FormatException {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'request body must be a JSON object',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'request body must be a JSON object',
      );
    }
    return decoded;
  }

  ({String kind, String value}) _parseScriptSource(Map<String, Object?> body) {
    final keys = ['script', 'path', 'feed_id'].where(body.containsKey).toList();
    if (keys.length != 1 ||
        body[keys.single] is! String ||
        (body[keys.single] as String).trim().isEmpty) {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'provide exactly one non-empty string: script, path, or feed_id',
      );
    }
    final key = keys.single;
    final value = body[key] as String;
    return (kind: key, value: key == 'script' ? value : value.trim());
  }

  Future<String> _loadSource(({String kind, String value}) source) async {
    if (source.kind == 'script') return source.value;
    if (source.kind == 'feed_id') {
      return _installedScriptLoader(feedId: source.value);
    }
    final file = File(source.value);
    if (!file.isAbsolute) {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'path must be absolute',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.openRead()) {
        bytes.add(chunk);
        if (bytes.length > _maxRequestBytes) {
          throw const _AgentRequestError(
            HttpStatus.requestEntityTooLarge,
            'script exceeds 2 MiB',
          );
        }
      }
      return utf8.decode(bytes.takeBytes());
    } on FileSystemException {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'cannot read script file',
      );
    } on FormatException {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'script file must be UTF-8',
      );
    }
  }

  Future<String> _resolveScript(Map<String, Object?> body) async {
    final inline = body['script'];
    if (inline is String && inline.trim().isNotEmpty) return inline;
    final feedId = body['feed_id'];
    if (feedId is String && feedId.trim().isNotEmpty) {
      return _installedScriptLoader(feedId: feedId.trim());
    }
    final current = _currentScript();
    if (current.trim().isEmpty) {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'provide script or feed_id, or load a script in the editor',
      );
    }
    return current;
  }

  DebugStage _parseStage(Map<String, Object?> body) {
    final operation = body['operation'];
    final input = body['input'];
    if (operation is! String || input is! Map<String, Object?>) {
      throw const _AgentRequestError(
        HttpStatus.badRequest,
        'operation must be a string and input must be an object',
      );
    }
    final mode = body['mode'];
    if (mode == 'singlePage') {
      return DebugStage.manual(
        operation: operation,
        inputJson: jsonEncode(input),
        cursorJson: jsonEncode(body['cursor']),
      );
    }
    if (mode != null && mode != 'pipeline') {
      throw _AgentRequestError(HttpStatus.badRequest, 'unknown mode: $mode');
    }
    String requiredString(String name) {
      final value = input[name];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      throw _AgentRequestError(
        HttpStatus.badRequest,
        'input.$name must be a non-empty string',
      );
    }

    return switch (operation) {
      'search' => DebugStage.search(keyword: requiredString('keyword')),
      'bookInfo' => DebugStage.bookInfo(bookId: requiredString('bookId')),
      'chapters' => DebugStage.chapters(bookId: requiredString('bookId')),
      'paragraphs' => DebugStage.paragraphs(
        bookId: requiredString('bookId'),
        chapterId: requiredString('chapterId'),
      ),
      'authStatus' => const DebugStage.authStatus(),
      _ => throw _AgentRequestError(
        HttpStatus.badRequest,
        'unknown operation: $operation',
      ),
    };
  }

  void _setResponseDefaults(HttpResponse response) {
    response.headers.contentType = ContentType.json;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'no-store');
  }

  void _json(HttpResponse response, int status, Object value) {
    response.statusCode = status;
    response.write(jsonEncode(value));
    unawaited(response.close());
  }

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _AgentRequestError implements Exception {
  const _AgentRequestError(this.status, this.message);
  final int status;
  final String message;
}

Map<String, Object?> _resultJson(DebugRunResult result) => {
  'ok': result.error == null,
  'duration_ms': result.durationMs,
  'script': result.scriptMeta == null
      ? null
      : {
          'id': result.scriptMeta!.id,
          'name': result.scriptMeta!.name,
          'version': result.scriptMeta!.version,
          'base_url': result.scriptMeta!.baseUrl,
        },
  'auth': result.auth.name,
  'output': _outputJson(result.output),
  'error': result.error == null
      ? null
      : {
          'kind': result.error!.kind.toString(),
          'message': result.error!.message,
          'detail': result.error!.detail,
        },
  'steps': [
    for (final step in result.steps)
      {
        'operation': step.operation,
        'round': step.round,
        'kind': step.kind,
        'summary': step.summary,
      },
  ],
  'dropped_steps': result.droppedSteps,
  'http': [
    for (final entry in result.trace)
      {
        'method': entry.method,
        'url': entry.url,
        'final_url': entry.finalUrl,
        'status': entry.status,
        'request_headers': [
          for (final (name, value) in entry.requestHeaders)
            {'name': name, 'value': value},
        ],
        'elapsed_ms': entry.elapsedMs,
        'response_size': entry.responseSize,
        'body_preview': entry.bodyPreview,
        'error': entry.error,
      },
  ],
  'dropped_http_entries': result.droppedEntries,
};

Object? _outputJson(DebugStageOutput? output) => switch (output) {
  null => null,
  DebugStageOutput_Search(:final items) => {
    'type': 'search',
    'items': [for (final item in items) _searchItemJson(item)],
  },
  DebugStageOutput_BookInfo(:final info) => {
    'type': 'bookInfo',
    'value': _bookInfoJson(info),
  },
  DebugStageOutput_Chapters(:final items) => {
    'type': 'chapters',
    'items': [
      for (final item in items) {'id': item.id, 'title': item.title},
    ],
  },
  DebugStageOutput_Paragraphs(:final items) => {
    'type': 'paragraphs',
    'items': [for (final item in items) _paragraphJson(item)],
  },
  DebugStageOutput_AuthStatus(:final status) => {
    'type': 'authStatus',
    'value': status.name,
  },
  DebugStageOutput_Manual(
    :final itemsJson,
    :final valueJson,
    :final nextCursorJson,
  ) =>
    {
      'type': 'singlePage',
      'items': itemsJson == null ? null : jsonDecode(itemsJson),
      'value': valueJson == null ? null : jsonDecode(valueJson),
      'next_cursor': nextCursorJson == null ? null : jsonDecode(nextCursorJson),
    },
};

Map<String, Object?> _searchItemJson(SearchResultItem item) => {
  'id': item.id,
  'title': item.title,
  'author': item.author,
  'cover_url': item.coverUrl,
  'description': item.description,
};

Map<String, Object?> _bookInfoJson(BookInfo info) => {
  'id': info.id,
  'title': info.title,
  'author': info.author,
  'cover_url': info.coverUrl,
  'description': info.description,
};

Map<String, Object?> _paragraphJson(ParagraphContent paragraph) =>
    switch (paragraph) {
      ParagraphContent_Title(:final id, :final text) => {
        'type': 'title',
        'id': _paragraphId(id),
        'text': text,
      },
      ParagraphContent_Text(:final id, :final content) => {
        'type': 'text',
        'id': _paragraphId(id),
        'content': content,
      },
      ParagraphContent_Image(:final id, :final url, :final alt) => {
        'type': 'image',
        'id': _paragraphId(id),
        'url': url,
        'alt': alt,
      },
    };

Object _paragraphId(ParagraphId id) => switch (id) {
  ParagraphId_Index(:final field0) => field0,
  ParagraphId_Id(:final field0) => field0,
};
