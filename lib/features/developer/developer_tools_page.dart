import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/errors.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/debug.dart';
import '../../src/rust/api/types.dart';
import '../feeds/feed_providers.dart';
import 'debug_trace_view.dart';
import 'debug_step_view.dart';
import 'developer_agent_server.dart';

/// Pipeline stages the runner can execute, mirroring the reading
/// pipeline's operations.
enum _StageKind { search, bookInfo, chapters, paragraphs, authStatus, manual }

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
  final _manualInputController = TextEditingController(
    text: '{\n  "keyword": ""\n}',
  );
  final _manualCursorController = TextEditingController(text: 'null');
  String _manualOperation = 'search';

  bool _running = false;
  bool _importing = false;
  bool _agentServerChanging = false;
  late final DeveloperAgentServer _agentServer;
  final List<_RunRecord> _history = [];
  _RunRecord? _selected;

  @override
  void initState() {
    super.initState();
    _agentServer = DeveloperAgentServer(
      currentScript: () => _scriptController.text,
    );
    _restoreScript();
  }

  @override
  void dispose() {
    unawaited(_agentServer.stop());
    _scriptController.dispose();
    _keywordController.dispose();
    _bookIdController.dispose();
    _chapterIdController.dispose();
    _manualInputController.dispose();
    _manualCursorController.dispose();
    super.dispose();
  }

  Future<void> _toggleAgentServer() async {
    if (_agentServerChanging) return;
    setState(() => _agentServerChanging = true);
    try {
      if (_agentServer.isRunning) {
        await _agentServer.stop();
      } else {
        await _agentServer.start();
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      showErrorSnack(ScaffoldMessenger.of(context), error.toString());
    } finally {
      if (mounted) setState(() => _agentServerChanging = false);
    }
  }

  Future<void> _showAgentApi() async {
    if (!_agentServer.isRunning) await _toggleAgentServer();
    if (!mounted || !_agentServer.isRunning) return;
    final uri = _agentServer.baseUri!;
    final token = _agentServer.token!;
    final command =
        "curl -s '${uri.resolve('/v1/run')}' "
        "-H 'Authorization: Bearer $token' "
        "-H 'Content-Type: application/json' "
        "--data '{\"operation\":\"search\",\"input\":{\"keyword\":\"test\"}}'";
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).devAgentApiTitle),
        content: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppLocalizations.of(context).devAgentApiHint),
              const SizedBox(height: LanghuanTheme.spaceMd),
              _AgentValue(
                label: AppLocalizations.of(context).devAgentEndpoint,
                value: uri.toString(),
              ),
              _AgentValue(
                label: AppLocalizations.of(context).devAgentToken,
                value: token,
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              SelectionArea(
                child: Text(
                  command,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              unawaited(_toggleAgentServer());
            },
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(AppLocalizations.of(context).devAgentStop),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(AppLocalizations.of(context).devAgentCopyCurl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).devClose),
          ),
        ],
      ),
    );
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
      showErrorSnack(ScaffoldMessenger.of(context), normalizeErrorMessage(e));
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
      showErrorSnack(ScaffoldMessenger.of(context), normalizeErrorMessage(e));
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
      case _StageKind.manual:
        return DebugStage.manual(
          operation: _manualOperation,
          inputJson: _manualInputController.text,
          cursorJson: _manualCursorController.text.trim().isEmpty
              ? 'null'
              : _manualCursorController.text,
        );
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
      case _StageKind.manual:
        return '$_manualOperation · cursor '
            '${_manualCursorController.text.trim().isEmpty ? 'null' : _manualCursorController.text.trim()}';
    }
  }

  void _setManualOperation(String operation) {
    const templates = {
      'search': '{\n  "keyword": ""\n}',
      'bookInfo': '{\n  "bookId": ""\n}',
      'chapters': '{\n  "bookId": ""\n}',
      'paragraphs': '{\n  "bookId": "",\n  "chapterId": ""\n}',
      'authStatus': '{}',
    };
    setState(() {
      _manualOperation = operation;
      _manualInputController.text = templates[operation] ?? '{}';
      _manualCursorController.text = 'null';
    });
  }

  void _useManualCursor(String cursor) {
    setState(() {
      _stage = _StageKind.manual;
      _manualCursorController.text = cursor;
    });
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
      appBar: AppBar(
        title: Text(l10n.devToolsTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: LanghuanTheme.spaceSm),
            child: TextButton.icon(
              onPressed: _agentServerChanging ? null : _showAgentApi,
              icon: _agentServerChanging
                  ? const LanghuanSpinner(size: 16)
                  : Icon(
                      Icons.smart_toy_outlined,
                      color: _agentServer.isRunning
                          ? theme.colorScheme.primary
                          : null,
                    ),
              label: Text(l10n.devAgentApi),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 1100) {
              return _DesktopWorkbench(
                scriptController: _scriptController,
                importing: _importing,
                onImport: _importFromInstalled,
                onClear: _clearScript,
                stage: _stage,
                onStageChanged: (stage) => setState(() => _stage = stage),
                keywordController: _keywordController,
                bookIdController: _bookIdController,
                chapterIdController: _chapterIdController,
                manualOperation: _manualOperation,
                onManualOperationChanged: _setManualOperation,
                manualInputController: _manualInputController,
                manualCursorController: _manualCursorController,
                running: _running,
                onRun: _run,
                selected: _selected,
                history: _history,
                onSelectHistory: (record) => setState(() => _selected = record),
                onChainToBookInfo: _chainToBookInfo,
                onChainToParagraphs: _chainToParagraphs,
                onUseManualCursor: _useManualCursor,
              );
            }
            return ListView(
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
                  manualOperation: _manualOperation,
                  onManualOperationChanged: _setManualOperation,
                  manualInputController: _manualInputController,
                  manualCursorController: _manualCursorController,
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
                    onUseManualCursor: _useManualCursor,
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
            );
          },
        ),
      ),
    );
  }
}

