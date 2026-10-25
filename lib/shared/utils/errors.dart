/// Shared error helpers used across features.
library;

/// Strips common exception prefixes (e.g. `BridgeError: …`) from an error so
/// only the human-readable message remains.
String normalizeErrorMessage(Object error) {
  final text = error.toString().trim();
  if (text.isEmpty) return 'Unknown error';
  final colonIndex = text.indexOf(':');
  if (colonIndex > 0 && colonIndex < text.length - 1) {
    return text.substring(colonIndex + 1).trim();
  }
  return text;
}
