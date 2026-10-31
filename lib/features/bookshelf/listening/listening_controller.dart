import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_providers.dart';
import '../../feeds/feed_service.dart';
import 'local_speech_engine.dart';

enum ListeningStatus { idle, loading, playing, paused, completed, error }

final speechEngineProvider = Provider<SpeechEngine>(
  (ref) => LocalSpeechEngine(),
);
final listeningControllerProvider = Provider<ListeningController>((ref) {
  final controller = ListeningController(
    ref.watch(feedServiceProvider),
    ref.watch(speechEngineProvider),
  );
  final lifecycle = AppLifecycleListener(
    onPause: () => unawaited(controller.pause()),
    onHide: () => unawaited(controller.pause()),
  );
  ref.onDispose(lifecycle.dispose);
  ref.onDispose(controller.dispose);
  return controller;
});

class ListeningController extends ChangeNotifier {
  ListeningController(this._service, this._engine);
  final FeedService _service;
  final SpeechEngine _engine;
  int _generation = 0;
  int _configuration = 0;
  bool _disposed = false;
  Future<void>? _voiceLoad;
  bool voicesLoading = false;
  Object? voicesError;
  Timer? _sleepTimer;
  DateTime? sleepDeadline;
  ListeningStatus status = ListeningStatus.idle;
  Object? error;
  String feedId = '', bookId = '', chapterId = '', paragraphId = '';
  List<ChapterInfoModel> _chapters = [];
  List<ParagraphContent> _paragraphs = [];
  int _chapterIndex = 0, _paragraphIndex = 0;
  List<LocalVoice> voices = [];
  LocalVoice? voice;
  double rate = 1;
  bool get canMoveParagraph => _paragraphs.isNotEmpty;
  bool get active =>
      status == ListeningStatus.playing || status == ListeningStatus.loading;
  bool ownsBook(String feed, String book) =>
      active && feedId == feed && bookId == book;

  /// Enumerate voices without starting playback or touching reading progress.
  Future<void> loadVoices() {
    if (_disposed) return Future.value();
    return _voiceLoad ??= _loadVoices().whenComplete(() => _voiceLoad = null);
  }

