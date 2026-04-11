import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/app_service.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isCleaning = false;

  Future<void> _cleanupCache() async {
    if (_isCleaning) return;
    setState(() => _isCleaning = true);

    try {
      final removed = await AppService.instance.cleanupStaleData();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final message = removed > 0
          ? l10n.settingsCleanupSuccess(removed)
          : l10n.settingsCleanupNothingToClean;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.settingsCleanupError)));
    } finally {
      if (mounted) setState(() => _isCleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: LanghuanTheme.spaceLg,
          ),
          children: [
            // ── Title ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                LanghuanTheme.spaceLg,
                0,
                LanghuanTheme.spaceLg,
              ),
              child: Text(
                l10n.settingsTitle,
                style: theme.textTheme.headlineLarge,
              ),
            ),

            // ── Storage section ────────────────────────────────────────
            _SectionLabel(label: l10n.settingsStorage),
            const SizedBox(height: LanghuanTheme.spaceSm),
            _SettingsCard(
              children: [
                _SettingsRow(
                  icon: Icons.cleaning_services_outlined,
                  label: l10n.settingsCleanupCache,
                  subtitle: l10n.settingsCleanupCacheDescription,
                  trailing: _isCleaning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant.withAlpha(
                            120,
                          ),
                        ),
                  onTap: _isCleaning ? null : _cleanupCache,
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
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
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
