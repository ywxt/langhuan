import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/theme/app_theme.dart';
import '../../src/rust/api/types.dart';
import 'transformer_rule_card.dart';
import 'transformer_settings.dart';

enum TransformerEditAction { save, delete }

class TransformerRuleEditorSheet extends StatefulWidget {
  const TransformerRuleEditorSheet({
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
  State<TransformerRuleEditorSheet> createState() =>
      _TransformerRuleEditorSheetState();
}

class _TransformerRuleEditorSheetState
    extends State<TransformerRuleEditorSheet> {
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
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
                child: Row(
                  children: [
                    Icon(transformerIcon(_rule.kind)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _rule.name.trim().isEmpty
                                ? transformerLabel(l, _rule.kind)
                                : _rule.name.trim(),
                            key: const ValueKey('transformer-editor-title'),
                            style: Theme.of(context).textTheme.titleLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_rule.name.trim().isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              transformerLabel(l, _rule.kind),
                              key: const ValueKey('transformer-editor-type'),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    CloseButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LanghuanTheme.spaceLg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Row(
                  children: [
                    if (widget.existing) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : () => _save(TransformerEditAction.delete),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(l.bookshelfDeleteConfirm),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _save(TransformerEditAction.save),
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: Text(l.transformSave),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
