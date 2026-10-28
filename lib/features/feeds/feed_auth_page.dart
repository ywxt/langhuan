import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/errors.dart';
import '../../shared/widgets/loading.dart';
import 'auth_webview.dart';
import 'feed_providers.dart';
import 'feed_service.dart';

/// Login flow for a feed that requires authentication.
///
/// The platform WebView lives behind [AuthWebviewSession]: an embedded view
/// on Android, iOS and macOS, a native browser window on Linux and Windows.
/// Verification is always manual — the user taps Verify, which collects the
/// current URL, the page HTML and the accumulated cookies and submits them
/// to the feed's auth parser.
class FeedAuthPage extends ConsumerStatefulWidget {
  const FeedAuthPage({super.key, required this.feedId});

  final String feedId;

  @override
  ConsumerState<FeedAuthPage> createState() => _FeedAuthPageState();
}

class _FeedAuthPageState extends ConsumerState<FeedAuthPage> {
  FeedAuthEntryModel? _entry;
  AuthWebviewSession? _session;
  bool _isLoadingEntry = true;
  String? _error;
  String? _submitError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEntry());
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _loadEntry() async {
    _session?.dispose();
    _session = null;
    setState(() {
      _isLoadingEntry = true;
      _error = null;
    });

    try {
      final entry = await ref
          .read(feedServiceProvider)
          .getFeedAuthEntry(widget.feedId);
      if (!mounted) return;

      if (entry == null) {
        final l10n = AppLocalizations.of(context);
        setState(() {
          _error = l10n.feedAuthNotSupported;
          _isLoadingEntry = false;
        });
        return;
      }

      final session = AuthWebviewSession.platform();
      session.addListener(_onSessionChanged);
      _entry = entry;
      _session = session;
      setState(() => _isLoadingEntry = false);
      await session.open(entry.url, title: entry.title);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = normalizeErrorMessage(e);
        _isLoadingEntry = false;
      });
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submitPage() async {
    final session = _session;
    if (session == null || !session.canVerify) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final snapshot = await session.snapshot();
      await ref
          .read(feedServiceProvider)
          .submitFeedAuthPage(
            feedId: widget.feedId,
            currentUrl: snapshot.currentUrl,
            response: snapshot.html,
            // Neither WebView flavor exposes main-frame response headers;
            // feeds parse auth from page content and cookies.
            responseHeaders: const [],
            cookies: snapshot.cookies,
          );

      if (!mounted) return;
      ref.invalidate(feedAuthStatusProvider(widget.feedId));
      await session.close();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = normalizeErrorMessage(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _reopenWindow() async {
    final entry = _entry;
    final session = _session;
    if (entry == null || session == null) return;
    try {
      await session.open(entry.url, title: entry.title);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = normalizeErrorMessage(e));
    }
  }

  bool get _canVerify =>
      !_isSubmitting && !_isLoadingEntry && (_session?.canVerify ?? false);

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = _session;

    return Scaffold(
      appBar: AppBar(
        title: Text(_entry?.title ?? l10n.feedAuthPageTitle),
        actions: [
          TextButton(
            onPressed: _canVerify ? _submitPage : null,
            child: _isSubmitting
                ? const LanghuanSpinner(size: 16)
                : Text(l10n.feedAuthDone),
          ),
          const SizedBox(width: LanghuanTheme.spaceSm),
        ],
      ),
      body: _isLoadingEntry
          ? const LoadingState()
          : _error != null
          ? _buildErrorState(l10n)
          : session!.usesSeparateWindow
          ? _buildWindowBody(l10n, session)
          : _buildInlineBody(l10n, session),
    );
  }

  Widget _buildErrorState(AppLocalizations l10n) {
    return Center(
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
    );
  }

  Widget _buildInlineBody(AppLocalizations l10n, AuthWebviewSession session) {
    return Column(
      children: [
        if (session.isPageLoading)
          LinearProgressIndicator(value: session.pageProgress),
        _buildInfoBanner(
          icon: _isSubmitting ? Icons.sync : Icons.info_outline,
          text: _isSubmitting
              ? l10n.feedAuthVerifying
              : l10n.feedAuthInstructions,
        ),
        if (_submitError != null) _buildSubmitError(),
        Expanded(child: session.view ?? const LoadingState()),
      ],
    );
  }

  Widget _buildWindowBody(AppLocalizations l10n, AuthWebviewSession session) {
    return Column(
      children: [
        _buildInfoBanner(
          icon: _isSubmitting ? Icons.sync : Icons.open_in_new,
          text: _isSubmitting
              ? l10n.feedAuthVerifying
              : l10n.feedAuthDesktopInstructions,
        ),
        if (_submitError != null) _buildSubmitError(),
        if (session.isWindowOpen)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                child: Text(
                  l10n.feedAuthDesktopWindowHint,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
            child: Column(
              children: [
                Icon(
                  Icons.desktop_windows_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: LanghuanTheme.spaceMd),
                Text(
                  session.isOpeningWindow ? '' : l10n.feedAuthWindowClosed,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: LanghuanTheme.spaceMd),
                OutlinedButton.icon(
                  onPressed: session.isOpeningWindow ? null : _reopenWindow,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l10n.feedAuthReopenWindow),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildInfoBanner({required IconData icon, required String text}) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceMd,
          vertical: LanghuanTheme.spaceSm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitError() {
    return Material(
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
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Expanded(
              child: Text(
                _submitError!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
