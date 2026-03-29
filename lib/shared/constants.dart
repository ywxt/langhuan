/// App-wide constants.
///
/// Centralises magic values so they can be changed in one place.
abstract final class AppConstants {
  /// Displayed in the Settings page and license dialog.
  static const String appVersion = '1.0.0';

  /// How long the "undo delete" snackbar stays visible before the deletion
  /// is committed.
  static const Duration undoDuration = Duration(seconds: 4);
}
