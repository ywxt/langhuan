/// Format a byte count for display: `0 B`, `12.5 KB`, `3.4 MB`, `1.2 GB`.
///
/// Uses one decimal place below 100 of a unit and none above, so values stay
/// compact in the settings stats rows.
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
