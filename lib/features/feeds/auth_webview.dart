import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../src/rust/api/types.dart';

/// Everything the feed's auth parser needs from the login page at manual
/// verification time.
@immutable
class AuthPageSnapshot {
  const AuthPageSnapshot({
    required this.currentUrl,
    required this.html,
    required this.cookies,
  });

  final String currentUrl;
  final String html;
  final List<CookieEntry> cookies;
}

/// One login session in the platform WebView.
///
/// Two flavors implement this interface; both are created through
/// [AuthWebviewSession.platform] and the login page treats them uniformly:
///
/// - Android, iOS and macOS embed the official webview_flutter widget.
///   Cookies are captured on every finished page load because login flows
///   finish on a different host from the page that set them.
/// - Linux and Windows open a native browser window via
///   desktop_webview_window; [snapshot] reads the URL, page HTML and cookies
///   from that window.
abstract class AuthWebviewSession extends ChangeNotifier {
  AuthWebviewSession();

  factory AuthWebviewSession.platform() =>
      Platform.isLinux || Platform.isWindows
      ? _DesktopWindowAuthWebviewSession()
      : _InlineAuthWebviewSession();

  /// Whether the login page runs in a separate native window (Linux and
  /// Windows) instead of the embedded [view].
  bool get usesSeparateWindow;

  /// The embedded login view, once [open] succeeded. Always null when
  /// [usesSeparateWindow] is true.
  Widget? get view;

  /// Whether a page is loading in the embedded view (inline flavor only).
  bool get isPageLoading;

  /// Load progress of the embedded view, 0..1 (inline flavor only).
  double get pageProgress;

  /// Whether [open] is currently creating the native window
  /// (separate-window flavor only).
  bool get isOpeningWindow;

  /// Whether the native window is open (separate-window flavor only).
  bool get isWindowOpen;

  /// Whether [snapshot] can succeed right now.
  bool get canVerify;

  /// Starts — or, after the native window was closed, restarts — the
  /// session at [url]. [title] names the native window where applicable.
  Future<void> open(String url, {String? title});

  /// Collects the login context for manual verification.
  Future<AuthPageSnapshot> snapshot();

  /// Closes the native window, if there is one.
  Future<void> close();
}

class _InlineAuthWebviewSession extends AuthWebviewSession {
  WebViewController? _controller;

  /// Lazily created: WebViewCookieManager asserts that a WebViewPlatform
  /// implementation exists, which is only true on Android, iOS and macOS —
  /// the platforms this flavor runs on.
  WebViewCookieManager? _cookieManager;
  Widget? _view;
  String? _url;
  bool _pageLoading = false;
  double _pageProgress = 0;
  bool _disposed = false;

  /// Cookies accumulated across page loads, keyed by `domain|path|name`.
  final Map<String, CookieEntry> _capturedCookies = {};

  @override
  bool get usesSeparateWindow => false;

  @override
  Widget? get view => _view;

  @override
  bool get isPageLoading => _pageLoading;

  @override
  double get pageProgress => _pageProgress;

  @override
  bool get isOpeningWindow => false;

  @override
  bool get isWindowOpen => false;

  @override
  bool get canVerify => _controller != null;

