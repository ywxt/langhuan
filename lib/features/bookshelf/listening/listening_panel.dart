import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/loading.dart';
import 'listening_controller.dart';
import 'listening_voice_picker.dart';

const _ratePresets = [0.75, 1.0, 1.25, 1.5, 2.0];
const _sleepPresets = [15, 30, 60];

String _rateLabel(double value) =>
    '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}×';

String _durationLabel(Duration remaining) =>
    '${remaining.inMinutes}:${remaining.inSeconds.remainder(60).toString().padLeft(2, '0')}';

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
                Text('${l10n.listeningRate} · ${_rateLabel(controller.rate)}'),
                Wrap(
                  spacing: LanghuanTheme.spaceSm,
                  children: [
                    for (final preset in _ratePresets)
                      ChoiceChip(
                        label: Text(_rateLabel(preset)),
                        selected: (controller.rate - preset).abs() < 0.01,
                        onSelected: (_) => controller.configure(rate: preset),
                      ),
                  ],
                ),
                Slider(
                  value: controller.rate.clamp(0.5, 2.0),
                  min: .5,
                  max: 2,
                  divisions: 15,
                  onChanged: controller.previewRate,
                  onChangeEnd: (value) => controller.configure(rate: value),
                ),
                const SizedBox(height: LanghuanTheme.spaceMdSm),
                Text(l10n.listeningSleep),
                Wrap(
                  spacing: LanghuanTheme.spaceSm,
                  children: [
                    ChoiceChip(
                      label: Text(l10n.listeningNoTimer),
                      selected:
                          controller.sleepDeadline == null &&
                          !controller.sleepAtChapterEnd,
                      onSelected: (_) => controller.setSleepTimer(null),
                    ),
                    for (final minutes in _sleepPresets)
                      ChoiceChip(
                        label: Text('${minutes}m'),
                        selected:
                            controller.sleepDuration ==
                            Duration(minutes: minutes),
                        onSelected: (_) => controller.setSleepTimer(
                          Duration(minutes: minutes),
                        ),
                      ),
                    ChoiceChip(
                      label: Text(l10n.listeningChapterEnd),
                      selected: controller.sleepAtChapterEnd,
                      onSelected: (_) =>
                          controller.setSleepTimer(null, atChapterEnd: true),
                    ),
                    ChoiceChip(
                      label: Text(l10n.listeningCustomTimer),
                      selected:
                          controller.sleepDuration != null &&
                          !_sleepPresets.any(
                            (minutes) =>
                                controller.sleepDuration ==
                                Duration(minutes: minutes),
                          ),
                      onSelected: (_) =>
                          _showCustomSleepTimerDialog(context, controller),
                    ),
                  ],
                ),
                if (controller.sleepDeadline case final deadline?)
                  _SleepCountdownRow(deadline: deadline)
                else if (controller.sleepAtChapterEnd)
                  Padding(
                    padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
                    child: Text(
                      AppLocalizations.of(context).listeningStopsAfterChapter,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: LanghuanTheme.spaceMdSm),
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
                              if (controller.status == ListeningStatus.paused) {
                                controller.resume();
                              } else {
                                onStart();
                              }
                              // Playback hands the screen back to the
                              // reader; the mini player carries controls.
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
              ],
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _showCustomSleepTimerDialog(
  BuildContext context,
  ListeningController controller,
) {
  final l10n = AppLocalizations.of(context);
  final materials = MaterialLocalizations.of(context);
  var minutes = (controller.sleepDuration?.inMinutes ?? 30).clamp(1, 120);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(l10n.listeningCustomTimerTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.listeningMinutesLabel(minutes)),
            Slider(
              key: const ValueKey('listening-custom-timer-slider'),
              value: minutes.toDouble(),
              min: 1,
              max: 120,
              divisions: 119,
              label: '$minutes',
              onChanged: (value) =>
                  setState(() => minutes = value.round().clamp(1, 120)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(materials.cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () {
              controller.setSleepTimer(Duration(minutes: minutes));
              Navigator.of(dialogContext).pop();
            },
            child: Text(materials.okButtonLabel),
          ),
        ],
      ),
    ),
  );
}

/// Live "stops in mm:ss" line for the active sleep deadline.
class _SleepCountdownRow extends StatefulWidget {
  const _SleepCountdownRow({required this.deadline});

  final DateTime deadline;

  @override
  State<_SleepCountdownRow> createState() => _SleepCountdownRowState();
}

class _SleepCountdownRowState extends State<_SleepCountdownRow> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.deadline.difference(DateTime.now());
    if (remaining.isNegative) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: LanghuanTheme.spaceSm),
      child: Text(
        AppLocalizations.of(
          context,
        ).listeningRemainingTime(_durationLabel(remaining)),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
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
      final theme = Theme.of(context);
      final chapterTitle = controller.chapterTitle;
      final subtitle = [
        if (controller.bookTitle.isNotEmpty &&
            controller.bookTitle != chapterTitle)
          controller.bookTitle,
        if (controller.paragraphTotal > 0)
          l10n.listeningParagraphProgress(
            controller.paragraphPosition,
            controller.paragraphTotal,
          ),
      ].join(' · ');
      return Material(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Chapter progress as a thin leading line.
            LinearProgressIndicator(
              value: controller.chapterProgress,
              minHeight: 2,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
            InkWell(
              onTap: () => showListeningPanel(
                context,
                controller,
                onStart: () => controller.start(
                  feedId: controller.feedId,
                  bookId: controller.bookId,
                  bookTitle: controller.bookTitle,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceMd,
                  vertical: LanghuanTheme.spaceSm,
                ),
                child: Row(
                  children: [
                    _EqualizerBars(playing: controller.active),
                    const SizedBox(width: LanghuanTheme.spaceMd),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chapterTitle.isNotEmpty
                                ? chapterTitle
                                : controller.bookTitle.isNotEmpty
                                ? controller.bookTitle
                                : l10n.listeningTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    if (controller.sleepDeadline case final deadline?)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: LanghuanTheme.spaceSm,
                        ),
                        child: Text(
                          '${(deadline.difference(DateTime.now()).inSeconds + 59) ~/ 60}m',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      )
                    else if (controller.sleepAtChapterEnd)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: LanghuanTheme.spaceSm,
                        ),
                        child: Tooltip(
                          message: l10n.listeningChapterEnd,
                          child: Icon(
                            Icons.bedtime_outlined,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: controller.active
                          ? l10n.listeningPause
                          : l10n.listeningResume,
                      icon: Icon(
                        controller.active ? Icons.pause : Icons.play_arrow,
                      ),
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
            ),
          ],
        ),
      );
    },
  );
}

/// Three-bar equalizer mark: animated while speaking, frozen when paused.
class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars({required this.playing});

  final bool playing;

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(_EqualizerBars old) {
    super.didUpdateWidget(old);
    if (widget.playing == old.playing) return;
    widget.playing ? _controller.repeat() : _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _amplitude(double t, int bar) {
    final phase = (t + bar / 3) % 1;
    return (math.sin(phase * 2 * math.pi) + 1) / 2;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var bar = 0; bar < 3; bar++)
            Container(
              width: 2,
              height: 3 + 7 * _amplitude(_controller.value, bar),
              margin: EdgeInsetsDirectional.only(end: bar == 2 ? 0 : 2),
              decoration: BoxDecoration(
                color: LanghuanTheme.brightGreen,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }
}