class _AgentValue extends StatelessWidget {
  const _AgentValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label)),
          Expanded(
            child: SelectionArea(
              child: Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop workbench: source, operation launcher, and inspector stay visible
/// at the same time so script authors do not lose context while comparing
/// reducer steps and HTTP traffic.
class _DesktopWorkbench extends StatelessWidget {
  const _DesktopWorkbench({
    required this.scriptController,
    required this.importing,
    required this.onImport,
    required this.onClear,
    required this.stage,
    required this.onStageChanged,
    required this.keywordController,
    required this.bookIdController,
    required this.chapterIdController,
    required this.manualOperation,
    required this.onManualOperationChanged,
    required this.manualInputController,
    required this.manualCursorController,
    required this.running,
    required this.onRun,
    required this.selected,
    required this.history,
    required this.onSelectHistory,
    required this.onChainToBookInfo,
    required this.onChainToParagraphs,
    required this.onUseManualCursor,
  });

  final TextEditingController scriptController;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onClear;
  final _StageKind stage;
  final ValueChanged<_StageKind> onStageChanged;
  final TextEditingController keywordController;
  final TextEditingController bookIdController;
  final TextEditingController chapterIdController;
  final String manualOperation;
  final ValueChanged<String> onManualOperationChanged;
  final TextEditingController manualInputController;
  final TextEditingController manualCursorController;
  final bool running;
  final VoidCallback onRun;
  final _RunRecord? selected;
  final List<_RunRecord> history;
  final ValueChanged<_RunRecord> onSelectHistory;
  final ValueChanged<String> onChainToBookInfo;
  final ValueChanged<String> onChainToParagraphs;
  final ValueChanged<String> onUseManualCursor;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('developer-desktop-workbench'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: KeyedSubtree(
            key: const ValueKey('developer-source-pane'),
            child: _DesktopScriptPane(
              controller: scriptController,
              importing: importing,
              onImport: onImport,
              onClear: onClear,
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          key: const ValueKey('developer-operation-pane'),
          width: 300,
          child: _DesktopOperationPane(
            stage: stage,
            onStageChanged: onStageChanged,
            keywordController: keywordController,
            bookIdController: bookIdController,
            chapterIdController: chapterIdController,
            manualOperation: manualOperation,
            onManualOperationChanged: onManualOperationChanged,
            manualInputController: manualInputController,
            manualCursorController: manualCursorController,
            running: running,
            onRun: onRun,
            history: history,
            selected: selected,
            onSelectHistory: onSelectHistory,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          key: const ValueKey('developer-inspector-pane'),
          flex: 5,
          child: selected == null
              ? Padding(
                  padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                  child: _EmptyHint(
                    l10n: AppLocalizations.of(context),
                    theme: Theme.of(context),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
                  children: [
                    _ResultSection(
                      record: selected!,
                      onChainToBookInfo: onChainToBookInfo,
                      onChainToParagraphs: onChainToParagraphs,
                      onUseManualCursor: onUseManualCursor,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _DesktopScriptPane extends StatelessWidget {
  const _DesktopScriptPane({
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
    return Padding(
      padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.code_rounded, size: 18),
              const SizedBox(width: LanghuanTheme.spaceSm),
              Text(l10n.devScriptLabel, style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: importing ? null : onImport,
                icon: importing
                    ? const LanghuanSpinner(size: 14)
                    : const Icon(Icons.download_rounded, size: 16),
                label: Text(l10n.devScriptImport),
              ),
              IconButton(
                tooltip: l10n.devScriptClear,
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          Text(
            l10n.devScriptHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LanghuanTheme.spaceSm),
          Expanded(
            child: TextField(
              controller: controller,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.45,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(LanghuanTheme.spaceMd),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopOperationPane extends StatelessWidget {
  const _DesktopOperationPane({
    required this.stage,
    required this.onStageChanged,
    required this.keywordController,
    required this.bookIdController,
    required this.chapterIdController,
    required this.manualOperation,
    required this.onManualOperationChanged,
    required this.manualInputController,
    required this.manualCursorController,
    required this.running,
    required this.onRun,
    required this.history,
    required this.selected,
    required this.onSelectHistory,
  });

  final _StageKind stage;
  final ValueChanged<_StageKind> onStageChanged;
  final TextEditingController keywordController;
  final TextEditingController bookIdController;
  final TextEditingController chapterIdController;
  final String manualOperation;
  final ValueChanged<String> onManualOperationChanged;
  final TextEditingController manualInputController;
  final TextEditingController manualCursorController;
  final bool running;
  final VoidCallback onRun;
  final List<_RunRecord> history;
  final _RunRecord? selected;
  final ValueChanged<_RunRecord> onSelectHistory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = _stageLabels(l10n);
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LanghuanTheme.spaceMd,
            LanghuanTheme.spaceLg,
            LanghuanTheme.spaceMd,
            LanghuanTheme.spaceSm,
          ),
          child: Text(
            l10n.debugOperations,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final entry in labels.entries)
          ListTile(
            dense: true,
            selected: stage == entry.key,
            leading: Icon(_stageIcon(entry.key), size: 19),
            title: Text(entry.value),
            onTap: () => onStageChanged(entry.key),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InputArea(
                stage: stage,
                keywordController: keywordController,
                bookIdController: bookIdController,
                chapterIdController: chapterIdController,
                manualOperation: manualOperation,
                onManualOperationChanged: onManualOperationChanged,
                manualInputController: manualInputController,
                manualCursorController: manualCursorController,
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              FilledButton.icon(
                onPressed: running ? null : onRun,
                icon: running
                    ? const LanghuanSpinner(size: 18)
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.debugRun),
              ),
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LanghuanTheme.spaceMd,
            vertical: LanghuanTheme.spaceSm,
          ),
          child: Text(
            l10n.debugHistoryTitle(history.length),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final record in history.reversed)
          ListTile(
            dense: true,
            selected: selected == record,
            leading: Icon(
              record.result.error == null
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              size: 18,
              color: record.result.error == null
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            title: Text(
              labels[record.stage]!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              record.inputSummary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text('${record.result.durationMs} ms'),
            onTap: () => onSelectHistory(record),
          ),
      ],
    );
  }
}

Map<_StageKind, String> _stageLabels(AppLocalizations l10n) => {
  _StageKind.search: l10n.debugStageSearch,
  _StageKind.bookInfo: l10n.debugStageBookInfo,
  _StageKind.chapters: l10n.debugStageChapters,
  _StageKind.paragraphs: l10n.debugStageParagraphs,
  _StageKind.authStatus: l10n.debugStageAuthStatus,
  _StageKind.manual: l10n.debugStageManual,
};

IconData _stageIcon(_StageKind stage) => switch (stage) {
  _StageKind.search => Icons.search_rounded,
  _StageKind.bookInfo => Icons.menu_book_outlined,
  _StageKind.chapters => Icons.format_list_numbered_rounded,
  _StageKind.paragraphs => Icons.subject_rounded,
  _StageKind.authStatus => Icons.key_rounded,
  _StageKind.manual => Icons.tune_rounded,
};

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
      _StageKind.manual: l10n.debugStageManual,
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
    required this.manualOperation,
    required this.onManualOperationChanged,
    required this.manualInputController,
    required this.manualCursorController,
  });

  final _StageKind stage;
  final TextEditingController keywordController;
  final TextEditingController bookIdController;
  final TextEditingController chapterIdController;
  final String manualOperation;
  final ValueChanged<String> onManualOperationChanged;
  final TextEditingController manualInputController;
  final TextEditingController manualCursorController;

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
      case _StageKind.manual:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: manualOperation,
              decoration: InputDecoration(
                labelText: l10n.debugManualOperation,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'search', child: Text('search')),
                DropdownMenuItem(value: 'bookInfo', child: Text('bookInfo')),
                DropdownMenuItem(value: 'chapters', child: Text('chapters')),
                DropdownMenuItem(
                  value: 'paragraphs',
                  child: Text('paragraphs'),
                ),
                DropdownMenuItem(
                  value: 'authStatus',
                  child: Text('authStatus'),
                ),
              ],
              onChanged: (value) {
                if (value != null) onManualOperationChanged(value);
              },
            ),
            const SizedBox(height: LanghuanTheme.spaceSm),
            TextField(
              controller: manualInputController,
              minLines: 3,
              maxLines: 8,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: l10n.debugManualInput,
                helperText: l10n.debugManualInputHint,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
                isDense: true,
              ),
            ),
            const SizedBox(height: LanghuanTheme.spaceSm),
            TextField(
              controller: manualCursorController,
              minLines: 1,
              maxLines: 4,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: l10n.debugManualCursor,
                helperText: l10n.debugManualCursorHint,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
                isDense: true,
              ),
            ),
          ],
        );
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
    required this.onUseManualCursor,
  });

  final _RunRecord record;
  final ValueChanged<String> onChainToBookInfo;
  final ValueChanged<String> onChainToParagraphs;
  final ValueChanged<String> onUseManualCursor;

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
            onUseManualCursor: onUseManualCursor,
          ),

        const SizedBox(height: LanghuanTheme.spaceLg),
        Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: LanghuanTheme.spaceSm),
            Text(
              l10n.debugStepTitle(result.steps.length),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: LanghuanTheme.spaceSm),
        DebugStepTraceView(entries: result.steps, dropped: result.droppedSteps),
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
    required this.onUseManualCursor,
  });

  final DebugStageOutput output;
  final ValueChanged<String> onChainToBookInfo;
  final ValueChanged<String> onChainToParagraphs;
  final ValueChanged<String> onUseManualCursor;

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
          DebugStageOutput_Manual(
            :final itemsJson,
            :final valueJson,
            :final nextCursorJson,
          ) =>
            _ManualOutput(
              itemsJson: itemsJson,
              valueJson: valueJson,
              nextCursorJson: nextCursorJson,
              onUseCursor: onUseManualCursor,
            ),
        },
      ],
    );
  }
}

class _ManualOutput extends StatelessWidget {
  const _ManualOutput({
    required this.itemsJson,
    required this.valueJson,
    required this.nextCursorJson,
    required this.onUseCursor,
  });

  final String? itemsJson;
  final String? valueJson;
  final String? nextCursorJson;
  final ValueChanged<String> onUseCursor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (itemsJson != null)
          _JsonResultBlock(label: 'items', value: itemsJson!),
        if (valueJson != null)
          _JsonResultBlock(label: 'value', value: valueJson!),
        if (nextCursorJson != null) ...[
          _JsonResultBlock(label: 'next_cursor', value: nextCursorJson!),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onUseCursor(nextCursorJson!),
              icon: const Icon(Icons.skip_next_rounded),
              label: Text(l10n.debugManualUseNextCursor),
            ),
          ),
        ] else
          Text(l10n.debugManualNoNextCursor),
      ],
    );
  }
}

class _JsonResultBlock extends StatelessWidget {
  const _JsonResultBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceSm),
      child: Container(
        padding: const EdgeInsets.all(LanghuanTheme.spaceSm),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: LanghuanTheme.borderRadiusSm,
        ),
        child: SelectionArea(
          child: Text(
            '$label\n$value',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ),
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
