import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../src/rust/api/types.dart';
import 'transformer_rule_card.dart';
import 'transformer_settings.dart';

enum TransformerEditAction { save, delete }

class TransformerRuleEditorPage extends StatefulWidget {
  const TransformerRuleEditorPage({
    super.key,
    required this.initial,
    required this.onSave,
    this.existing = false,
    this.applicationFromBook = false,
  });
  final TransformerEntry initial;
  final Future<void> Function(
    TransformerEntry rule,
    TransformerEditAction action,
  )
  onSave;
  final bool existing, applicationFromBook;
  @override
  State<TransformerRuleEditorPage> createState() =>
      _TransformerRuleEditorPageState();
}

class _TransformerRuleEditorPageState extends State<TransformerRuleEditorPage> {
  final _form = GlobalKey<FormState>();
  late TransformerEntry _rule = widget.initial;
  bool _saving = false;
  String? _error;

  Future<void> _save(TransformerEditAction action) async {
    final l = AppLocalizations.of(context);
    if (action == TransformerEditAction.delete) {
      final confirmed = await showConfirmDialog(
        context,
        title: l.transformRemoveTitle,
        message: l.transformRemoveMessage,
        confirmLabel: l.bookshelfDeleteConfirm,
        cancelLabel: l.bookshelfDeleteCancel,
      );
      if (!confirmed || !mounted) return;
    } else if (!_form.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_rule.copyWith(name: _rule.name.trim()), action);
      if (mounted) Navigator.of(context).pop();
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
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(transformerLabel(l, _rule.kind)),
          actions: [
            TextButton.icon(
              onPressed: _saving
                  ? null
                  : () => _save(TransformerEditAction.save),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(l.transformSave),
            ),
            if (widget.existing)
              PopupMenuButton<TransformerEditAction>(
                enabled: !_saving,
                onSelected: _save,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: TransformerEditAction.delete,
                    child: Text(l.bookshelfDeleteConfirm),
                  ),
                ],
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.applicationFromBook)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(l.transformApplicationEditHint),
                  ),
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
                Form(
                  key: _form,
                  child: TransformerRuleForm(
                    rule: _rule,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _rule = value),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
