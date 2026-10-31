import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/errors.dart';

/// A live final page; controls and refresh feedback must never be snapshotted.
class ReaderEndPage extends StatefulWidget {
  const ReaderEndPage({
    super.key,
    this.onRefresh,
    required this.onReturnToText,
  });

  final Future<void> Function()? onRefresh;
  final VoidCallback onReturnToText;

  @override
  State<ReaderEndPage> createState() => _ReaderEndPageState();
}

class _ReaderEndPageState extends State<ReaderEndPage> {
  bool _refreshing = false;
  bool _checked = false;
  String? _error;

  Future<void> _refresh() async {
    if (_refreshing || widget.onRefresh == null) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await widget.onRefresh!();
      if (mounted) setState(() => _checked = true);
    } catch (error) {
      if (mounted) setState(() => _error = normalizeErrorMessage(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final message =
        _error ??
        (_refreshing
            ? l10n.readerEndChecking
            : _checked
            ? l10n.readerEndChecked
            : l10n.readerEndHint);

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(0, constraints.maxHeight - 64),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 40,
                              child: Divider(
                                color: colors.onSurface.withValues(alpha: 0.12),
                              ),
                            ),
                            Container(
                              width: 76,
                              height: 76,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              decoration: BoxDecoration(
                                color: colors.onSurface.withValues(
                                  alpha: 0.035,
                                ),
                                borderRadius: LanghuanTheme.borderRadiusLg,
                                border: Border.all(
                                  color: colors.onSurface.withValues(
                                    alpha: 0.08,
                                  ),
                                ),
                              ),
                              child: Icon(
                                Icons.auto_stories_outlined,
                                size: 32,
                                color: colors.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                            SizedBox(
                              width: 40,
                              child: Divider(
                                color: colors.onSurface.withValues(alpha: 0.12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        l10n.readerEndOfBook,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56),
                        child: Center(
                          heightFactor: 1,
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              message,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.7,
                                color: _error == null
                                    ? colors.onSurfaceVariant
                                    : colors.error,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        key: const ValueKey('reader-end-refresh'),
                        onPressed: _refreshing || widget.onRefresh == null
                            ? null
                            : _refresh,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          shape: const StadiumBorder(),
                        ),
                        icon: _refreshing
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colors.onPrimary,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 20),
                        label: Text(
                          _refreshing
                              ? l10n.readerEndChecking
                              : l10n.readerRefreshChapters,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        key: const ValueKey('reader-end-return'),
                        onPressed: widget.onReturnToText,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                        ),
                        icon: const Icon(Icons.arrow_back_rounded, size: 18),
                        label: Text(l10n.readerBackToText),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
