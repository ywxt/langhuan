import 'dart:async';

import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import 'listening_controller.dart';
import 'listening_voice_picker.dart';

Future<void> showListeningPanel(
  BuildContext context,
  ListeningController controller, {
  required VoidCallback onStart,
}) {
  unawaited(controller.loadVoices());
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(LanghuanTheme.spaceLg),
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
                const SizedBox(height: LanghuanTheme.spaceMd),
                if (controller.status == ListeningStatus.error ||
                    controller.voicesError != null) ...[
                  Text(
                    l10n.listeningError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                ],
                if (controller.status == ListeningStatus.completed)
                  Text(l10n.listeningCompleted),
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: const ValueKey('listening-voice-selector'),
                    leading: const Icon(Icons.record_voice_over_outlined),
                    title: Text(l10n.listeningVoice),
                    subtitle: Text(
                      controller.voicesLoading
                          ? l10n.listeningLoadingVoices
                          : controller.voicesError != null
                          ? l10n.listeningReloadVoices
                          : '${controller.voice?.name ?? ''} · ${controller.voice?.locale ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: controller.voicesLoading
                        ? const LanghuanSpinner(size: 20)
                        : Icon(
                            controller.voicesError != null
                                ? Icons.refresh
                                : Icons.chevron_right,
                          ),
                    onTap: controller.voicesLoading
                        ? null
                        : () async {
                            if (controller.voicesError != null) {
                              await controller.loadVoices();
                              return;
                            }
                            final voice = await showListeningVoicePicker(
                              context,
                              voices: controller.voices,
                              selected: controller.voice?.key,
                            );
                            if (voice != null && context.mounted) {
                              await controller.configure(voice: voice);
                            }
                          },
                  ),
                ),
                const SizedBox(height: LanghuanTheme.spaceMdSm),
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
                  alignment: WrapAlignment.spaceBetween,
                  spacing: LanghuanTheme.spaceSm,
                  children: [
                    IconButton(
                      tooltip: l10n.listeningPrevious,
                      onPressed: !controller.canMoveParagraph
                          ? null
                          : () => controller.moveParagraph(-1),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    FilledButton.icon(
                      onPressed: controller.active
                          ? controller.pause
                          : () {
                              onStart();
                              // Starting playback hands the screen back to
                              // the reader; the mini player carries controls.
                              Navigator.of(context).pop();
                            },
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
                      onPressed: !controller.canMoveParagraph
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
                const SizedBox(height: LanghuanTheme.spaceMdSm),
                Text(l10n.listeningSleep),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: LanghuanTheme.spaceSm,
                  children: [
                    ActionChip(
                      label: Text(l10n.listeningNoTimer),
                      onPressed: () => controller.setSleepTimer(null),
                    ),
                    for (final minutes in [15, 30, 60])
                      ActionChip(
                        label: Text('${minutes}m'),
                        onPressed: () => controller.setSleepTimer(
                          Duration(minutes: minutes),
                        ),
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
}

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
