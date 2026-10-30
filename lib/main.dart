import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/rust_init.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // Draw the app behind transparent system bars so the scaffold surface is
  // the status bar colour everywhere. Android 15+ forces this layout
  // anyway; on older versions the window would otherwise keep the launch
  // theme's opaque black bar above a light app.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  setLocaleToRust();

  runApp(const ProviderScope(child: LanghuanApp()));
}
