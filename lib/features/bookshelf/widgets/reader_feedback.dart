import 'package:flutter/material.dart';

/// Shows a brief themed toast on the root overlay.
///
/// Pure-Flutter replacement for the former `fluttertoast` plugin: no platform
/// channel, fully theme-driven, and rendered on the root overlay so it stays
/// visible above full-screen reader pages and open modal sheets.
void showReaderToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  // Replace a toast that is still visible instead of stacking entries.
  _currentEntry?.remove();
  _currentEntry = null;

  final theme = Theme.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ReaderToast(
      message: message,
      background: theme.colorScheme.onSurface,
      foreground: theme.colorScheme.surface,
      onFinished: () {
        if (_currentEntry == entry) {
          _currentEntry = null;
          entry.remove();
        }
      },
    ),
  );
  _currentEntry = entry;
  overlay.insert(entry);
}

OverlayEntry? _currentEntry;

class _ReaderToast extends StatefulWidget {
  const _ReaderToast({
    required this.message,
    required this.background,
    required this.foreground,
    required this.onFinished,
  });

  final String message;
  final Color background;
  final Color foreground;
  final VoidCallback onFinished;

  @override
  State<_ReaderToast> createState() => _ReaderToastState();
}

class _ReaderToastState extends State<_ReaderToast>
    with SingleTickerProviderStateMixin {
  static const Duration _visibleDuration = Duration(milliseconds: 2400);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    reverseDuration: const Duration(milliseconds: 200),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future<void>.delayed(_visibleDuration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _controller.reverse();
    if (!mounted) return;
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.paddingOf(context).bottom + 48,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _controller,
          child: Center(
            child: Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: widget.background,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  widget.message,
                  style: TextStyle(color: widget.foreground, fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
