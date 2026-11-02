import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/snackbars.dart';
import '../script_formatter.dart';

/// Human-readable size for a script of [bytes] UTF-8 bytes.
String formatScriptSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  }
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// Full-screen viewer for a feed script awaiting installation.
///
/// The security warning asks the user to trust a source; this page lets
/// them verify it instead — the exact text rendered here is what a
/// confirm-install persists and runs. The script stays selectable and
/// copyable, search highlights every live match (risky patterns like
/// domains, storage or credential handling are easy to spot), a soft-wrap
/// toggle keeps long lines readable, and a formatted view reindents
/// minified scripts (clearly labeled: copy always yields the untouched
/// original, so what leaves this page is exactly what installs).
class ScriptAuditPage extends StatefulWidget {
  const ScriptAuditPage({
    super.key,
    required this.script,
    required this.name,
    required this.version,
  });

  final String script;
  final String name;
  final String version;

  @override
  State<ScriptAuditPage> createState() => _ScriptAuditPageState();
}

class _ScriptAuditPageState extends State<ScriptAuditPage> {
  static const _monoStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.5,
  );

  /// Guard against pathological match counts (a one-character query over
  /// a huge minified script) flooding the span tree.
  static const _matchCap = 2000;

  final _searchController = TextEditingController();
  late final int _byteLength = utf8.encode(widget.script).length;
  String _query = '';
  bool _wrap = true;
  bool _formatted = false;
  String? _formattedCache;

  /// The text currently on screen: the raw script, or its clearly labeled
  /// reindented reading view. Copy always yields [ScriptAuditPage.script].
  String get _display => _formatted
      ? (_formattedCache ??= formatJavaScript(widget.script))
      : widget.script;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.script));
    showSuccessSnack(
      ScaffoldMessenger.of(context),
      AppLocalizations.of(context).addFeedAuditCopied,
    );
  }

  /// Character ranges of every case-insensitive query match, capped at
  /// [_matchCap].
  ///
  /// Lowercasing can change a few code points' length, which would
  /// misalign offsets; those rare scripts fall back to a case-sensitive
  /// scan so the highlights always point at real text.
  List<(int, int)> _matches() {
    final query = _query.trim();
    final display = _display;
    if (query.length < 2 || query.length > display.length) {
      return const [];
    }
    final haystack = display.toLowerCase();
    final needle = query.toLowerCase();
    final caseInsensitive = haystack.length == display.length;
    final text = caseInsensitive ? haystack : display;
    final target = caseInsensitive ? needle : query;
    final result = <(int, int)>[];
    var start = 0;
    while (result.length < _matchCap) {
      final index = text.indexOf(target, start);
      if (index < 0) break;
      result.add((index, index + target.length));
      start = index + target.length;
    }
    return result;
  }

  TextSpan _highlightedText(ColorScheme colors) {
    final text = _display;
    final matches = _matches();
    if (matches.isEmpty) {
      return TextSpan(text: text);
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in matches) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor: colors.primaryContainer,
            color: colors.onPrimaryContainer,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(children: spans);
  }

  Widget? _searchResultLabel(AppLocalizations l10n) {
    if (_query.trim().length < 2) return null;
    final count = _matches().length;
    return Padding(
      padding: const EdgeInsets.only(right: LanghuanTheme.spaceMd),
      child: Center(
        child: Text(
          count == 0
              ? l10n.addFeedAuditNoMatch
              : l10n.addFeedAuditMatchCount(count),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: count == 0 ? null : Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final lines = widget.script.isEmpty
        ? 0
        : '\n'.allMatches(widget.script).length + 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addFeedAuditTitle),
        actions: [
          IconButton(
            tooltip: l10n.addFeedAuditFormat,
            isSelected: _formatted,
            icon: const Icon(Icons.format_align_left_rounded),
            onPressed: () => setState(() => _formatted = !_formatted),
          ),
          IconButton(
            tooltip: l10n.addFeedAuditWrap,
            isSelected: _wrap,
            icon: const Icon(Icons.wrap_text_rounded),
            onPressed: () => setState(() => _wrap = !_wrap),
          ),
          IconButton(
            tooltip: l10n.addFeedAuditCopy,
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copy,
          ),
        ],
      ),
      body: widget.script.isEmpty
          ? Center(
              child: Text(
                l10n.addFeedAuditEmpty,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── What is being audited, and how big it is ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LanghuanTheme.spaceMd,
                    LanghuanTheme.spaceSm,
                    LanghuanTheme.spaceMd,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${widget.name} v${widget.version}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: LanghuanTheme.spaceSm),
                      Text(
                        l10n.addFeedAuditStats(
                          formatScriptSize(_byteLength),
                          lines,
                        ),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // ── Formatted-view disclaimer ──
                // The stats always describe the install payload (the
                // original script); the note explains what the formatted
                // view is so the two cannot be confused.
                if (_formatted)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LanghuanTheme.spaceMd,
                      LanghuanTheme.spaceXs,
                      LanghuanTheme.spaceMd,
                      0,
                    ),
                    child: Text(
                      l10n.addFeedAuditFormattedNote,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                // ── Live search ──
                Padding(
                  padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: l10n.addFeedAuditSearchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                      suffix: _searchResultLabel(l10n),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                // ── The script itself ──
                Expanded(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        LanghuanTheme.spaceMd,
                        0,
                        LanghuanTheme.spaceMd,
                        LanghuanTheme.space2xl,
                      ),
                      child: _wrap
                          ? Text.rich(
                              _highlightedText(colors),
                              style: _monoStyle,
                            )
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text.rich(
                                _highlightedText(colors),
                                style: _monoStyle,
                                softWrap: false,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
