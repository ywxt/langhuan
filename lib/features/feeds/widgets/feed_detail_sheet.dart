import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/errors.dart';
import '../../../shared/utils/snackbars.dart';
import '../../../shared/widgets/meta_row.dart';
import '../../../src/rust/api/types.dart';
import '../feed_providers.dart';
import '../feed_service.dart';

/// Opens a modal bottom sheet showing feed metadata.
void showFeedDetailSheet(BuildContext context, FeedMetaItem feed) {
  showModalBottomSheet<void>(
    context: context,
    builder: (context) => FeedDetailSheet(feed: feed),
  );
}

/// Bottom sheet displaying detailed metadata for a single feed.
class FeedDetailSheet extends StatelessWidget {
  const FeedDetailSheet({super.key, required this.feed});

  final FeedMetaItem feed;

  @override
  Widget build(BuildContext context) {
    return _FeedDetailContent(feed: feed);
  }
}

class _FeedDetailContent extends ConsumerStatefulWidget {
  const _FeedDetailContent({required this.feed});

  final FeedMetaItem feed;

  @override
  ConsumerState<_FeedDetailContent> createState() => _FeedDetailContentState();
}

class _FeedDetailContentState extends ConsumerState<_FeedDetailContent> {
  bool _loadingAuth = false;
  bool _authSupported = false;
  FeedAuthStatusModel _authStatus = FeedAuthStatusModel.unsupported;

  @override
  void initState() {
    super.initState();
    _loadAuthStatus();
  }

  Future<void> _loadAuthStatus() async {
    setState(() {
      _loadingAuth = true;
    });
    var supported = false;
    try {
      supported = await FeedService.instance.isFeedAuthSupported(
        widget.feed.id,
      );
      FeedAuthStatusModel status = FeedAuthStatusModel.unsupported;
      if (supported) {
        try {
          status = await FeedService.instance.getFeedAuthStatus(widget.feed.id);
        } catch (_) {
          // A failed status probe (for example while offline) must not hide
          // the login action for an auth-capable feed.
          status = FeedAuthStatusModel.loggedOut;
        }
      }
      if (!mounted) return;
      setState(() {
        _authSupported = supported;
        _authStatus = status;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _authSupported = supported;
        _authStatus = FeedAuthStatusModel.unsupported;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingAuth = false;
        });
      }
    }
  }

  Future<void> _openLoginFlow() async {
    final navigator = GoRouter.of(context);
    final result = await navigator.pushNamed<bool>(
      'feed-auth',
      queryParameters: {'feedId': widget.feed.id},
    );
    if (result == true && mounted) {
      ref.invalidate(feedAuthStatusProvider(widget.feed.id));
      await _loadAuthStatus();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showSuccessSnack(
        ScaffoldMessenger.of(context),
        l10n.feedAuthUpdated,
      );
    }
  }

  Future<void> _logout() async {
    try {
      await FeedService.instance.clearFeedAuth(widget.feed.id);
      if (!mounted) return;
      ref.invalidate(feedAuthStatusProvider(widget.feed.id));
      await _loadAuthStatus();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showSuccessSnack(
        ScaffoldMessenger.of(context),
        l10n.feedAuthLoggedOut,
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(
        ScaffoldMessenger.of(context),
        normalizeErrorMessage(e),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final feed = widget.feed;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LanghuanTheme.spaceLg,
          0,
          LanghuanTheme.spaceLg,
          LanghuanTheme.spaceXl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(feed.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: LanghuanTheme.spaceMd),

            if (feed.error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(LanghuanTheme.spaceMd),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: LanghuanTheme.borderRadiusMd,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: LanghuanTheme.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.feedItemLoadError,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            feed.error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
            ],

            MetaRow(
              icon: Icons.label_outline,
              label: l10n.feedDetailId,
              value: feed.id,
            ),
            const SizedBox(height: LanghuanTheme.spaceMd),
            MetaRow(
              icon: Icons.tag,
              label: l10n.feedDetailVersion,
              value: feed.version,
            ),
            if (feed.author != null) ...[
              const SizedBox(height: LanghuanTheme.spaceMd),
              MetaRow(
                icon: Icons.person_outline,
                label: l10n.feedDetailAuthor,
                value: feed.author!,
              ),
            ],

            if (_authSupported) ...[
              const SizedBox(height: LanghuanTheme.spaceLg),
              const Divider(),
              const SizedBox(height: LanghuanTheme.spaceMd),
              MetaRow(
                icon: Icons.lock_outline,
                label: l10n.feedAuthLabel,
                value: switch (_authStatus) {
                  FeedAuthStatusModel.loggedIn => l10n.feedAuthStatusLoggedIn,
                  FeedAuthStatusModel.expired => l10n.feedAuthStatusExpired,
                  FeedAuthStatusModel.loggedOut => l10n.feedAuthStatusLoggedOut,
                  FeedAuthStatusModel.unsupported =>
                    l10n.feedAuthStatusUnsupported,
                },
              ),
              const SizedBox(height: LanghuanTheme.spaceMd),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _loadingAuth ? null : _openLoginFlow,
                    icon: const Icon(Icons.login),
                    label: Text(l10n.feedAuthLogin),
                  ),
                  const SizedBox(width: LanghuanTheme.spaceSm),
                  OutlinedButton.icon(
                    onPressed:
                        _loadingAuth ||
                            _authStatus == FeedAuthStatusModel.loggedOut
                        ? null
                        : _logout,
                    icon: const Icon(Icons.logout),
                    label: Text(l10n.feedAuthLogout),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
