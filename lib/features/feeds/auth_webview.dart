import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_all/webview_all.dart';

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
/// [webview_all] supplies the same embedded controller/widget API on every
/// supported native platform. Cookies are captured after each page load
/// because login flows can finish on a different host from the entry page.
abstract class AuthWebviewSession extends ChangeNotifier {
  AuthWebviewSession();

  factory AuthWebviewSession.platform() => _InlineAuthWebviewSession();

  /// The embedded login view, once [open] succeeded.
  Widget? get view;

  /// Whether a page is loading.
  bool get isPageLoading;

  /// Load progress, 0..1.
  double get pageProgress;

  /// Whether [snapshot] can succeed right now.
  bool get canVerify;

  /// Starts the session at [url].
  Future<void> open(String url, {required String userAgent});

  /// Collects the login context for manual verification.
  Future<AuthPageSnapshot> snapshot();

  /// Releases session resources where the platform exposes an explicit close.
  Future<void> close();
}

class _InlineAuthWebviewSession extends AuthWebviewSession {
  WebViewController? _controller;

  /// Lazily created after the platform implementation has registered.
  WebViewCookieManager? _cookieManager;
  Widget? _view;
  String? _url;
  bool _pageLoading = false;
  double _pageProgress = 0;
  bool _disposed = false;

  /// Cookies accumulated across page loads, keyed by `domain|path|name`.
  final Map<String, CookieEntry> _capturedCookies = {};

  @override
  Widget? get view => _view;

  @override
  bool get isPageLoading => _pageLoading;

  @override
  double get pageProgress => _pageProgress;

  @override
  bool get canVerify => _controller != null;

  @override
  Future<void> open(String url, {required String userAgent}) async {
    if (_controller != null || _disposed) return;
    _url = url;
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
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
    );
    // The feed owns this value. Apply it before the first navigation so
    // cookies and anti-bot credentials are issued for the same UA later used
    // by the feed's HTTP requests.
    await controller.setUserAgent(userAgent);
    _controller = controller;
    _view = WebViewWidget(controller: controller);
    if (_disposed) return;
    notifyListeners();
    await controller.loadRequest(Uri.parse(url));
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
