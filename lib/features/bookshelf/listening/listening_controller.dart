import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../src/rust/api/types.dart';
import '../../feeds/feed_service.dart';
import 'local_speech_engine.dart';

enum ListeningStatus { idle, loading, playing, paused, completed, error }

class ListeningController extends ChangeNotifier {
  ListeningController(this._service, this._engine, {this.preparePlayback}) {
    _restoreSettings();
  }
  final FeedService _service;
  final SpeechEngine _engine;
  final Future<void> Function()? preparePlayback;
  bool _resumeAfterConfiguration = false;
  int _generation = 0;
  int _configuration = 0;
  bool _disposed = false;
  Future<void>? _voiceLoad;
  bool voicesLoading = false;
  Object? voicesError;
  Timer? _sleepTimer;
  DateTime? sleepDeadline;
  Duration? sleepDuration;

  /// One-shot sleep mode: stop after the current chapter finishes instead
  /// of advancing. Cleared once it fires.
  bool sleepAtChapterEnd = false;
  ListeningStatus status = ListeningStatus.idle;
  Object? error;
  String feedId = '', bookId = '', chapterId = '', paragraphId = '';
  String bookTitle = '';
  List<ChapterInfoModel> _chapters = [];
  List<ParagraphContent> _paragraphs = [];
  int _chapterIndex = 0, _paragraphIndex = 0;
  List<LocalVoice> voices = [];
  LocalVoice? voice;
  double rate = 1;

  // Single-slot next-chapter prefetch: one in-flight (or completed) fetch
  // for the chapter after the one now playing. Errors are swallowed and
  // re-fetched inline when the slot is consumed.
  String? _prefetchChapterId;
  Future<List<ParagraphContent>>? _prefetchFuture;

  // Persisted settings (SharedPreferences, best-effort).
  static const _rateKey = 'listening.rate';
  static const _voiceIdKey = 'listening.voiceId';
  static const _voiceLocaleKey = 'listening.voiceLocale';
  LocalVoiceKey? _persistedVoiceKey;

  bool get canMoveParagraph => _paragraphs.isNotEmpty;
  bool get active =>
      status == ListeningStatus.playing || status == ListeningStatus.loading;
  bool ownsBook(String feed, String book) =>
      active && feedId == feed && bookId == book;

  /// Display title of the current chapter, '' while chapters are loading.
  String get chapterTitle =>
      _chapterIndex >= 0 && _chapterIndex < _chapters.length
      ? _chapters[_chapterIndex].title
      : '';

  /// 1-based position within the current chapter (0 while unavailable).
  int get paragraphPosition => _paragraphs.isEmpty ? 0 : _paragraphIndex + 1;
  int get paragraphTotal => _paragraphs.length;

