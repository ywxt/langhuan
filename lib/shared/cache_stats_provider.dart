import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_service.dart';
import '../src/rust/api/types.dart' show CacheStats;

/// Database and cache statistics.
///
/// The value is a snapshot from the last fetch. It is invalidated whenever
/// the settings tab is entered and after maintenance actions, so the numbers
/// shown on the settings page are always current while keeping the previous
/// value on screen during a refresh.
final cacheStatsProvider = FutureProvider<CacheStats>((ref) {
  return AppService.instance.cacheStats();
});
