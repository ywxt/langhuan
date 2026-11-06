import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop input shares the same navigation actions as touch page turns.
class ReaderDesktopControls extends StatelessWidget {
  const ReaderDesktopControls({
    super.key,
    required this.onPrevious,
    required this.onNext,
    required this.child,
    this.scrollToTurn = false,
  });

  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Widget child;
  final bool scrollToTurn;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      // Leave text fields, buttons and modal dialogs their own key handling.
      if (!node.hasPrimaryFocus ||
          ModalRoute.of(context)?.isCurrent == false ||
          (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed ||
          keyboard.isAltPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.pageUp ||
          (key == LogicalKeyboardKey.space && keyboard.isShiftPressed)) {
        onPrevious();
      } else if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.space) {
        onNext();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: Builder(
      builder: (focusContext) => Listener(
        onPointerDown: (event) {
          // Return keyboard navigation to the text after using reader controls.
          if (event.kind == PointerDeviceKind.mouse &&
              event.buttons == kPrimaryMouseButton) {
            Focus.of(focusContext).requestFocus();
          }
        },
        onPointerSignal: scrollToTurn
            ? (event) {
                if (event is! PointerScrollEvent ||
                    ModalRoute.of(context)?.isCurrent == false) {
                  return;
                }
                final delta = event.scrollDelta;
                final distance = delta.dx.abs() > delta.dy.abs()
                    ? delta.dx
                    : delta.dy;
                if (distance == 0) return;
                // A nested scrollable (e.g. chapter comments) gets first claim.
                GestureBinding.instance.pointerSignalResolver.register(event, (
                  _,
                ) {
                  Focus.of(focusContext).requestFocus();
                  if (distance > 0) {
                    onNext();
                  } else {
                    onPrevious();
                  }
                });
              }
            : null,
        child: child,
      ),
    ),
  );
}