  /// Fraction of the current chapter's paragraphs already spoken.
  double get chapterProgress => status == ListeningStatus.completed
      ? 1
      : _paragraphs.isEmpty
      ? 0
      : (_paragraphIndex / _paragraphs.length).clamp(0.0, 1.0);

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
          voices.where((v) => v.key == _persistedVoiceKey).firstOrNull ??
          voices.where((v) => v.key == voice?.key).firstOrNull ??
          voices.first;
      _persistedVoiceKey = voice!.key;
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
    String bookTitle = '',
  }) async {
    ++_configuration;
    _resumeAfterConfiguration = false;
    final generation = ++_generation;
    try {
      await _engine.stop();
      if (generation != _generation) return;
      this.feedId = feedId;
      this.bookId = bookId;
      this.chapterId = chapterId;
      this.paragraphId = paragraphId;
      this.bookTitle = bookTitle;
      _paragraphs = [];
      _chapters = [];
      _clearPrefetch();
      status = ListeningStatus.loading;
      error = null;
      notifyListeners();
      if (voices.isEmpty || voicesError != null || _voiceLoad != null) {
        await loadVoices();
      }
      if (generation != _generation) return;
      if (voicesError case final failure?) throw failure;
      await preparePlayback?.call();
      if (generation != _generation) return;
      // Reading progress and the chapter list are independent — fetch both
      // in parallel so first sound only waits for the slower of the two.
      final (saved, chapters) = await (
        chapterId.isEmpty
            ? _service.getReadingProgress(feedId: feedId, bookId: bookId)
            : Future<ReadingProgressModel?>.value(),
        _service.chapters(feedId: feedId, bookId: bookId),
      ).wait;
      if (generation != _generation) return;
      if (saved != null) {
        this.chapterId = saved.chapterId;
        this.paragraphId = saved.paragraphId;
      }
      _chapters = chapters;
      _chapterIndex = chapters.indexWhere((c) => c.id == this.chapterId);
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
          sleepDuration = null;
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
          final content = await _takeParagraphs(nextChapter);
          if (generation != _generation) return;
          _paragraphs = content;
          _syncParagraphIndex();
        }
        _kickPrefetch(generation);
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
        if (sleepAtChapterEnd &&
            generation == _generation &&
            _chapterIndex < _chapters.length) {
          // One-shot: fires at the first chapter boundary reached.
          sleepAtChapterEnd = false;
          await pause();
          return;
        }
      }
      if (generation == _generation) {
        status = ListeningStatus.completed;
        notifyListeners();
      }
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  Future<void> pause() {
    ++_configuration;
    _resumeAfterConfiguration = false;
    return _pausePlayback();
  }

  Future<void> _pausePlayback() async {
    if (!active) return;
    final generation = ++_generation;
    // Keep _chapters/_paragraphs/indices: a later resume() re-enters
    // playback from memory instead of re-fetching everything.
    status = ListeningStatus.paused;
    notifyListeners();
    try {
      await _engine.stop();
      if (generation != _generation) return;
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  Future<void> resume() async {
    if (active || feedId.isEmpty) return;
    // Fast path: the paused session is still in memory. Reading progress is
    // the resume position — including manual reading done while paused — so
    // coordinate with one cheap database read, relocate in memory, and
    // re-enter playback without re-fetching chapters or paragraphs.
    if (status == ListeningStatus.paused &&
        _chapters.isNotEmpty &&
        chapterId.isNotEmpty) {
      final generation = ++_generation;
      status = ListeningStatus.loading;
      notifyListeners();
      try {
        await preparePlayback?.call();
        if (generation != _generation) return;
        final saved = await _service.getReadingProgress(
          feedId: feedId,
          bookId: bookId,
        );
        if (generation != _generation) return;
        if (saved != null && saved.chapterId != chapterId) {
          final savedIndex = _chapters.indexWhere(
            (c) => c.id == saved.chapterId,
          );
          if (savedIndex < 0) {
            // Chapter not in the retained list — full restart.
            await start(feedId: feedId, bookId: bookId, bookTitle: bookTitle);
            return;
          }
          _chapterIndex = savedIndex;
          _paragraphs = [];
          chapterId = saved.chapterId;
          paragraphId = saved.paragraphId;
        } else if (saved != null && saved.paragraphId != paragraphId) {
          paragraphId = saved.paragraphId;
          _syncParagraphIndex();
        }
        _resumeFromMemory(generation);
        return;
      } catch (e) {
        if (generation == _generation) _fail(e);
        return;
      }
    }
    await start(feedId: feedId, bookId: bookId, bookTitle: bookTitle);
  }

  Future<void> stop() async {
    ++_configuration;
    _resumeAfterConfiguration = false;
    final generation = ++_generation;
    status = ListeningStatus.idle;
    _sleepTimer?.cancel();
    sleepDeadline = null;
    sleepDuration = null;
    sleepAtChapterEnd = false;
    _paragraphs = [];
    _chapters = [];
    _clearPrefetch();
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
    // Explicit jump: re-enter from memory without progress coordination.
    _resumeFromMemory(++_generation);
  }

  Future<void> configure({LocalVoice? voice, double? rate}) async {
    final configuration = ++_configuration;
    _resumeAfterConfiguration = active || _resumeAfterConfiguration;
    await _pausePlayback();
    if (configuration != _configuration) return;
    if (voice != null) {
      this.voice = voice;
      _persistedVoiceKey = voice.key;
    }
    if (rate != null) this.rate = rate.clamp(0.5, 2.0);
    _persistSettings();
    notifyListeners();
    final shouldResume = _resumeAfterConfiguration;
    _resumeAfterConfiguration = false;
    if (shouldResume) await resume();
  }

  /// Discard transformed content while retaining the shared paragraph position.
  Future<void> invalidateContent() async {
    final wasPlaying = active;
    final pendingPause = pause();
    final generation = _generation;
    await pendingPause;
    if (_disposed || generation != _generation) return;
    _paragraphs = [];
    _clearPrefetch();
    notifyListeners();
    if (wasPlaying) await resume();
  }

  void previewRate(double value) {
    rate = value.clamp(0.5, 2);
    notifyListeners();
  }

  void setSleepTimer(Duration? duration, {bool atChapterEnd = false}) {
    _sleepTimer?.cancel();
    sleepDeadline = null;
    sleepDuration = null;
    sleepAtChapterEnd = atChapterEnd;
    if (duration != null) {
      sleepDuration = duration;
      sleepDeadline = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        sleepDeadline = null;
        sleepDuration = null;
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

  /// Point [_paragraphIndex] at [paragraphId] within [_paragraphs].
  void _syncParagraphIndex() {
    _paragraphIndex = _paragraphs.indexWhere((p) => _id(p) == paragraphId);
    if (_paragraphIndex < 0) {
      _paragraphIndex = _paragraphs.indexWhere(
        (p) => sameOriginalParagraph(_id(p), paragraphId),
      );
      if (_paragraphIndex < 0) _paragraphIndex = 0;
    }
  }

  /// Re-enter playback from the in-memory chapter/paragraph state without
  /// re-fetching. [generation] must be current.
  void _resumeFromMemory(int generation) {
    status = ListeningStatus.loading;
    error = null;
    notifyListeners();
    unawaited(_run(generation));
  }

  /// Start prefetching the chapter after the current one, if any, while the
  /// network would otherwise idle during playback.
  void _kickPrefetch(int generation) {
    final nextIndex = _chapterIndex + 1;
    if (nextIndex >= _chapters.length) return;
    final nextId = _chapters[nextIndex].id;
    if (_prefetchChapterId == nextId) return;
    _prefetchChapterId = nextId;
    final future = _service.paragraphs(
      feedId: feedId,
      bookId: bookId,
      chapterId: nextId,
    );
    _prefetchFuture = future;
    // A prefetch nobody consumes (stop, failure, pause without resume) must
    // not surface as an unhandled async error.
    future.ignore();
  }

  /// Consume the prefetch slot for [chapterId] if it matches, otherwise (or
  /// after a failed prefetch) fetch directly so errors surface normally.
  Future<List<ParagraphContent>> _takeParagraphs(String chapterId) async {
    final future = _prefetchChapterId == chapterId ? _prefetchFuture : null;
    _clearPrefetch();
    if (future != null) {
      try {
        return await future;
      } catch (_) {
        // Prefetch failures are silent; the direct fetch below reports them.
      }
    }
    return _service.paragraphs(
      feedId: feedId,
      bookId: bookId,
      chapterId: chapterId,
    );
  }

  void _clearPrefetch() {
    _prefetchChapterId = null;
    _prefetchFuture = null;
  }

  Future<void> _restoreSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final savedRate = prefs.getDouble(_rateKey);
      if (savedRate != null) rate = savedRate.clamp(0.5, 2.0);
      final voiceId = prefs.getString(_voiceIdKey);
      final voiceLocale = prefs.getString(_voiceLocaleKey);
      if (voiceId != null && voiceLocale != null) {
        _persistedVoiceKey = (id: voiceId, locale: voiceLocale);
      }
      notifyListeners();
    } catch (_) {
      // Persistence is best-effort: fresh installs and environments without
      // a SharedPreferences implementation start from defaults.
    }
  }

  void _persistSettings() {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_rateKey, rate);
        final key = voice?.key;
        if (key != null) {
          await prefs.setString(_voiceIdKey, key.id);
          await prefs.setString(_voiceLocaleKey, key.locale);
        }
      } catch (_) {
        // Best-effort persistence.
      }
    }());
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
    ++_configuration;
    _resumeAfterConfiguration = false;
    ++_generation;
    _sleepTimer?.cancel();
    unawaited(_engine.stop().catchError((Object _) {}));
    super.dispose();
  }
}
