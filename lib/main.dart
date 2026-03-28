import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langhuan/rust_init.dart';
import 'package:rinf/rinf.dart';

import 'app.dart';
import 'src/bindings/bindings.dart';
import 'src/bindings/signals/signals.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeRust(assignRustSignal);

  setLocaleToRust();

  runApp(const ProviderScope(child: LanghuanApp()));
}
