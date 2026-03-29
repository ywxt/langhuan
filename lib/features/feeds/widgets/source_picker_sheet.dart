import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/option_row.dart';
import 'add_feed_dialog.dart';

/// Bottom sheet that lets the user choose how to add a feed: from URL or file.
class SourcePickerSheet extends StatefulWidget {
  const SourcePickerSheet({super.key, required this.parentContext});

  final BuildContext parentContext;

  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  bool _pickingFile = false;

  void _openUrlDialog() {
    Navigator.of(context).pop();
    if (!widget.parentContext.mounted) return;
    showDialog<void>(
      context: widget.parentContext,
      builder: (_) => const AddFeedDialog(),
    );
  }

  Future<void> _pickFile() async {
    setState(() => _pickingFile = true);
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null) return;
      if (!mounted) return;
      Navigator.of(context).pop();
      if (!widget.parentContext.mounted) return;
      showDialog<void>(
        context: widget.parentContext,
        builder: (_) => AddFeedDialog(initialPath: path),
      );
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LanghuanTheme.spaceLg,
        0,
        LanghuanTheme.spaceLg,
        LanghuanTheme.spaceXl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: LanghuanTheme.spaceMd),
            child: Text(l10n.addFeedTitle, style: theme.textTheme.titleLarge),
          ),
          OptionRow(
            icon: Icons.link_rounded,
            label: l10n.addFeedTabUrl,
            subtitle: l10n.addFeedTabUrlDesc,
            onTap: _openUrlDialog,
          ),
          OptionRow(
            icon: Icons.folder_open_rounded,
            label: l10n.addFeedTabFile,
            subtitle: l10n.addFeedTabFileDesc,
            onTap: _pickingFile ? null : _pickFile,
            trailing: _pickingFile
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
