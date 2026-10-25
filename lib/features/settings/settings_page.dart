import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/app_service.dart';
import '../../shared/cache_stats_provider.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/format_bytes.dart';
import '../../shared/utils/snackbars.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/loading.dart';
import '../../src/rust/api/types.dart' show CacheStats;
import '../bookshelf/reader_settings_provider.dart';
import '../bookshelf/widgets/book_cover.dart' show coverProvider;
import '../bookshelf/widgets/chinese_conversion_picker.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _isCleaning = false;
  bool _isClearing = false;
  bool _isBackingUp = false;

  String _statText(CacheStats? stats, String Function(CacheStats) read) {
    return stats == null ? '—' : read(stats);
  }

  Future<void> _cleanupCache() async {
    if (_isCleaning) return;
    setState(() => _isCleaning = true);

    try {
      final result = await AppService.instance.cleanupStaleData();
      ref.invalidate(cacheStatsProvider);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (result.itemsRemoved > 0) {
        showSuccessSnack(
          ScaffoldMessenger.of(context),
          l10n.settingsCleanupSuccess(result.itemsRemoved),
        );
      } else {
        showSuccessSnack(
          ScaffoldMessenger.of(context),
          l10n.settingsCleanupNothingToClean,
        );
      }
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showErrorSnack(ScaffoldMessenger.of(context), l10n.settingsCleanupError);
    } finally {
      if (mounted) setState(() => _isCleaning = false);
    }
  }

  Future<void> _clearCache() async {
    if (_isClearing) return;

    final l10n = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.settingsClearCacheConfirmTitle,
      message: l10n.settingsClearCacheConfirmMessage,
      note: l10n.settingsClearCacheNote,
      confirmLabel: l10n.settingsClearCache,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isClearing = true);

    try {
      final result = await AppService.instance.clearCache();
      // Stored cover bytes are gone — make BookCover widgets re-read.
      ref.invalidate(coverProvider);
      ref.invalidate(cacheStatsProvider);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (result.itemsRemoved > 0) {
        showSuccessSnack(
          ScaffoldMessenger.of(context),
          l10n.settingsClearCacheSuccess(formatBytes(result.bytesFreed)),
        );
      } else {
        showSuccessSnack(
          ScaffoldMessenger.of(context),
          l10n.settingsClearCacheNothing,
        );
      }
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showErrorSnack(
        ScaffoldMessenger.of(context),
        l10n.settingsClearCacheError,
      );
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  /// Write a database snapshot into the app-data directory, hand it to the
  /// system save dialog, then remove the temporary file. The copy the user
  /// saved (if any) is the only thing that survives.
  Future<void> _exportBackup() async {
    if (_isBackingUp) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _isBackingUp = true);

    File? temp;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final dir = await getApplicationDocumentsDirectory();
      temp = File('${dir.path}/langhuan-backup-$stamp.db');
      await AppService.instance.exportBackup(path: temp.path);

      final bytes = await temp.readAsBytes();
      final saved = await FilePicker.saveFile(
        fileName: 'langhuan-backup-$stamp.db',
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;
      if (saved != null) {
        showSuccessSnack(
          ScaffoldMessenger.of(context),
          l10n.settingsBackupSuccess,
        );
      }
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showErrorSnack(ScaffoldMessenger.of(context), l10n.settingsBackupError);
    } finally {
      // The snapshot is handed off (or abandoned); the temp never stays.
      if (temp != null && await temp.exists()) {
        await temp.delete();
      }
      if (mounted) setState(() => _isBackingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // AsyncValue.value keeps the previous snapshot on screen while a refresh
    // is in flight; null (loading without data, or a database error) falls
    // back to the '—' placeholders.
    final stats = ref.watch(cacheStatsProvider).value;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title — fixed page chrome; only the sections scroll. ──
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
                LanghuanTheme.spaceLg,
              ),
              child: Text(
                l10n.settingsTitle,
                style: theme.textTheme.headlineLarge,
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: LanghuanTheme.spaceLg,
                ),
                children: [
                  // ── Reading section ──────────────────────────────────
                  _SectionLabel(label: l10n.settingsReading),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _SettingsCard(
                    children: [_ChineseConversionRow(ref: ref, l10n: l10n)],
                  ),

                  const SizedBox(height: LanghuanTheme.spaceLg),

                  // ── Storage section ────────────────────────────────────────
                  _SectionLabel(label: l10n.settingsStorage),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _SettingsCard(
                    children: [
                      _SettingsRow(
                        icon: Icons.dataset_outlined,
                        label: l10n.settingsStorageDatabaseSize,
                        trailing: Text(
                          _statText(stats, (s) => formatBytes(s.dbBytes)),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const _SettingsDivider(),
                      _SettingsRow(
                        icon: Icons.storage_outlined,
                        label: l10n.settingsStorageCacheSize,
                        trailing: Text(
                          _statText(stats, (s) => formatBytes(s.cacheBytes)),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const _SettingsDivider(),
                      _StatsChips(stats: stats, l10n: l10n),
                      const _SettingsDivider(),
                      _SettingsRow(
                        icon: Icons.cleaning_services_outlined,
                        label: l10n.settingsCleanupCache,
                        subtitle: l10n.settingsCleanupCacheDescription,
                        trailing: _isCleaning
                            ? const LanghuanSpinner(size: 20)
                            : Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withAlpha(120),
                              ),
                        onTap: _isCleaning ? null : _cleanupCache,
                      ),
                      const _SettingsDivider(),
                      _SettingsRow(
                        icon: Icons.delete_sweep_outlined,
                        label: l10n.settingsClearCache,
                        subtitle: l10n.settingsClearCacheDescription,
                        trailing: _isClearing
                            ? const LanghuanSpinner(size: 20)
                            : Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withAlpha(120),
                              ),
                        onTap: _isClearing ? null : _clearCache,
                      ),
                      const _SettingsDivider(),
                      _SettingsRow(
                        icon: Icons.save_outlined,
                        label: l10n.settingsBackup,
                        subtitle: l10n.settingsBackupDescription,
                        trailing: _isBackingUp
                            ? const LanghuanSpinner(size: 20)
                            : Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withAlpha(120),
                              ),
                        onTap: _isBackingUp ? null : _exportBackup,
                      ),
                    ],
                  ),

                  const SizedBox(height: LanghuanTheme.spaceLg),

                  // ── About section ──────────────────────────────────────────
                  _SectionLabel(label: l10n.settingsAbout),
                  const SizedBox(height: LanghuanTheme.spaceSm),
                  _SettingsCard(
                    children: [
                      _SettingsRow(
                        icon: Icons.info_outline,
                        label: l10n.settingsVersion,
                        trailing: Text(
                          AppConstants.appVersion,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsRow(
                        icon: Icons.description_outlined,
                        label: l10n.settingsLicenses,
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant.withAlpha(
                            120,
                          ),
                        ),
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: l10n.appName,
                          applicationVersion: AppConstants.appVersion,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: LanghuanTheme.space2xl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings building blocks
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: LanghuanTheme.spaceXs),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: LanghuanTheme.borderRadiusMd,
      child: Column(children: children),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: LanghuanTheme.borderRadiusMd,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LanghuanTheme.spaceMd,
          vertical: 14,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: LanghuanTheme.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyLarge),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LanghuanTheme.spaceMd),
      child: Divider(
        height: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

/// Compact label/count chips summarizing what is stored.
class _StatsChips extends StatelessWidget {
  const _StatsChips({required this.stats, required this.l10n});

  final CacheStats? stats;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String count(int? value) => value?.toString() ?? '—';
    final chips = <String>[
      '${l10n.settingsStorageBooks} ${count(stats?.bookCount)}',
      '${l10n.settingsStorageChapters} ${count(stats?.chapterCount)}',
      '${l10n.settingsStorageCovers} ${count(stats?.coverCount)}',
      '${l10n.settingsStorageBookshelfCount} ${count(stats?.bookshelfCount)}',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LanghuanTheme.spaceMd,
        vertical: LanghuanTheme.spaceSm,
      ),
      child: Wrap(
        spacing: LanghuanTheme.spaceSm,
        runSpacing: LanghuanTheme.spaceXs,
        children: [
          for (final chip in chips)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: LanghuanTheme.spaceSm,
                vertical: LanghuanTheme.spaceXs,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: LanghuanTheme.borderRadiusSm,
              ),
              child: Text(
                chip,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChineseConversionRow extends StatelessWidget {
  const _ChineseConversionRow({required this.ref, required this.l10n});

  final WidgetRef ref;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final chineseConversion = ref.watch(
      readerSettingsProvider.select((s) => s.chineseConversion),
    );
    final notifier = ref.read(readerSettingsProvider.notifier);

    return _SettingsRow(
      icon: Icons.translate,
      label: l10n.settingsChineseConversion,
      subtitle:
          '${l10n.settingsChineseConversionDescription}\n'
          '${chineseConversionLabel(l10n, chineseConversion)}',
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final mode = await showChineseConversionPicker(
          context,
          selected: chineseConversion,
        );
        if (mode != null) notifier.setChineseConversion(mode);
      },
    );
  }
}
