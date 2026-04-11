import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/rust_init.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  setLocaleToRust();

  runApp(const ProviderScope(child: LanghuanApp()));
}