  Future<void> _loadVoices() async {
    voicesLoading = true;
    voicesError = null;
    notifyListeners();
    try {
      final available = await _engine.voices();
      if (_disposed) return;
      if (available.isEmpty) {
        throw StateError('No voices available from the system TTS engine');
      }
      voices = available;
      voice =
          voices.where((v) => v.key == voice?.key).firstOrNull ?? voices.first;
    } catch (e) {
      if (!_disposed) voicesError = e;
    } finally {
      voicesLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> start({
    required String feedId,
    required String bookId,
    String chapterId = '',
    String paragraphId = '',
  }) async {
    final generation = ++_generation;
    try {
      await _engine.stop();
      if (generation != _generation) return;
      this.feedId = feedId;
      this.bookId = bookId;
      this.chapterId = chapterId;
      this.paragraphId = paragraphId;
      _paragraphs = [];
      _chapters = [];
      status = ListeningStatus.loading;
      error = null;
      notifyListeners();
      if (voices.isEmpty || voicesError != null || _voiceLoad != null) {
        await loadVoices();
      }
      if (generation != _generation) return;
      if (voicesError case final failure?) throw failure;
      final saved = chapterId.isEmpty
          ? await _service.getReadingProgress(feedId: feedId, bookId: bookId)
          : null;
      if (generation != _generation) return;
      if (saved != null) {
        this.chapterId = saved.chapterId;
        this.paragraphId = saved.paragraphId;
      }
      _chapters = await _service.chapters(feedId: feedId, bookId: bookId);
      if (generation != _generation) return;
      _chapterIndex = _chapters.indexWhere((c) => c.id == this.chapterId);
      if (_chapterIndex < 0) _chapterIndex = 0;
      unawaited(_run(generation));
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  Future<void> _run(int generation) async {
    try {
      while (generation == _generation && _chapterIndex < _chapters.length) {
        if (sleepDeadline case final deadline?
            when !deadline.isAfter(DateTime.now())) {
          sleepDeadline = null;
          await pause();
          return;
        }
        final nextChapter = _chapters[_chapterIndex].id;
        if (_paragraphs.isEmpty || nextChapter != chapterId) {
          if (nextChapter != chapterId) {
            chapterId = nextChapter;
            paragraphId = '';
          }
          // Keep chapter-level progress even when the new chapter fails to load.
          if (paragraphId.isEmpty) {
            await _save();
            if (generation != _generation) return;
          }
          final content = await _service.paragraphs(
            feedId: feedId,
            bookId: bookId,
            chapterId: nextChapter,
          );
          if (generation != _generation) return;
          _paragraphs = content;
          _paragraphIndex = content.indexWhere((p) => _id(p) == paragraphId);
          if (_paragraphIndex < 0) {
            _paragraphIndex = content.indexWhere(
              (p) => sameOriginalParagraph(_id(p), paragraphId),
            );
            if (_paragraphIndex < 0) _paragraphIndex = 0;
          }
        }
        while (generation == _generation &&
            _paragraphIndex < _paragraphs.length) {
          final paragraph = _paragraphs[_paragraphIndex];
          final text = switch (paragraph) {
            ParagraphContent_Text(:final content) => content,
            ParagraphContent_Title(:final text) => text,
            _ => '',
          };
          if (text.trim().isEmpty) {
            _paragraphIndex++;
            continue;
          }
          paragraphId = _id(paragraph);
          status = ListeningStatus.playing;
          error = null;
          notifyListeners();
          await _save();
          for (final chunk in speechChunks(text)) {
            if (generation != _generation) return;
            final sentence = text.substring(chunk.start, chunk.end);
            if (sentence.trim().isEmpty) continue;
            await _engine
                .speak(sentence, voice!, rate)
                .timeout(const Duration(minutes: 3));
            if (generation != _generation) return;
          }
          _paragraphIndex++;
        }
        _chapterIndex++;
        _paragraphs = [];
      }
      if (generation == _generation) {
        status = ListeningStatus.completed;
        notifyListeners();
      }
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  Future<void> pause() async {
    if (!active) return;
    final generation = ++_generation;
    status = ListeningStatus.paused;
    notifyListeners();
    try {
      await _engine.stop();
      if (generation != _generation) return;
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  void resume() {
    if (active || feedId.isEmpty) return;
    // Reading progress is the only resume position, including manual reading
    // that happened while speech was paused.
    unawaited(start(feedId: feedId, bookId: bookId));
  }

  Future<void> stop() async {
    final generation = ++_generation;
    status = ListeningStatus.idle;
    _sleepTimer?.cancel();
    sleepDeadline = null;
    notifyListeners();
    try {
      await _engine.stop();
      if (generation != _generation) return;
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  Future<void> moveParagraph(int delta) async {
    await pause();
    if (_paragraphs.isEmpty) return;
    _paragraphIndex = (_paragraphIndex + delta).clamp(
      0,
      _paragraphs.length - 1,
    );
    paragraphId = _id(_paragraphs[_paragraphIndex]);
    await start(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphId: paragraphId,
    );
  }

  Future<void> configure({LocalVoice? voice, double? rate}) async {
    final configuration = ++_configuration;
    final playing = active;
    await pause();
    if (configuration != _configuration) return;
    if (voice != null) this.voice = voice;
    if (rate != null) this.rate = rate.clamp(0.5, 2.0);
    notifyListeners();
    if (playing) resume();
  }

  void previewRate(double value) {
    rate = value.clamp(0.5, 2);
    notifyListeners();
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    sleepDeadline = duration == null ? null : DateTime.now().add(duration);
    if (duration != null) {
      _sleepTimer = Timer(duration, () {
        sleepDeadline = null;
        unawaited(pause());
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _save() async {
    if (feedId.isEmpty || chapterId.isEmpty) return;
    await _service.setReadingProgress(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
      paragraphId: paragraphId,
      paragraphCharOffset: 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _fail(Object e) {
    ++_generation;
    status = ListeningStatus.error;
    error = e;
    unawaited(_engine.stop().catchError((Object _) {}));
    notifyListeners();
  }

  static String _id(ParagraphContent p) => switch (p) {
    ParagraphContent_Text(:final id) ||
    ParagraphContent_Title(:final id) ||
    ParagraphContent_Image(:final id) => id.toStringValue(),
  };
  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _sleepTimer?.cancel();
    unawaited(_engine.stop().catchError((Object _) {}));
    super.dispose();
  }
}
