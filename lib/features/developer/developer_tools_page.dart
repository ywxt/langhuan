import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/debug.dart';
import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import 'debug_trace_view.dart';

/// Pipeline stages the runner can execute, mirroring the reading
/// pipeline's operations.
enum _StageKind { search, bookInfo, chapters, paragraphs, authStatus }

/// One executed debug run, kept for the in-session history.
class _RunRecord {
  _RunRecord({
    required this.stage,
    required this.inputSummary,
    required this.result,
  }) : time = DateTime.now();

  final _StageKind stage;
  final String inputSummary;
  final DateTime time;
  final DebugRunResult result;
}

/// The developer tools page: a standalone feed-script environment.
///
/// Scripts are pasted here (or imported read-only from an installed feed),
/// compiled and executed independently of the app's normal operation —
/// nothing runs against the installed registry and nothing a run does is
/// written back. The page runs one pipeline stage of the script with
/// arbitrary input, showing the typed output, the terminal error (if any),
/// and the recorded HTTP traffic side by side; results accumulate in an
/// in-memory history so a script author can compare runs before and after
/// an edit.
class DeveloperToolsPage extends ConsumerStatefulWidget {
  const DeveloperToolsPage({super.key});

  @override
  ConsumerState<DeveloperToolsPage> createState() => _DeveloperToolsPageState();
}

class _DeveloperToolsPageState extends ConsumerState<DeveloperToolsPage> {
  static const _kScriptKey = 'developer.script';

  _StageKind _stage = _StageKind.search;
  final _scriptController = TextEditingController();
  final _keywordController = TextEditingController();
  final _bookIdController = TextEditingController();
  final _chapterIdController = TextEditingController();

  bool _running = false;
  bool _importing = false;
  final List<_RunRecord> _history = [];
  _RunRecord? _selected;

  @override
  void initState() {
    super.initState();
    _restoreScript();
  }

