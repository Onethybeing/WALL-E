import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, VoidCallback, debugPrint;
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Wake-word listening, take 3. Two earlier approaches were tried and
/// dropped:
/// - sherpa-onnx's native keyword spotter crashed reproducibly (Ort::Exception
///   reshape error, SIGABRT) -- a genuine model/runtime incompatibility, not
///   fixable from our integration code.
/// - Porcupine's Flutter plugin still hardcodes `compileSdkVersion 31` in its
///   current (Dec 2025) release, conflicting with camera/mlkit's AndroidX
///   requirements -- re-checked the actual GitHub source, still unfixed
///   upstream.
///
/// This uses `speech_to_text`, a thin wrapper around Android's own
/// SpeechRecognizer -- no native model to crash, no compileSdk conflict
/// (it only needs 31+, which this app already has). Its own docs say it
/// doesn't support true continuous listening, so this works around that by
/// restarting the listen session every time it stops (on "done" or
/// "notListening" status) -- not a perfect always-on listener (there's a
/// brief gap between sessions, and each session is capped by Android's own
/// speech-timeout), but good enough for "say the wake word, then talk."
class WakeWordListener {
  WakeWordListener({required this.onWake});

  final VoidCallback onWake;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  bool _running = false; // true once start() succeeds, false after stop()
  bool _paused = false; // true while a real voice turn owns the mic
  Timer? _restartTimer;
  int _consecutiveErrors = 0;

  static const List<String> _wakePhrases = [
    'wall-e', 'wall e', 'walle', 'hey wall-e', 'hey wall e', 'hey walle',
  ];

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (!isSupported || _running) return;
    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onStatus: _onStatus,
          onError: _onError,
        );
      }
      if (!_initialized) return;
      _running = true;
      await _listenOnce();
    } catch (e) {
      // Mic denied, unsupported device, etc -- wake word is a nice-to-have,
      // the rest of the pet works fine without it.
      debugPrint('WakeWordListener failed to start: $e');
      _running = false;
    }
  }

  Future<void> _listenOnce() async {
    if (!_running || _paused) return;
    await _speech.listen(
      onResult: _onResult,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      cancelOnError: true,
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  void _onResult(dynamic result) {
    _consecutiveErrors = 0;
    final heard = (result.recognizedWords as String).toLowerCase();
    if (_wakePhrases.any((phrase) => heard.contains(phrase))) {
      onWake();
    }
  }

  void _onError(dynamic error) {
    // Android's SpeechRecognizer throws error_busy if a new session starts
    // before the previous one has fully torn down, and error_client for a
    // handful of other transient reasons -- restarting immediately on every
    // status change (the original approach) caused a tight restart storm
    // that just regenerated the same errors (confirmed live: dozens of
    // error_busy/error_client lines a second in logcat). The exponential
    // backoff below, capped at 5s, lets the recognizer actually settle.
    debugPrint('WakeWordListener error: ${error.errorMsg}');
    _consecutiveErrors++;
  }

  void _onStatus(String status) {
    // Android's SpeechRecognizer stops itself after a timeout or a pause in
    // speech -- starting a new session (after a short settle delay) is what
    // approximates "always listening" here, since the package itself has no
    // built-in continuous mode (see class doc comment).
    if ((status == stt.SpeechToText.doneStatus || status == stt.SpeechToText.notListeningStatus) &&
        _running && !_paused) {
      _scheduleRestart();
    }
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    final backoffMs = (300 * (1 << _consecutiveErrors.clamp(0, 4))).clamp(300, 5000);
    _restartTimer = Timer(Duration(milliseconds: backoffMs), _listenOnce);
  }

  /// Frees the mic for a real voice turn (tap or wake-word triggered) --
  /// speech_to_text's own docs warn the mic can't be shared between it and
  /// another recorder at the same time. Call [resume] once the voice turn
  /// (listen -> think -> speak, possibly several conversational hops) is
  /// fully done -- main.dart does this by watching the brain's mood return
  /// to "idle".
  Future<void> pause() async {
    if (!_running) return;
    _paused = true;
    _restartTimer?.cancel();
    await _speech.cancel();
  }

  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    _consecutiveErrors = 0;
    await _listenOnce();
  }

  Future<void> stop() async {
    _running = false;
    _paused = false;
    _restartTimer?.cancel();
    await _speech.cancel();
  }
}
