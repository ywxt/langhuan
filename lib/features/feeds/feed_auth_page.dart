import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../src/rust/api/types.dart';
import 'feed_service.dart';

class FeedAuthPage extends StatefulWidget {
  const FeedAuthPage({super.key, required this.feedId});

  final String feedId;

  @override
  State<FeedAuthPage> createState() => _FeedAuthPageState();
}

class _FeedAuthPageState extends State<FeedAuthPage> {
  InAppWebViewController? _controller;
  bool _isSubmitting = false;
  bool _isLoadingEntry = true;
  String? _error;
  FeedAuthEntryModel? _entry;

  /// Response headers captured from the most recent main-frame navigation.
  List<(String, String)> _lastResponseHeaders = const [];

  @override
  void initState() {
    super.initState();
    _loadEntry();
  }

  Future<void> _loadEntry() async {
    setState(() {
      _isLoadingEntry = true;
      _error = null;
    });

    try {
      final entry = await FeedService.instance.getFeedAuthEntry(widget.feedId);
      if (!mounted) return;

      if (entry == null) {
        final l10n = AppLocalizations.of(context);
        setState(() {
          _error = l10n.feedAuthNotSupported;
          _isLoadingEntry = false;
        });
        return;
      }

      _entry = entry;
      setState(() {
        _isLoadingEntry = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoadingEntry = false;
      });
    }
  }

  Future<void> _submitPage() async {
    if (_isSubmitting || _controller == null) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final controller = _controller!;
      final currentUrl =
          (await controller.getUrl())?.toString() ?? _entry?.url ?? '';

      final html =
          await controller.evaluateJavascript(
                source: 'document.documentElement.outerHTML',
              )
              as String? ??
          '';

      // Collect cookies via CookieManager for the current URL.
      final url = await controller.getUrl();
      final cookieManager = CookieManager.instance();
      final rawCookies = url != null
          ? await cookieManager.getCookies(url: url)
          : <Cookie>[];
      final structuredCookies = rawCookies
          .map((c) => CookieEntry(name: c.name, value: c.value.toString()))
          .toList(growable: false);

      final responseHeaders = _lastResponseHeaders;

      await FeedService.instance.submitFeedAuthPage(
        feedId: widget.feedId,
        currentUrl: currentUrl,
        response: html,
        responseHeaders: responseHeaders,
        cookies: structuredCookies,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.feedAuthPageTitle),
        actions: [
          TextButton(
            onPressed: _isSubmitting || _isLoadingEntry ? null : _submitPage,
            child: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.feedAuthDone),
          ),
          const SizedBox(width: LanghuanTheme.spaceSm),
        ],
      ),
      body: _isLoadingEntry
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                child: Text(_error!),
              ),
            )
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_entry!.url)),
              initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
              onWebViewCreated: (controller) {
                _controller = controller;
              },
              onLoadStop: (controller, url) async {
                if (url == null) return;
                _lastResponseHeaders = await _fetchResponseHeaders(
                  controller,
                  url.toString(),
                );
              },
            ),
    );
  }

  /// Fetch response headers for [url] via JS `fetch()` inside the WebView.
  ///
  /// Falls back to an empty list on CORS or other errors.
  Future<List<(String, String)>> _fetchResponseHeaders(
    InAppWebViewController controller,
    String url,
  ) async {
    try {
      final result = await controller.evaluateJavascript(
        source:
            '''
(async () => {
  try {
    const r = await fetch('${_escapeJsString(url)}', {
      method: 'GET',
      credentials: 'include',
    });
    const pairs = [];
    r.headers.forEach((v, k) => pairs.push(k + '\\x00' + v));
    return pairs.join('\\n');
  } catch (_) {
    return '';
  }
})()
''',
      );
      final text = (result as String?) ?? '';
      if (text.isEmpty) return const [];
      return text
          .split('\n')
          .where((line) => line.contains('\x00'))
          .map((line) {
            final idx = line.indexOf('\x00');
            return (line.substring(0, idx), line.substring(idx + 1));
          })
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static String _escapeJsString(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
  }
}
