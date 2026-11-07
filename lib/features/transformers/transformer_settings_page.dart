import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../src/rust/api/types.dart';
import 'transformer_rule_card.dart';
import 'transformer_rule_editor_page.dart';
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
    if (_saving || from == to) return;
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

  Widget _ruleList(List<TransformerEntry> rules, {bool application = false}) =>
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: rules.length,
        onReorderItem: (from, to) =>
            _reorder(from, to, application: application),
        itemBuilder: (context, index) => TransformerRuleCard(
          key: ObjectKey(rules[index]),
          rule: rules[index],
          onTap: _saving
              ? null
              : () => _edit(index: index, application: application),
          dragHandle: ReorderableDragStartListener(
            index: index,
            enabled: !_saving,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Tooltip(
                message: AppLocalizations.of(context).transformReorder,
                child: const Icon(Icons.drag_handle),
              ),
            ),
          ),
        ),
      );

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
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TransformerRuleEditorPage(
          initial: initial,
          existing: index != null,
          applicationFromBook: _book && application,
          onSave: (rule, action) =>
              _saveRule(rule, action, index: index, application: application),
        ),
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
        onPressed: settings.hasValue && !_saving ? _add : null,
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
                      onChanged: _saving ? null : _setInheritance,
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
