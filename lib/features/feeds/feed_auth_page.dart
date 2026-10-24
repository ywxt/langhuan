import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../src/rust/api/types.dart';
import 'feed_providers.dart';
import 'feed_service.dart';

class FeedAuthPage extends ConsumerStatefulWidget {
  const FeedAuthPage({super.key, required this.feedId});

  final String feedId;

  @override
  ConsumerState<FeedAuthPage> createState() => _FeedAuthPageState();
}

class _FeedAuthPageState extends ConsumerState<FeedAuthPage> {
  InAppWebViewController? _controller;
  bool _isSubmitting = false;
  bool _isLoadingEntry = true;
  bool _isPageLoading = false;
  bool _hasCompletedInitialLoad = false;
  double _pageProgress = 0;
  String? _error;
  String? _submitError;
  FeedAuthEntryModel? _entry;

  /// Cookies are accumulated across redirects because OAuth and other login
  /// flows commonly finish on a different host from the page that set them.
  final Map<String, CookieEntry> _capturedCookies = {};

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

  Future<void> _submitPage({bool automatic = false}) async {
    if (_isSubmitting || _controller == null) return;

    setState(() {
      _isSubmitting = true;
      if (!automatic) _submitError = null;
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

      final url = await controller.getUrl();
      if (url != null) await _captureCookiesBestEffort(url);

      await FeedService.instance.submitFeedAuthPage(
        feedId: widget.feedId,
        currentUrl: currentUrl,
        response: html,
        // WebView does not expose successful main-frame response headers on
        // every platform. Re-fetching the URL here is unsafe for one-time
        // OAuth callbacks, so feeds should prefer page content and cookies.
        responseHeaders: const [],
        cookies: _capturedCookies.values.toList(growable: false),
      );

      if (!mounted) return;
      ref.invalidate(feedAuthStatusProvider(widget.feedId));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      if (!automatic) {
        setState(() {
          _submitError = e.toString();
        });
      }
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
        title: Text(_entry?.title ?? l10n.feedAuthPageTitle),
        actions: [
          TextButton(
            onPressed: _isSubmitting || _isLoadingEntry || _controller == null
                ? null
                : () => _submitPage(),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: LanghuanTheme.spaceMd),
                    FilledButton.icon(
                      onPressed: _loadEntry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.searchRetry),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (_isPageLoading)
                  LinearProgressIndicator(value: _pageProgress),
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LanghuanTheme.spaceMd,
                      vertical: LanghuanTheme.spaceSm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _isSubmitting ? Icons.sync : Icons.info_outline,
                          size: 18,
                        ),
                        const SizedBox(width: LanghuanTheme.spaceSm),
                        Expanded(
                          child: Text(
                            _isSubmitting
                                ? l10n.feedAuthVerifying
                                : l10n.feedAuthInstructions,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_submitError != null)
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LanghuanTheme.spaceMd,
                        vertical: LanghuanTheme.spaceSm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: LanghuanTheme.spaceSm),
                          Expanded(
                            child: Text(
                              _submitError!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(_entry!.url)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      thirdPartyCookiesEnabled: true,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      if (mounted) setState(() {});
                    },
                    onLoadStart: (_, _) {
                      if (!mounted) return;
                      setState(() {
                        _isPageLoading = true;
                        _pageProgress = 0;
                        _submitError = null;
                      });
                    },
                    onProgressChanged: (_, progress) {
                      if (!mounted) return;
                      setState(() {
                        _pageProgress = progress / 100;
                      });
                    },
                    onLoadStop: _onLoadStop,
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _onLoadStop(InAppWebViewController _, WebUri? url) async {
    if (mounted) {
      setState(() {
        _isPageLoading = false;
        _pageProgress = 1;
      });
    }
    if (url == null) return;

    await _captureCookiesBestEffort(url);
    if (!mounted) return;

    // The first page is the login form itself. Later main-frame loads usually
    // mean a form submission or OAuth redirect, so let the Feed extract and
    // verify auth automatically. A manual Verify action remains available for
    // single-page login flows that do not navigate.
    if (!_hasCompletedInitialLoad) {
      _hasCompletedInitialLoad = true;
      return;
    }
    await _submitPage(automatic: true);
  }

  Future<void> _captureCookies(WebUri url) async {
    final cookies = await CookieManager.instance().getCookies(url: url);
    for (final cookie in cookies) {
      final item = CookieEntry(
        name: cookie.name,
        value: cookie.value.toString(),
        domain: cookie.domain,
        path: cookie.path,
        expires: cookie.expiresDate?.toString(),
        secure: cookie.isSecure,
        httpOnly: cookie.isHttpOnly,
        sameSite: cookie.sameSite?.toNativeValue(),
      );
      final key = '${item.domain ?? url.host}|${item.path ?? '/'}|${item.name}';
      _capturedCookies[key] = item;
    }
  }

  Future<void> _captureCookiesBestEffort(WebUri url) async {
    try {
      await _captureCookies(url);
    } catch (_) {
      // HTML and URL based auth must still work on platforms that cannot
      // expose all WebView cookies.
    }
  }
}
