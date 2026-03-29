import 'package:flutter/material.dart';

import 'widgets/source_picker_sheet.dart';

// ---------------------------------------------------------------------------
// Public entry point called from feeds_page.dart
// ---------------------------------------------------------------------------

/// Opens the "Add Feed" bottom sheet flow.
void showAddFeedSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SourcePickerSheet(parentContext: context),
  );
}
