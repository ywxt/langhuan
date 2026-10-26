import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the developer tools are unlocked.
///
/// Unlocked by tapping the settings page's version row seven times (the
/// Android-style hidden gate) and hidden otherwise — the developer
/// environment is invisible to normal users. It is a persisted runtime
/// toggle rather than a compile-time flag, so sources can be debugged on
/// real devices running release builds.
class DeveloperModeNotifier extends Notifier<bool> {
  static const _kDeveloperMode = 'developer.enabled';

  @override
  bool build() {
    _restoreFromStorage();
    return false;
  }

  void setEnabled(bool enabled) {
    if (state == enabled) return;
    state = enabled;
    _persistState();
  }

  void toggle() => setEnabled(!state);

  Future<void> _restoreFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kDeveloperMode) ?? false;
    if (enabled != state) {
      state = enabled;
    }
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDeveloperMode, state);
  }
}

final developerModeProvider = NotifierProvider<DeveloperModeNotifier, bool>(
  DeveloperModeNotifier.new,
);