  @override
  Future<void> open(String url, {String? title}) async {
    if (_controller != null || _disposed) return;
    _url = url;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (_disposed) return;
            _pageProgress = progress / 100;
            notifyListeners();
          },
          onPageStarted: (_) {
            if (_disposed) return;
            _pageLoading = true;
            notifyListeners();
          },
          onPageFinished: (url) {
            if (_disposed) return;
            _pageLoading = false;
            notifyListeners();
            final uri = Uri.tryParse(url);
            if (uri != null) unawaited(_captureCookies(uri));
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
    _controller = controller;
    _view = WebViewWidget(controller: controller);
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> _captureCookies(Uri uri) async {
    try {
      final cookieManager = _cookieManager ??= WebViewCookieManager();
      final cookies = await cookieManager.getCookies(domain: uri);
      if (_disposed) return;
      for (final cookie in cookies) {
        _capturedCookies['${cookie.domain}|${cookie.path}|${cookie.name}'] =
            CookieEntry(
              name: cookie.name,
              value: cookie.value,
              domain: cookie.domain,
              path: cookie.path,
            );
      }
    } catch (_) {
      // HTML and URL based auth must still work when cookie access fails.
    }
  }

  @override
  Future<AuthPageSnapshot> snapshot() async {
    final controller = _controller;
    if (controller == null) throw StateError('webview is not open');
    final currentUrl = await controller.currentUrl() ?? _url ?? '';
    final result = await controller.runJavaScriptReturningResult(
      'document.documentElement.outerHTML',
    );
    return AuthPageSnapshot(
      currentUrl: currentUrl,
      html: _decodeJsStringResult(result),
      cookies: _capturedCookies.values.toList(growable: false),
    );
  }

  @override
  Future<void> close() async {
    // The embedded view dies with the page that hosts it.
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// `runJavaScriptReturningResult` JSON-encodes string results on Android,
  /// so a string may arrive wrapped in quotes.
  static String _decodeJsStringResult(Object? result) {
    if (result is! String) return result?.toString() ?? '';
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is String) return decoded;
      } catch (_) {
        // Not JSON-encoded after all; use the raw string.
      }
    }
    return result;
  }
}

class _DesktopWindowAuthWebviewSession extends AuthWebviewSession {
  Webview? _webview;
  String? _url;
  bool _opening = false;
  bool _closed = true;
  bool _disposed = false;

  /// Hosts the window navigated to; at snapshot time only cookies for these
  /// hosts are submitted, mirroring the per-page capture of the inline
  /// flavor.
  final Set<String> _visitedHosts = {};

  @override
  bool get usesSeparateWindow => true;

  @override
  Widget? get view => null;

  @override
  bool get isPageLoading => false;

  @override
  double get pageProgress => 0;

  @override
  bool get isOpeningWindow => _opening;

  @override
  bool get isWindowOpen => _webview != null && !_closed;

  @override
  bool get canVerify => isWindowOpen;

  @override
  Future<void> open(String url, {String? title}) async {
    if (_disposed || _opening || isWindowOpen) return;
    _url = url;
    _opening = true;
    if (!_disposed) notifyListeners();
    try {
      final webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: title ?? '',
          windowWidth: 1100,
          windowHeight: 720,
        ),
      );
      if (_disposed) {
        unawaited(webview.close());
        return;
      }
      webview.navigationState.addListener(_onNavigationChanged);
      unawaited(
        webview.onClose.then((_) {
          if (_disposed) return;
          _closed = true;
          notifyListeners();
        }),
      );
      _webview = webview;
      _closed = false;
      // A window closed during creation completes onClose as a microtask;
      // let that run so the closed state wins before the entry URL loads.
      await Future<void>.delayed(Duration.zero);
      if (!_closed && !_disposed) {
        await webview.launch(url);
      }
    } finally {
      if (!_disposed) {
        _opening = false;
        notifyListeners();
      }
    }
  }

  void _onNavigationChanged() {
    final url = _webview?.navigationState.value.url;
    if (url == null) return;
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) _visitedHosts.add(host);
  }

  /// Whether [domain] (cookie form, possibly `.example.com`) belongs to a
  /// host the window actually visited.
  bool _matchesVisitedHosts(String domain) {
    final stripped = domain.startsWith('.') ? domain.substring(1) : domain;
    if (stripped.isEmpty) return false;
    for (final host in _visitedHosts) {
      if (host == stripped || host.endsWith('.$stripped')) return true;
    }
    return false;
  }

  @override
  Future<AuthPageSnapshot> snapshot() async {
    final webview = _webview;
    if (webview == null || _closed) {
      throw StateError('login window is closed');
    }
    final currentUrl = webview.navigationState.value.url ?? _url ?? '';
    final result = await webview.evaluateJavaScript(
      'document.documentElement.outerHTML',
    );
    final all = await webview.getAllCookies();
    final cookies = all
        .where((cookie) => _matchesVisitedHosts(cookie.domain))
        .map(
          (cookie) => CookieEntry(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expires?.toIso8601String(),
            secure: cookie.secure,
            httpOnly: cookie.httpOnly,
          ),
        )
        .toList();
    return AuthPageSnapshot(
      currentUrl: currentUrl,
      html: result is String ? result : '',
      cookies: cookies,
    );
  }

  @override
  Future<void> close() async {
    await _webview?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
