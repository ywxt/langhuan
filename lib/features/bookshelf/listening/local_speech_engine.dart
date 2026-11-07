import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/foundation.dart';

typedef LocalVoiceKey = ({String id, String locale});

class LocalVoice {
  const LocalVoice(this.id, this.name, this.locale);
  final String id;
  final String name;
  final String locale;

  // Android engines can reuse a voice name for several locales. Keep the
  // native identifier unchanged and use both fields for application identity.
  LocalVoiceKey get key => (id: id, locale: locale);
}

abstract class SpeechEngine {
  Future<List<LocalVoice>> voices();
  Future<void> speak(String text, LocalVoice voice, double rate);
  Future<void> stop();
}

/// Uses the device's TTS engine rather than a separate synthesis service.
/// Network use and voice data are managed by the engine itself.
class LocalSpeechEngine implements SpeechEngine {
  LocalSpeechEngine({
    TargetPlatform? platform,
    this.managedAudioSession = false,
  }) : _platform = platform ?? defaultTargetPlatform;
  final TargetPlatform _platform;
  final bool managedAudioSession;
  FlutterTts? _plugin;
  Process? _process;
  int _generation = 0;
  FlutterTts get _tts => _plugin ??= FlutterTts();

  @override
  Future<List<LocalVoice>> voices() async {
    if (_platform == TargetPlatform.linux) {
      final result = await Process.run('espeak-ng', ['--version']);
      if (result.exitCode != 0) throw StateError('espeak-ng unavailable');
      return const [LocalVoice('cmn', 'eSpeak NG 中文', 'zh-CN')];
    }
    if (managedAudioSession && _platform == TargetPlatform.iOS) {
      // audio_session owns activation across utterances and chapter boundaries.
      await _tts.autoStopSharedSession(false);
    }
    final values = await _tts.getVoices as List;
    final voicesByKey = <LocalVoiceKey, LocalVoice>{};
    for (final raw in values) {
      final value = Map<String, dynamic>.from(raw as Map);
      final name = value['name']?.toString();
      final locale = value['locale']?.toString();
      if (name == null || locale == null) continue;
      final voice = LocalVoice(
        value['identifier']?.toString() ?? name,
        name,
        locale,
      );
      voicesByKey.putIfAbsent(voice.key, () => voice);
    }
    final voices = voicesByKey.values.toList();
    voices.sort((a, b) {
      final language = (a.locale.startsWith('zh') ? 0 : 1).compareTo(
        b.locale.startsWith('zh') ? 0 : 1,
      );
      if (language != 0) return language;
      final name = a.name.compareTo(b.name);
      if (name != 0) return name;
      final locale = a.locale.compareTo(b.locale);
      return locale != 0 ? locale : a.id.compareTo(b.id);
    });
    return voices;
  }

  @override
  Future<void> speak(String text, LocalVoice voice, double rate) async {
    final generation = _generation;
    if (_platform == TargetPlatform.linux) {
      // Own the process so cancellation cannot stop other applications' speech.
      final process = await Process.start('espeak-ng', [
        '--stdin',
        '-v',
        voice.id,
        '-s',
        '${(175 * rate).round()}',
      ]);
      if (generation != _generation) {
        process.kill();
        return;
      }
      _process = process;
      final output = process.stdout.drain<void>();
      final errors = process.stderr.drain<void>();
      process.stdin.write(text);
      await process.stdin.close();
      final code = await process.exitCode;
      await Future.wait([output, errors]);
      if (identical(_process, process)) _process = null;
      if (code != 0 && generation == _generation) {
        throw StateError('eSpeak NG: $code');
      }
      return;
    }
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate((rate * 0.5).clamp(0.1, 1.0));
    final selection =
        (_platform == TargetPlatform.iOS || _platform == TargetPlatform.macOS)
        ? {'identifier': voice.id}
        : {'name': voice.name, 'locale': voice.locale};
    final selected = await _tts.setVoice(selection);
    if (selected != 1) throw StateError('local voice unavailable');
    if (generation != _generation) return;
    final result = await _tts.speak(text, focus: !managedAudioSession);
    if (generation == _generation && result != 1) {
      throw StateError('local speech failed');
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _process?.kill();
    _process = null;
    await _plugin?.stop();
  }
}

/// Internal utterance boundaries, independent of saved paragraph positions.
/// Never split a surrogate pair or strip punctuation from the original text.
Iterable<({int start, int end})> speechChunks(String text) sync* {
  var offset = 0;
  while (offset < text.length) {
    var end = (offset + 240).clamp(0, text.length);
    if (end < text.length && _low(text.codeUnitAt(end))) end--;
    final punctuation = RegExp(
      r'[。！？；.!?;\n]',
    ).allMatches(text.substring(offset, end));
    if (punctuation.isNotEmpty) end = offset + punctuation.last.end;
    yield (start: offset, end: end);
    offset = end;
  }
}

bool _low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
