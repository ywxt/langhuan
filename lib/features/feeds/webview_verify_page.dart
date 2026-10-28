import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/errors.dart';
import '../../shared/widgets/loading.dart';
import 'auth_webview.dart';
import 'feed_service.dart';

/// Interactive verification page for a feed's `webview` reducer step.
///
/// The Rust side parks the originating operation (search, chapters, …)
/// until this page answers the prompt: tapping Done submits the page
/// snapshot — current URL, HTML and accumulated cookies — back to the
/// reducer, which retries with the fresh session. Leaving the page
/// cancels the operation instead.
class WebviewVerifyPage extends StatefulWidget {
  const WebviewVerifyPage({super.key, required this.prompt});

  final WebviewPromptModel prompt;

  @override
  State<WebviewVerifyPage> createState() => _WebviewVerifyPageState();
}

class _WebviewVerifyPageState extends State<WebviewVerifyPage> {
  AuthWebviewSession? _session;
  String? _error;
  String? _submitError;
  bool _isSubmitting = false;
  bool _canceled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final session = AuthWebviewSession.platform();
      session.addListener(_onSessionChanged);
      _session = session;
      if (mounted) setState(() {});
      await session.open(widget.prompt.url, title: widget.prompt.title);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = normalizeErrorMessage(e));
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submitPage() async {
    final session = _session;
    if (session == null || !session.canVerify || _canceled) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final snapshot = await session.snapshot();
      await FeedService.instance.completeWebview(
        requestId: widget.prompt.requestId,
        currentUrl: snapshot.currentUrl,
        html: snapshot.html,
        cookies: snapshot.cookies,
      );

      if (!mounted) return;
      await session.close();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitError = normalizeErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  /// Leaving the page without submitting cancels the parked operation.
  Future<void> _cancel() async {
    if (_canceled || _isSubmitting) return;
    _canceled = true;
    try {
      await FeedService.instance.cancelWebview(widget.prompt.requestId);
    } catch (_) {
      // The operation was already gone; nothing else to do.
    }
    _session?.close();
  }

  Future<void> _reopenWindow() async {
    final session = _session;
    if (session == null) return;
    try {
      await session.open(widget.prompt.url, title: widget.prompt.title);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = normalizeErrorMessage(e));
    }
  }

  bool get _canVerify =>
      !_isSubmitting && !_canceled && (_session?.canVerify ?? false);

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = _session;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_isSubmitting) return;
        await _cancel();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.prompt.title ?? l10n.webviewVerifyPageTitle),
          actions: [
            TextButton(
              onPressed: _canVerify ? _submitPage : null,
              child: _isSubmitting
                  ? const LanghuanSpinner(size: 16)
                  : Text(l10n.webviewVerifyDone),
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
          ],
        ),
        body: _error != null
            ? _buildErrorState(l10n)
            : session == null
            ? const LoadingState()
            : session.usesSeparateWindow
            ? _buildWindowBody(l10n, session)
            : _buildInlineBody(l10n, session),
      ),
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
              onPressed: _open,
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
          icon: _isSubmitting ? Icons.sync : Icons.verified_outlined,
          text: _isSubmitting
              ? l10n.webviewVerifySubmitting
              : l10n.webviewVerifyInstructions,
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
              ? l10n.webviewVerifySubmitting
              : l10n.webviewVerifyDesktopInstructions,
        ),
        if (_submitError != null) _buildSubmitError(),
        if (session.isWindowOpen)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                child: Text(
                  l10n.webviewVerifyDesktopWindowHint,
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
                  session.isOpeningWindow ? '' : l10n.webviewVerifyWindowClosed,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: LanghuanTheme.spaceMd),
                OutlinedButton.icon(
                  onPressed: session.isOpeningWindow ? null : _reopenWindow,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l10n.webviewVerifyReopenWindow),
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
