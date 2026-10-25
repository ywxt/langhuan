import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Confirmation dialog content in the Add Feed style.
///
/// A body [message] followed by an optional highlighted block:
/// - [warning] renders an error-tinted container (destructive consequences),
/// - [note] renders a neutral informational container.
///
/// The blocks reuse the visual language of the Add Feed dialog's error
/// content: rounded container, leading outline icon, matching text colour.
class ConfirmDialogContent extends StatelessWidget {
  const ConfirmDialogContent({
    super.key,
    required this.message,
    this.warning,
    this.note,
  });

  final String message;

  /// Destructive-consequence text, shown in an error-tinted block.
  final String? warning;

  /// Informational text, shown in a neutral block.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: theme.textTheme.bodyMedium),
          if (warning != null) ...[
            const SizedBox(height: LanghuanTheme.spaceMd),
            ConfirmNoteBlock(text: warning!, warning: true),
          ],
          if (note != null) ...[
            const SizedBox(height: LanghuanTheme.spaceMd),
            ConfirmNoteBlock(text: note!, warning: false),
          ],
        ],
      ),
    );
  }
}

/// A rounded container block with a leading outline icon, styled after the
/// Add Feed dialog's error content.
class ConfirmNoteBlock extends StatelessWidget {
  const ConfirmNoteBlock({super.key, required this.text, this.warning = true});

  final String text;

  /// When true the block uses error colours, otherwise neutral colours.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final backgroundColor = warning
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final foregroundColor = warning
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: LanghuanTheme.borderRadiusMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.error_outline : Icons.info_outline,
            color: foregroundColor,
          ),
          const SizedBox(width: LanghuanTheme.spaceSm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foregroundColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows a confirmation dialog built from [ConfirmDialogContent] and returns
/// whether the user confirmed.
///
/// The action row follows the Add Feed dialog: a plain [TextButton] for
/// cancel and a regular [FilledButton] for the primary action.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel,
  String? warning,
  String? note,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      scrollable: true,
      content: ConfirmDialogContent(
        message: message,
        warning: warning,
        note: note,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            cancelLabel ??
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