  @override
  void dispose() {
    _scriptController.dispose();
    _keywordController.dispose();
    _bookIdController.dispose();
    _chapterIdController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Script source
  // -------------------------------------------------------------------------

  /// The editor's contents survive page visits (but not reinstalls) so a
  /// long work-in-progress script is not lost to a stray back navigation.
  Future<void> _restoreScript() async {
    final prefs = await SharedPreferences.getInstance();
    final script = prefs.getString(_kScriptKey);
    if (script != null &&
        script.isNotEmpty &&
        _scriptController.text.isEmpty &&
        mounted) {
      _scriptController.text = script;
    }
  }

  Future<void> _persistScript() async {
    final prefs = await SharedPreferences.getInstance();
    final script = _scriptController.text;
    if (script.isEmpty) {
      await prefs.remove(_kScriptKey);
    } else {
      await prefs.setString(_kScriptKey, script);
    }
  }

  Future<void> _importFromInstalled() async {
    if (_importing) return;
    final l10n = AppLocalizations.of(context);
    final feeds = ref.read(feedListProvider).items;
    if (feeds.isEmpty) {
      showErrorSnack(ScaffoldMessenger.of(context), l10n.devScriptImportEmpty);
      return;
    }

    final feedId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                0,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceSm,
              ),
              child: Text(
                l10n.devScriptImportTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final feed in feeds)
              ListTile(
                title: Text(feed.name, maxLines: 1),
                subtitle: Text('v${feed.version}', maxLines: 1),
                trailing: Text(
                  feed.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () => Navigator.pop(context, feed.id),
              ),
          ],
        ),
      ),
    );
    if (feedId == null || !mounted) return;
    final feedName = feeds.where((f) => f.id == feedId).first.name;

    setState(() => _importing = true);
    try {
      final script = await debugGetInstalledScript(feedId: feedId);
      if (!mounted) return;
      _scriptController.text = script;
      final messenger = ScaffoldMessenger.of(context);
      final message = AppLocalizations.of(context).devScriptImported(feedName);
      await _persistScript();
      showSuccessSnack(messenger, message);
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _clearScript() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.devScriptClearConfirmTitle,
      message: l10n.devScriptClearConfirmMessage,
      confirmLabel: l10n.devScriptClear,
    );
    if (!confirmed || !mounted) return;
    _scriptController.clear();
    await _persistScript();
  }

  // -------------------------------------------------------------------------
  // Running
  // -------------------------------------------------------------------------

  Future<void> _run() async {
    if (_running) return;
    final l10n = AppLocalizations.of(context);
    final script = _scriptController.text.trim();
    if (script.isEmpty) {
      showErrorSnack(ScaffoldMessenger.of(context), l10n.devScriptMissing);
      return;
    }
    final stage = _buildStage();
    if (stage == null) return;

    // Keep the editor's contents across restarts before anything can go
    // wrong with the run itself.
    unawaited(_persistScript());
    setState(() => _running = true);
    try {
      final result = await debugRunStage(script: script, stage: stage);
      if (!mounted) return;
      setState(() {
        _history.add(
          _RunRecord(
            stage: _stage,
            inputSummary: _inputSummary(),
            result: result,
          ),
        );
        _selected = _history.last;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Builds the bridge stage from the input fields; `null` (after telling
  /// the user) when a required input is empty.
  DebugStage? _buildStage() {
    final l10n = AppLocalizations.of(context);
    switch (_stage) {
      case _StageKind.search:
        final keyword = _keywordController.text.trim();
        if (keyword.isEmpty) {
          showErrorSnack(
            ScaffoldMessenger.of(context),
            l10n.debugInputMissing(l10n.debugInputKeyword),
          );
          return null;
        }
        return DebugStage.search(keyword: keyword);
      case _StageKind.bookInfo:
        final bookId = _bookIdController.text.trim();
        if (bookId.isEmpty) {
          showErrorSnack(
            ScaffoldMessenger.of(context),
            l10n.debugInputMissing(l10n.debugInputBookId),
          );
          return null;
        }
        return DebugStage.bookInfo(bookId: bookId);
      case _StageKind.chapters:
        final bookId = _bookIdController.text.trim();
        if (bookId.isEmpty) {
          showErrorSnack(
            ScaffoldMessenger.of(context),
            l10n.debugInputMissing(l10n.debugInputBookId),
          );
          return null;
        }
        return DebugStage.chapters(bookId: bookId);
      case _StageKind.paragraphs:
        final bookId = _bookIdController.text.trim();
        final chapterId = _chapterIdController.text.trim();
        if (bookId.isEmpty) {
          showErrorSnack(
            ScaffoldMessenger.of(context),
            l10n.debugInputMissing(l10n.debugInputBookId),
          );
          return null;
        }
        if (chapterId.isEmpty) {
          showErrorSnack(
            ScaffoldMessenger.of(context),
            l10n.debugInputMissing(l10n.debugInputChapterId),
          );
          return null;
        }
        return DebugStage.paragraphs(bookId: bookId, chapterId: chapterId);
      case _StageKind.authStatus:
        return const DebugStage.authStatus();
    }
  }

  String _inputSummary() {
    switch (_stage) {
      case _StageKind.search:
        return _keywordController.text.trim();
      case _StageKind.bookInfo || _StageKind.chapters:
        return _bookIdController.text.trim();
      case _StageKind.paragraphs:
        return '${_bookIdController.text.trim()} · '
            '${_chapterIdController.text.trim()}';
      case _StageKind.authStatus:
        return '';
    }
  }

  // -------------------------------------------------------------------------
  // Chain mode: carry a result id into the next stage's input
  // -------------------------------------------------------------------------

  void _chainToBookInfo(String bookId) {
    setState(() {
      _stage = _StageKind.bookInfo;
      _bookIdController.text = bookId;
    });
  }

  void _chainToParagraphs(String chapterId) {
    setState(() {
      _stage = _StageKind.paragraphs;
      _chapterIdController.text = chapterId;
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.devToolsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            LanghuanTheme.spaceLg,
            LanghuanTheme.spaceMd,
            LanghuanTheme.spaceLg,
            LanghuanTheme.spaceXl,
          ),
          children: [
            _ScriptSection(
              controller: _scriptController,
              importing: _importing,
              onImport: _importFromInstalled,
              onClear: _clearScript,
            ),
            const SizedBox(height: LanghuanTheme.spaceLg),
            _StageSelector(
              stage: _stage,
              onChanged: (stage) => setState(() => _stage = stage),
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            _InputArea(
              stage: _stage,
              keywordController: _keywordController,
              bookIdController: _bookIdController,
              chapterIdController: _chapterIdController,
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const LanghuanSpinner(size: 18)
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.debugRun),
            ),
            const SizedBox(height: LanghuanTheme.spaceLg),
            if (_selected != null)
              _ResultSection(
                record: _selected!,
                onChainToBookInfo: _chainToBookInfo,
                onChainToParagraphs: _chainToParagraphs,
              )
            else
              _EmptyHint(l10n: l10n, theme: theme),
            if (_history.length > 1) ...[
              const SizedBox(height: LanghuanTheme.spaceLg),
              _HistorySection(
                history: _history,
                selected: _selected,
                onSelect: (record) => setState(() => _selected = record),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Script source editor
// ---------------------------------------------------------------------------

class _ScriptSection extends StatelessWidget {
  const _ScriptSection({
    required this.controller,
    required this.importing,
    required this.onImport,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.code_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Text(
              l10n.devScriptLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: importing ? null : onImport,
              icon: importing
                  ? const LanghuanSpinner(size: 14)
                  : const Icon(Icons.download_rounded, size: 16),
              label: Text(l10n.devScriptImport),
            ),
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: Text(l10n.devScriptClear),
            ),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceXs),
        Text(
          l10n.devScriptHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: LanghuanTheme.spaceSm),
        TextField(
          controller: controller,
          minLines: 6,
          maxLines: 14,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stage selection + inputs
// ---------------------------------------------------------------------------

class _StageSelector extends StatelessWidget {
  const _StageSelector({required this.stage, required this.onChanged});

  final _StageKind stage;
  final ValueChanged<_StageKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = {
      _StageKind.search: l10n.debugStageSearch,
      _StageKind.bookInfo: l10n.debugStageBookInfo,
      _StageKind.chapters: l10n.debugStageChapters,
      _StageKind.paragraphs: l10n.debugStageParagraphs,
      _StageKind.authStatus: l10n.debugStageAuthStatus,
    };

    return Wrap(
      spacing: LanghuanTheme.spaceSm,
      runSpacing: LanghuanTheme.spaceSm,
      children: [
        for (final entry in labels.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: stage == entry.key,
            onSelected: (_) => onChanged(entry.key),
          ),
      ],
    );
  }
}

class _InputArea extends StatelessWidget {
  const _InputArea({
    required this.stage,
    required this.keywordController,
    required this.bookIdController,
    required this.chapterIdController,
  });

  final _StageKind stage;
  final TextEditingController keywordController;
  final TextEditingController bookIdController;
  final TextEditingController chapterIdController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (stage) {
      case _StageKind.search:
        return TextField(
          controller: keywordController,
          decoration: InputDecoration(
            labelText: l10n.debugInputKeyword,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        );
      case _StageKind.bookInfo || _StageKind.chapters:
        return TextField(
          controller: bookIdController,
          decoration: InputDecoration(
            labelText: l10n.debugInputBookId,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        );
      case _StageKind.paragraphs:
        return Column(
          children: [
            TextField(
              controller: bookIdController,
              decoration: InputDecoration(
                labelText: l10n.debugInputBookId,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceSm),
            TextField(
              controller: chapterIdController,
              decoration: InputDecoration(
                labelText: l10n.debugInputChapterId,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        );
      case _StageKind.authStatus:
        return const SizedBox.shrink();
    }
  }
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.record,
    required this.onChainToBookInfo,
    required this.onChainToParagraphs,
  });

  final _RunRecord record;
  final ValueChanged<String> onChainToBookInfo;
  final ValueChanged<String> onChainToParagraphs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final result = record.result;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Summary ──
        Wrap(
          spacing: LanghuanTheme.spaceSm,
          runSpacing: LanghuanTheme.spaceSm,
          children: [
            if (result.error != null)
              _SummaryChip(
                color: theme.colorScheme.error,
                label: l10n.debugSummaryFailed,
              )
            else
              _SummaryChip(
                color: theme.colorScheme.primary,
                label: l10n.debugSummaryOk,
              ),
            _SummaryChip(
              color: theme.colorScheme.onSurfaceVariant,
              label: l10n.debugDurationMs(result.durationMs),
            ),
            if (result.scriptMeta != null)
              _SummaryChip(
                color: theme.colorScheme.onSurfaceVariant,
                label:
                    '${result.scriptMeta!.name} ${result.scriptMeta!.version}',
              ),
            _AuthChip(auth: result.auth),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceMd),

        // ── Error ──
        if (result.error != null) ...[
          _ErrorCard(error: result.error!),
          const SizedBox(height: LanghuanTheme.spaceMd),
        ],

        // ── Output ──
        if (result.output != null)
          _OutputView(
            output: result.output!,
            onChainToBookInfo: onChainToBookInfo,
            onChainToParagraphs: onChainToParagraphs,
          ),

        const SizedBox(height: LanghuanTheme.spaceLg),
        DebugTraceSection(
          entries: result.trace,
          dropped: result.droppedEntries,
        ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// How the run handled auth: reused stored login, none stored, or a
/// script without a login block.
class _AuthChip extends StatelessWidget {
  const _AuthChip({required this.auth});

  final DebugAuthUse auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (auth) {
      DebugAuthUse.applied => (l10n.devAuthApplied, theme.colorScheme.primary),
      DebugAuthUse.missing => (l10n.devAuthMissing, theme.colorScheme.tertiary),
      DebugAuthUse.notSupported => (
        l10n.devAuthNotSupported,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    return _SummaryChip(color: color, label: label);
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.l10n, required this.theme});

  final AppLocalizations l10n;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Text(
        l10n.debugEmptyHint,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The error is data here, not control flow: a debug run displays it
/// alongside whatever the stage produced before failing.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final BridgeError error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: LanghuanTheme.spaceSm),
              Text(
                l10n.debugErrorTitle,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: LanghuanTheme.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onErrorContainer.withValues(
                    alpha: 0.12,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _errorKindLabel(error.kind),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: LanghuanTheme.spaceSm),
          SelectionArea(
            child: Text(
              _detailText(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// An anticipated script error reports only what the script itself said
  /// — the classification lives in the chip above. Everything unexpected
  /// carries the full localized message.
  String _detailText() {
    final detail = error.detail;
    if (detail != null && detail.isNotEmpty) return detail;
    return error.message;
  }

  /// Error kinds are a technical classification aimed at script authors —
  /// the raw identifier is more useful than a translated phrase.
  String _errorKindLabel(ErrorKind kind) => switch (kind) {
    ErrorKind_Internal() => 'Internal',
    ErrorKind_Network() => 'Network',
    ErrorKind_ScriptRuntime() => 'ScriptRuntime',
    ErrorKind_ScriptConfig() => 'ScriptConfig',
    ErrorKind_ScriptExpected(:final reason) =>
      'ScriptExpected.${_reasonLabel(reason)}',
    ErrorKind_Storage() => 'Storage',
    ErrorKind_Registry() => 'Registry',
  };

  /// Known reasons map to their identifier; a script's custom code is its
  /// own classification.
  String _reasonLabel(ScriptExpectedReason reason) => switch (reason) {
    ScriptExpectedReason_AuthRequired() => 'authRequired',
    ScriptExpectedReason_CfChallenge() => 'cfChallenge',
    ScriptExpectedReason_RateLimited() => 'rateLimited',
    ScriptExpectedReason_ContentNotFound() => 'contentNotFound',
    ScriptExpectedReason_SourceUnavailable() => 'sourceUnavailable',
    ScriptExpectedReason_Other(:final code) => code,
  };
}

// ---------------------------------------------------------------------------
// Typed output views
// ---------------------------------------------------------------------------

class _OutputView extends StatelessWidget {
  const _OutputView({
    required this.output,
    required this.onChainToBookInfo,
    required this.onChainToParagraphs,
  });

  final DebugStageOutput output;
  final ValueChanged<String> onChainToBookInfo;
  final ValueChanged<String> onChainToParagraphs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.data_object_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Text(
              l10n.debugOutputTitle,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceSm),
        switch (output) {
          DebugStageOutput_Search(:final items) => _SearchOutput(
            items: items,
            onChainToBookInfo: onChainToBookInfo,
          ),
          DebugStageOutput_BookInfo(:final info) => _BookInfoOutput(info: info),
          DebugStageOutput_Chapters(:final items) => _ChaptersOutput(
            items: items,
            onChainToParagraphs: onChainToParagraphs,
          ),
          DebugStageOutput_Paragraphs(:final items) => _ParagraphsOutput(
            items: items,
          ),
          DebugStageOutput_AuthStatus(:final status) => _AuthStatusOutput(
            status: status,
          ),
        },
      ],
    );
  }
}

class _SearchOutput extends StatelessWidget {
  const _SearchOutput({required this.items, required this.onChainToBookInfo});

  final List<SearchResultItem> items;
  final ValueChanged<String> onChainToBookInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (items.isEmpty) {
      return Text(
        l10n.debugResultEmpty,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Column(
      children: [
        for (final item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${item.author} · ${item.id}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton.icon(
              onPressed: () => onChainToBookInfo(item.id),
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: Text(l10n.debugChainBookInfo),
            ),
          ),
      ],
    );
  }
}

class _BookInfoOutput extends StatelessWidget {
  const _BookInfoOutput({required this.info});

  final BookInfo info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        _FieldRow(label: l10n.debugFieldId, value: info.id),
        _FieldRow(label: l10n.debugFieldTitle, value: info.title),
        _FieldRow(label: l10n.debugFieldAuthor, value: info.author),
        if (info.coverUrl != null)
          _FieldRow(label: l10n.debugFieldCover, value: info.coverUrl!),
        if (info.description != null)
          _FieldRow(
            label: l10n.debugFieldDescription,
            value: info.description!,
          ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChaptersOutput extends StatelessWidget {
  const _ChaptersOutput({
    required this.items,
    required this.onChainToParagraphs,
  });

  final List<ChapterItem> items;
  final ValueChanged<String> onChainToParagraphs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (items.isEmpty) {
      return Text(
        l10n.debugResultEmpty,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Column(
      children: [
        for (final (index, chapter) in items.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Text(
              '${index + 1}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            title: Text(
              chapter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton.icon(
              onPressed: () => onChainToParagraphs(chapter.id),
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: Text(l10n.debugChainParagraphs),
            ),
          ),
      ],
    );
  }
}

class _ParagraphsOutput extends StatelessWidget {
  const _ParagraphsOutput({required this.items});

  final List<ParagraphContent> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    if (items.isEmpty) {
      return Text(
        l10n.debugResultEmpty,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final paragraph in items)
              switch (paragraph) {
                ParagraphContent_Title(:final text) => Padding(
                  padding: const EdgeInsets.only(
                    top: LanghuanTheme.spaceSm,
                    bottom: LanghuanTheme.spaceXs,
                  ),
                  child: Text(text, style: theme.textTheme.titleMedium),
                ),
                ParagraphContent_Text(:final content) => Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: LanghuanTheme.spaceXs,
                  ),
                  child: Text(
                    content,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
                ParagraphContent_Image(:final url, :final alt) => Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: LanghuanTheme.spaceXs,
                  ),
                  child: Text(
                    alt != null && alt.isNotEmpty
                        ? '[${l10n.debugImageParagraph}] $url ($alt)'
                        : '[${l10n.debugImageParagraph}] $url',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ),
              },
          ],
        ),
      ),
    );
  }
}

class _AuthStatusOutput extends StatelessWidget {
  const _AuthStatusOutput({required this.status});

  final AuthStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final (label, color) = switch (status) {
      AuthStatus.loggedIn => (
        l10n.feedAuthStatusLoggedIn,
        theme.colorScheme.primary,
      ),
      AuthStatus.expired => (
        l10n.feedAuthStatusExpired,
        theme.colorScheme.tertiary,
      ),
      AuthStatus.loggedOut => (
        l10n.feedAuthStatusLoggedOut,
        theme.colorScheme.onSurfaceVariant,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LanghuanTheme.spaceMd,
        vertical: LanghuanTheme.spaceSm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: LanghuanTheme.borderRadiusSm,
      ),
      child: Text(
        label,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.history,
    required this.selected,
    required this.onSelect,
  });

  final List<_RunRecord> history;
  final _RunRecord? selected;
  final ValueChanged<_RunRecord> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final labels = {
      _StageKind.search: l10n.debugStageSearch,
      _StageKind.bookInfo: l10n.debugStageBookInfo,
      _StageKind.chapters: l10n.debugStageChapters,
      _StageKind.paragraphs: l10n.debugStageParagraphs,
      _StageKind.authStatus: l10n.debugStageAuthStatus,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.history_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Text(
              l10n.debugHistoryTitle(history.length),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceSm),
        // Newest first; tapping a row brings that run's result back up.
        for (final record in history.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            selected: selected == record,
            leading: Icon(
              record.result.error == null
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              size: 18,
              color: record.result.error == null
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            title: Text(
              record.inputSummary.isEmpty
                  ? labels[record.stage]!
                  : '${labels[record.stage]} · ${record.inputSummary}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _formatTime(record.time),
              style: theme.textTheme.bodySmall,
            ),
            trailing: Text(
              l10n.debugDurationMs(record.result.durationMs),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => onSelect(record),
          ),
      ],
    );
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
