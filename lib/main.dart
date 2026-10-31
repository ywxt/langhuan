import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/rust_init.dart';

import 'app.dart';
import 'reader_gesture_binding.dart';
import 'shared/utils/reader_input_trace.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  ReaderGestureBinding();

  if (kProfileMode) {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final dispatchPacket = dispatcher.onPointerDataPacket;
    dispatcher.onPointerDataPacket = (packet) {
      ReaderInputTrace.recordPacket(packet);
      dispatchPacket?.call(packet);
    };
    // Opt-in diagnostic data stays in the local profile VM timeline. Input
    // behaviour cannot be changed through this extension.
    registerExtension('ext.langhuan.readerInputTrace', (_, parameters) async {
      final enabled = parameters['enabled'];
      if (enabled == 'true' || enabled == 'false') {
        ReaderInputTrace.enabled = enabled == 'true';
      }
      return ServiceExtensionResponse.result(
        jsonEncode({'enabled': ReaderInputTrace.enabled}),
      );
    });
  }

  await RustLib.init();

  // Draw the app behind transparent system bars so the scaffold surface is
  // the status bar colour everywhere. Android 15+ forces this layout
  // anyway; on older versions the window would otherwise keep the launch
  // theme's opaque black bar above a light app.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  setLocaleToRust();

  runApp(const ProviderScope(child: LanghuanApp()));
}
