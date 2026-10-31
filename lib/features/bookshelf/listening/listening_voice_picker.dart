import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import 'local_speech_engine.dart';

Future<LocalVoice?> showListeningVoicePicker(
  BuildContext context, {
  required List<LocalVoice> voices,
  required LocalVoiceKey? selected,
}) {
  final snapshot = List<LocalVoice>.unmodifiable(voices);
  Widget picker(BuildContext context) => ListeningVoicePicker(
    voices: snapshot,
    selected: selected,
    onSelected: (voice) => Navigator.of(context).pop(voice),
  );

  if (MediaQuery.sizeOf(context).width >= 840) {
    return showDialog<LocalVoice>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 520,
          height: MediaQuery.sizeOf(context).height * .7,
          child: picker(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<LocalVoice>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(heightFactor: .75, child: picker(context)),
    ),
  );
}

class ListeningVoicePicker extends StatefulWidget {
  const ListeningVoicePicker({
    super.key,
    required this.voices,
    required this.selected,
    required this.onSelected,
  });

  final List<LocalVoice> voices;
  final LocalVoiceKey? selected;
  final ValueChanged<LocalVoice> onSelected;

  @override
  State<ListeningVoicePicker> createState() => _ListeningVoicePickerState();
}

class _ListeningVoicePickerState extends State<ListeningVoicePicker> {
  final _scrollController = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final filtered = widget.voices
        .where(
          (voice) =>
              '${voice.name} ${voice.locale}'.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.listeningVoice,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const CloseButton(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            decoration: InputDecoration(
              hintText: l10n.listeningSearchVoices,
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (value) {
              setState(() => _query = value);
              if (_scrollController.hasClients) _scrollController.jumpTo(0);
            },
          ),
        ),
        const SizedBox(height: LanghuanTheme.spaceMd),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(l10n.listeningNoVoicesMatch))
              : Scrollbar(
                  controller: _scrollController,
                  child: ListView.builder(
                    controller: _scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final voice = filtered[index];
                      final selected = voice.key == widget.selected;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Semantics(
                          selected: selected,
                          child: ListTile(
                            selected: selected,
                            selectedTileColor:
                                theme.colorScheme.primaryContainer,
                            textColor: selected
                                ? theme.colorScheme.onPrimaryContainer
                                : null,
                            selectedColor: theme.colorScheme.onPrimaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: LanghuanTheme.borderRadiusMd,
                            ),
                            title: Text(
                              voice.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(voice.locale),
                            trailing: selected
                                ? const Icon(Icons.check_circle)
                                : null,
                            onTap: () => widget.onSelected(voice),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
