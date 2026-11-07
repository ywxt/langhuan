import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/constants.dart';
import '../../shared/utils/delete_with_undo.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/swipe_action_card.dart';
import '../../src/rust/api/types.dart';
import 'transformer_rule_card.dart';
import 'transformer_rule_editor_sheet.dart';
import 'transformer_settings.dart';

Future<void> openTransformerSettings(
  BuildContext context, {
  String? feedId,
  String? bookId,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => TransformerSettingsPage(feedId: feedId, bookId: bookId),
  ),
);

class TransformerSettingsPage extends ConsumerStatefulWidget {
  const TransformerSettingsPage({super.key, this.feedId, this.bookId})
    : assert((feedId == null) == (bookId == null));
  final String? feedId, bookId;
  @override
  ConsumerState<TransformerSettingsPage> createState() =>
      _TransformerSettingsPageState();
}

class _TransformerSettingsPageState
    extends ConsumerState<TransformerSettingsPage> {
  bool _saving = false;
  String? _error;
  ({TransformerEntry rule, bool application})? _pendingDelete;
  bool get _busy => _saving || _pendingDelete != null;
  bool get _book => widget.feedId != null;

  List<TransformerEntry> _rules(
    TransformerSettings value, {
    bool application = false,
  }) => _book && !application
      ? value.book(widget.feedId!, widget.bookId!).rules
      : value.application;

  Future<void> _saveRule(
    TransformerEntry rule,
    TransformerEditAction action, {
    int? index,
    bool application = false,
  }) async {
    final current = await ref.read(transformerSettingsProvider.future);
    final rules = List.of(_rules(current, application: application));
    if (index == null) {
      rules.add(rule);
    } else if (action == TransformerEditAction.delete) {
      rules.removeAt(index);
    } else {
      rules[index] = rule;
    }
    final bookScope = _book && !application;
    await ref
        .read(transformerSettingsProvider.notifier)
        .save(
          rules: rules,
          feedId: bookScope ? widget.feedId : null,
          bookId: bookScope ? widget.bookId : null,
          inheritApplication: bookScope
              ? current.book(widget.feedId!, widget.bookId!).inheritApplication
              : true,
        );
  }

  Future<void> _reorder(int from, int to, {bool application = false}) async {
    if (_busy || from == to) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = await ref.read(transformerSettingsProvider.future);
      final rules = List.of(_rules(current, application: application));
      rules.insert(to, rules.removeAt(from));
      final bookScope = _book && !application;
      await ref
          .read(transformerSettingsProvider.notifier)
          .save(
            rules: rules,
            feedId: bookScope ? widget.feedId : null,
            bookId: bookScope ? widget.bookId : null,
            inheritApplication: bookScope
                ? current
                      .book(widget.feedId!, widget.bookId!)
                      .inheritApplication
                : true,
          );
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is BridgeError ? error.message : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(
    TransformerEntry rule, {
    required bool application,
  }) async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l.transformRemoveTitle,
      message: l.transformRemoveMessage,
      note: _book && application ? l.transformApplicationEditHint : null,
      confirmLabel: l.bookshelfDeleteConfirm,
      cancelLabel: l.bookshelfDeleteCancel,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _pendingDelete = (rule: rule, application: application);
      _error = null;
    });
    try {
      final undone = await deleteWithUndo(
        messenger: messenger,
        message: l.transformDeleteQueued(
          rule.name.trim().isEmpty
              ? transformerLabel(l, rule.kind)
              : rule.name.trim(),
        ),
        undoLabel: l.transformUndo,
        duration: AppConstants.undoDuration,
      );
      if (undone || !mounted) return;
      final current = await ref.read(transformerSettingsProvider.future);
      final index = _rules(current, application: application).indexOf(rule);
      // The list may have been refreshed while undo was available. Never
      // delete a different rule at the previously captured index.
      if (index < 0) return;
      await _saveRule(
        rule,
        TransformerEditAction.delete,
        index: index,
        application: application,
      );
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is BridgeError ? error.message : error.toString(),
        );
      }
    } finally {
      messenger.clearSnackBars();
      if (mounted) setState(() => _pendingDelete = null);
    }
  }

  Widget _ruleList(List<TransformerEntry> rules, {bool application = false}) {
    final visible = rules.indexed
        .where(
          (entry) =>
              _pendingDelete?.application != application ||
              !identical(_pendingDelete?.rule, entry.$2),
        )
        .toList();
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: visible.length,
      onReorderItem: (from, to) => _reorder(from, to, application: application),
      itemBuilder: (context, index) {
        final (originalIndex, rule) = visible[index];
        return Padding(
          key: ObjectKey(rule),
          padding: const EdgeInsets.only(bottom: 12),
          child: SwipeActionCard(
            dismissKey: ObjectKey(rule),
            deleteTooltip: AppLocalizations.of(context).bookshelfDeleteConfirm,
            enabled: !_busy,
            confirmDismiss: (_) async {
              await _delete(rule, application: application);
              return false;
            },
            child: TransformerRuleCard(
              rule: rule,
              margin: EdgeInsets.zero,
              borderRadius: BorderRadius.zero,
              onTap: _busy
                  ? null
                  : () => _edit(index: originalIndex, application: application),
              dragHandle: ReorderableDragStartListener(
                index: index,
                enabled: !_busy,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Tooltip(
                    message: AppLocalizations.of(context).transformReorder,
                    child: const Icon(Icons.drag_handle),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _edit({
    int? index,
    bool application = false,
    TransformerKind? kind,
  }) async {
    final current = ref.read(transformerSettingsProvider).requireValue;
    final rules = _rules(current, application: application);
    final initial = index == null
        ? TransformerEntry(
            kind: kind!,
            mode: kind == TransformerKind.chineseConversion
                ? ChineseConversionMode.s2T
                : ChineseConversionMode.none,
          )
        : rules[index];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => TransformerRuleEditorSheet(
        initial: initial,
        existing: index != null,
        applicationFromBook: _book && application,
        onSave: (rule, action) =>
            _saveRule(rule, action, index: index, application: application),
      ),
    );
  }

  Future<void> _add() async {
    final l = AppLocalizations.of(context);
    final kind = await showModalBottomSheet<TransformerKind>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l.transformAdd,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final kind in TransformerKind.values)
                ListTile(
                  leading: Icon(transformerIcon(kind)),
                  title: Text(transformerLabel(l, kind)),
                  subtitle: Text(transformerDescription(l, kind)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, kind),
                ),
            ],
          ),
        ),
      ),
    );
    if (kind != null && mounted) await _edit(kind: kind);
  }

  Future<void> _setInheritance(bool inherit) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = await ref.read(transformerSettingsProvider.future);
      await ref
          .read(transformerSettingsProvider.notifier)
          .save(
            rules: _rules(current),
            feedId: widget.feedId,
            bookId: widget.bookId,
            inheritApplication: inherit,
          );
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is BridgeError ? error.message : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(transformerSettingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_book ? l.transformBookSettings : l.transformTitle),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l.transformAdd,
        onPressed: settings.hasValue && !_busy ? _add : null,
        child: const Icon(Icons.add),
      ),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(error.toString())),
        data: (value) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Text(l.transformDescription),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_book) ...[
                  Card(
                    child: SwitchListTile(
                      title: Text(l.transformInherit),
                      subtitle: Text(l.transformInheritDescription),
                      value: value
                          .book(widget.feedId!, widget.bookId!)
                          .inheritApplication,
                      onChanged: _busy ? null : _setInheritance,
                    ),
                  ),
                  if (value
                      .book(widget.feedId!, widget.bookId!)
                      .inheritApplication) ...[
                    _SectionTitle(label: l.transformApplicationRules),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(l.transformApplicationEditHint),
                    ),
                    _ruleList(value.application, application: true),
                    if (value.application.isEmpty) Text(l.transformEmpty),
                  ],
                  _SectionTitle(label: l.transformBookRules),
                ],
                if (_rules(value).isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        const Icon(Icons.auto_fix_high_outlined, size: 48),
                        const SizedBox(height: 16),
                        Text(l.transformEmpty),
                        const SizedBox(height: 8),
                        Text(l.transformAddHint),
                      ],
                    ),
                  ),
                _ruleList(_rules(value)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );
}
