import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../router/app_router.dart';
import 'feed_service.dart';

/// Keeps the app-wide WebView verification prompt stream open and presents
/// each prompt.
///
/// Feed reducers can return a `webview` step when they hit a gate only a
/// human in a real browser can clear (anti-bot sliders, consent walls).
/// The Rust side parks the originating operation and emits a prompt here;
/// this coordinator pushes the [WebviewVerifyPage], the user completes the
/// interaction, and the page snapshot flows back into the reducer, which
/// retries with the fresh session.
///
/// Started once from `LanghuanApp`; prompts are presented sequentially —
/// the loop parks on `push` until the page pops.
final webviewVerifyCoordinatorProvider = FutureProvider<void>((ref) async {
  final router = ref.watch(appRouterProvider);
  final service = FeedService.instance;

  final stream = await service.openWebviewPromptStream();
  ref.onDispose(() => unawaited(stream.cancel()));

  while (true) {
    final prompt = await stream.next();
    if (prompt == null) break;
    final model = WebviewPromptModel.fromRust(prompt);
    try {
      await router.pushNamed('webview-verify', extra: model);
    } catch (error, stack) {
      // The page could not be presented (router gone, bad state) — release
      // the parked operation instead of leaving it hanging forever.
      debugPrint('webview prompt presentation failed: $error\n$stack');
      try {
        await service.cancelWebview(model.requestId);
      } catch (_) {
        // The operation was already gone; nothing else to do.
      }
    }
  }
});
