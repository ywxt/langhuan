import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'listening_controller.dart';

Future<void> showListeningPanel(
  BuildContext context,
  ListeningController controller, {
  required VoidCallback onStart,
  VoidCallback? onStartHere,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final l10n = AppLocalizations.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.listeningTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  CloseButton(),
                ],
              ),
              Text(l10n.listeningLocalHint),
              const SizedBox(height: 16),
              if (controller.status == ListeningStatus.error) ...[
                Text(
                  l10n.listeningError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              if (controller.status == ListeningStatus.completed)
                Text(l10n.listeningCompleted),
              if (controller.voices.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(controller.voice?.id),
                  initialValue: controller.voice?.id,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.listeningVoice),
                  items: [
                    for (final voice in controller.voices)
                      DropdownMenuItem(
                        value: voice.id,
                        child: Text(
                          '${voice.name} · ${voice.locale}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) {
                      controller.configure(
                        voice: controller.voices.firstWhere((v) => v.id == id),
                      );
                    }
                  },
                ),
              const SizedBox(height: 12),
              Text(
                '${l10n.listeningRate} · ${controller.rate.toStringAsFixed(1)}×',
              ),
              Slider(
                value: controller.rate,
                min: .5,
                max: 2,
                divisions: 15,
                onChanged: controller.previewRate,
                onChangeEnd: (value) => controller.configure(rate: value),
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  IconButton(
                    tooltip: l10n.listeningPrevious,
                    onPressed: controller.voice == null
                        ? null
                        : () => controller.moveParagraph(-1),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  FilledButton.icon(
                    onPressed: controller.active
                        ? controller.pause
                        : controller.status == ListeningStatus.paused
                        ? controller.resume
                        : onStart,
                    icon: Icon(
                      controller.active ? Icons.pause : Icons.play_arrow,
                    ),
                    label: Text(
                      controller.active
                          ? l10n.listeningPause
                          : controller.status == ListeningStatus.paused
                          ? l10n.listeningResume
                          : l10n.listeningStart,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.listeningNext,
                    onPressed: controller.voice == null
                        ? null
                        : () => controller.moveParagraph(1),
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: l10n.listeningStop,
                    onPressed: controller.stop,
                    icon: const Icon(Icons.stop),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (onStartHere != null)
                TextButton.icon(
                  onPressed: onStartHere,
                  icon: const Icon(Icons.my_location),
                  label: Text(l10n.listeningFromHere),
                ),
              Text(l10n.listeningSleep),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: Text(l10n.listeningNoTimer),
                    onPressed: () => controller.setSleepTimer(null),
                  ),
                  for (final minutes in [15, 30, 60])
                    ActionChip(
                      label: Text('${minutes}m'),
                      onPressed: () =>
                          controller.setSleepTimer(Duration(minutes: minutes)),
                    ),
                ],
              ),
              if (controller.sleepDeadline case final deadline?)
                Text(TimeOfDay.fromDateTime(deadline).format(context)),
            ],
          );
        },
      ),
    ),
  ),
);

class ListeningMiniPlayer extends StatelessWidget {
  const ListeningMiniPlayer({super.key, required this.controller});
  final ListeningController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.status == ListeningStatus.idle) {
        return const SizedBox.shrink();
      }
      final l10n = AppLocalizations.of(context);
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: ListTile(
          leading: const Icon(Icons.headphones),
          title: Text(l10n.listeningTitle),
          subtitle: Text(controller.chapterId, maxLines: 1),
          onTap: () => showListeningPanel(
            context,
            controller,
            onStart: () => controller.start(
              feedId: controller.feedId,
              bookId: controller.bookId,
              chapterId: controller.chapterId,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: controller.active
                    ? l10n.listeningPause
                    : l10n.listeningResume,
                icon: Icon(controller.active ? Icons.pause : Icons.play_arrow),
                onPressed: controller.active
                    ? controller.pause
                    : controller.resume,
              ),
              IconButton(
                tooltip: l10n.listeningStop,
                icon: const Icon(Icons.close),
                onPressed: controller.stop,
              ),
            ],
          ),
        ),
      );
    },
  );
}
