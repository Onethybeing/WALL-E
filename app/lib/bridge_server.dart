import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';

// Voice-activity detection for /listen -- see _handleListen. RMS is
// measured on real signed 16-bit PCM samples (range +-32768); the actual
// speech threshold is calibrated per-recording, not a fixed constant here.
const Duration _calibrationWindow = Duration(milliseconds: 500);
const double _silenceSecondsToStop = 1.2;

// Shared with MainActivity.kt for anything that needs a native Android API
// Termux can't reach itself -- media key dispatch and the alarm clock intent.
const _platformChannel = MethodChannel('com.sourav.walle/media');

// Standard Android media key codes -- matches tools.py's media_control()
// action names (play_pause/next/previous) so the two sides agree.
const Map<String, int> _mediaKeyCodes = {
  'play_pause': 85, // KEYCODE_MEDIA_PLAY_PAUSE
  'next': 87, // KEYCODE_MEDIA_NEXT
  'previous': 88, // KEYCODE_MEDIA_PREVIOUS
};

/// A tiny local HTTP server so the Python brain (running in Termux on the
/// same phone) can ask the Flutter app to take a photo or get a GPS fix --
/// and, the other direction, so the brain can tell the eyes what it's
/// currently doing (thinking/searching/speaking/taking a photo) so they can
/// react in real time.
///
/// This exists because Termux:API's own Camera and Location commands are
/// broken on a sideloaded (non-Play-Store) install -- see tools.py's
/// analyze_photo/get_location docstrings. Since this is all loopback
/// (127.0.0.1), it also completely sidesteps the mobile-hotspot client
/// isolation that broke wireless adb -- nothing here leaves the device.
class BridgeServer {
  static const int port = 8099;

  /// Current agent activity, pushed by the Python brain via POST /mood.
  /// One of: idle, thinking, searching, speaking, taking_photo (see
  /// brain/mood_bridge.py's VALID_STATES -- keep these two lists in sync).
  /// main.dart listens to this to drive the eyes' visual state.
  final ValueNotifier<String> moodNotifier = ValueNotifier<String>('idle');

  // CameraX (which the `camera` plugin uses under the hood) refuses to bind
  // two independent CameraController sessions at once on this hardware --
  // face_tracking.dart's front-camera stream being live caused takePicture()
  // here to fail with "ImageCaptureException: Not bound to a valid Camera".
  // main.dart wires these to pause/resume its FaceTracker around a photo.
  Future<void> Function()? pauseFaceCamera;
  Future<void> Function()? resumeFaceCamera;

  // Lets a second tap during /listen end the recording immediately,
  // alongside (not instead of) silence-based auto-stop -- see
  // _handleListen and main.dart's onTap. Needed because this device's mic
  // noise floor never fully quiets down (confirmed via direct RMS
  // measurement: stays elevated the whole recording, with no reliable
  // silence gap for VAD to detect), so automatic stopping alone isn't
  // trustworthy here. Null whenever no /listen call is in flight.
  Completer<void>? _activeListenStop;

  void stopListening() {
    final completer = _activeListenStop;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  HttpServer? _server;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/location') {
        await _handleLocation(request);
      } else if (request.uri.path == '/photo') {
        await _handlePhoto(request);
      } else if (request.uri.path == '/mood' && request.method == 'POST') {
        await _handleMood(request);
      } else if (request.uri.path == '/media' && request.method == 'POST') {
        await _handleMedia(request);
      } else if (request.uri.path == '/alarm' && request.method == 'POST') {
        await _handleAlarm(request);
      } else if (request.uri.path == '/listen') {
        await _handleListen(request);
      } else if (request.uri.path == '/screen/gesture' && request.method == 'POST') {
        await _handleScreenGesture(request);
      } else if (request.uri.path == '/screen/action' && request.method == 'POST') {
        await _handleScreenAction(request);
      } else if (request.uri.path == '/screen/text') {
        await _handleScreenText(request);
      } else if (request.uri.path == '/screen/tap_text' && request.method == 'POST') {
        await _handleScreenTapText(request);
      } else if (request.uri.path == '/app/open' && request.method == 'POST') {
        await _handleOpenAppByName(request);
      } else if (request.uri.path == '/accessibility/status') {
        await _handleAccessibilityStatus(request);
      } else if (request.uri.path == '/accessibility/request' && request.method == 'POST') {
        await _handleAccessibilityRequest(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('error: $e');
      await request.response.close();
    }
  }

  Future<void> _handleMood(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final state = data['state'];
    if (state is! String || state.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: missing "state" string in body');
      await request.response.close();
      return;
    }
    moodNotifier.value = state;
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> _handleMedia(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final action = data['action'];
    final keyCode = _mediaKeyCodes[action];
    if (keyCode == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: unknown action "$action"');
      await request.response.close();
      return;
    }
    await _platformChannel.invokeMethod('dispatchMediaKey', {'keyCode': keyCode});
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> _handleAlarm(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final hour = data['hour'];
    final minute = data['minute'];
    if (hour is! int || minute is! int) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: "hour" and "minute" must be integers');
      await request.response.close();
      return;
    }
    await _platformChannel.invokeMethod('setAlarm', {
      'hour': hour,
      'minute': minute,
      'label': data['label'] ?? '',
    });
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  /// Screen dimensions in physical pixels -- the same coordinate space
  /// AccessibilityService's gesture dispatch expects, so callers send x/y
  /// as 0.0-1.0 fractions of the screen (brain/tools.py's control_screen)
  /// rather than needing to know this device's actual resolution.
  (double, double) _screenSizePx() {
    final view = ui.PlatformDispatcher.instance.views.first;
    return (view.physicalSize.width, view.physicalSize.height);
  }

  Future<void> _handleScreenGesture(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final x1 = (data['x1'] as num?)?.toDouble();
    final y1 = (data['y1'] as num?)?.toDouble();
    final x2 = (data['x2'] as num?)?.toDouble() ?? x1;
    final y2 = (data['y2'] as num?)?.toDouble() ?? y1;
    final durationMs = (data['duration_ms'] as num?)?.toInt() ?? 50;
    if (x1 == null || y1 == null || x2 == null || y2 == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: x1/y1 are required (x2/y2 default to x1/y1 for a tap)');
      await request.response.close();
      return;
    }
    final (w, h) = _screenSizePx();
    final ok = await _platformChannel.invokeMethod<bool>('a11yGesture', {
      'x1': x1 * w, 'y1': y1 * h, 'x2': x2 * w, 'y2': y2 * h, 'durationMs': durationMs,
    });
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ok': ok ?? false}));
    await request.response.close();
  }

  Future<void> _handleScreenAction(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final action = data['action'];
    if (action is! String) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: "action" must be one of back/home/recents/notifications');
      await request.response.close();
      return;
    }
    final ok = await _platformChannel.invokeMethod<bool>('a11yGlobalAction', {'action': action});
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ok': ok ?? false}));
    await request.response.close();
  }

  Future<void> _handleScreenText(HttpRequest request) async {
    final text = await _platformChannel.invokeMethod<String>('a11yScreenText');
    request.response.write(text ?? '');
    await request.response.close();
  }

  Future<void> _handleScreenTapText(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final text = data['text'];
    if (text is! String || text.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: "text" is required');
      await request.response.close();
      return;
    }
    final ok = await _platformChannel.invokeMethod<bool>('a11yFindAndTap', {'text': text});
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ok': ok ?? false}));
    await request.response.close();
  }

  Future<void> _handleOpenAppByName(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final name = data['name'];
    if (name is! String || name.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('error: "name" is required');
      await request.response.close();
      return;
    }
    final ok = await _platformChannel.invokeMethod<bool>('openAppByName', {'name': name});
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ok': ok ?? false}));
    await request.response.close();
  }

  Future<void> _handleAccessibilityStatus(HttpRequest request) async {
    final enabled = await _platformChannel.invokeMethod<bool>('isAccessibilityServiceEnabled');
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'enabled': enabled ?? false}));
    await request.response.close();
  }

  Future<void> _handleAccessibilityRequest(HttpRequest request) async {
    await _platformChannel.invokeMethod('openAccessibilitySettings');
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> _handleLocation(HttpRequest request) async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
    );
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
    }));
    await request.response.close();
  }

  Future<void> _handlePhoto(HttpRequest request) async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    // Free up the camera hardware from face_tracking.dart's front-camera
    // stream first -- see the pauseFaceCamera/resumeFaceCamera doc comment.
    await pauseFaceCamera?.call();
    try {
      final controller = CameraController(back, ResolutionPreset.medium, enableAudio: false);
      await controller.initialize();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      await controller.dispose();

      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.add(bytes);
      await request.response.close();
    } finally {
      await resumeFaceCamera?.call();
    }
  }

  /// Records from the mic and returns real linear-PCM WAV bytes, stopping
  /// ~1.2s after speech trails off (or at max_seconds, default 15).
  ///
  /// Replaces Termux:API's `termux-microphone-record` for the same reason
  /// /photo and /location replace their Termux:API equivalents: `adb shell
  /// cmd appops get com.termux.api` shows RECORD_AUDIO capped at AppOps
  /// mode "foreground" at the *uid* level on this device/ROM (can't be
  /// overridden per-package -- tried), which silently returns empty/zeroed
  /// audio instead of erroring, so termux-microphone-record "succeeds"
  /// while actually capturing nothing. Confirmed this app's own
  /// RECORD_AUDIO AppOps is a healthy "allow" by contrast.
  ///
  /// Uses raw PCM streaming (`startStream`) rather than the plugin's own
  /// file-based `AudioEncoder.wav` writer -- that path produced a WAV file
  /// with a perfectly valid, self-consistent header (confirmed: correct
  /// RIFF/data chunk sizes, 16kHz/mono/16-bit as requested) but garbage
  /// sample data, which played back as pure static despite registering
  /// real RMS energy on the meter. `startStream(AudioEncoder.pcm16bits)`
  /// is the same capture path wake_word.dart already used successfully
  /// (that feature's native crash was in sherpa-onnx's inference, never in
  /// this capture step), so this reuses it and builds the WAV container
  /// by hand instead of trusting the plugin's file writer.
  Future<void> _handleListen(HttpRequest request) async {
    final maxSeconds = int.tryParse(request.uri.queryParameters['max_seconds'] ?? '') ?? 15;
    final recorder = AudioRecorder();
    if (!await recorder.hasPermission()) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('error: microphone permission not granted');
      await request.response.close();
      return;
    }

    final pcm = BytesBuilder(copy: false);
    var heardSpeech = false;
    var silenceSeconds = 0.0;
    final doneCompleter = Completer<void>();
    _activeListenStop = doneCompleter;

    // A fixed RMS threshold doesn't generalize across devices/mic gain --
    // measured this device's own raw-PCM noise floor sitting at ~900-1600,
    // well above a reasonable guessed threshold, so silence was never
    // detected and every recording ran the full max_seconds (confirmed
    // live). Instead, calibrate against this recording's own first
    // _calibrationWindow of audio (assumed to be near-silence, since
    // real-world use starts the mic right as the user taps to speak, not
    // mid-sentence) and set the threshold proportionally above that.
    final calibrationRms = <double>[];
    double? speechThreshold;
    final recordingClock = Stopwatch()..start();

    final stream = await recorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
    );
    late final StreamSubscription<Uint8List> sub;
    sub = stream.listen((chunk) {
      pcm.add(chunk);
      final rms = _pcm16Rms(chunk);

      if (speechThreshold == null) {
        calibrationRms.add(rms);
        if (recordingClock.elapsed >= _calibrationWindow) {
          final noiseFloor = calibrationRms.reduce((a, b) => a + b) / calibrationRms.length;
          speechThreshold = (noiseFloor * 2.2).clamp(400.0, 3000.0);
        }
        return; // VAD doesn't evaluate until calibration finishes
      }

      if (rms > speechThreshold!) {
        heardSpeech = true;
        silenceSeconds = 0;
      } else if (heardSpeech) {
        // Chunk duration varies by platform, so measure it rather than
        // assuming a fixed size like the old amplitude-poll version did.
        silenceSeconds += chunk.length / 2 / 16000;
        if (silenceSeconds >= _silenceSecondsToStop) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        }
      }
    });

    final timeout = Future.delayed(Duration(seconds: maxSeconds));
    await Future.any([doneCompleter.future, timeout]);
    if (identical(_activeListenStop, doneCompleter)) _activeListenStop = null;
    await sub.cancel();
    await recorder.stop();

    final wavBytes = _wrapPcmAsWav(pcm.takeBytes(), sampleRate: 16000, numChannels: 1);
    request.response.headers.contentType = ContentType('audio', 'wav');
    request.response.add(wavBytes);
    await request.response.close();
  }

  double _pcm16Rms(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount == 0) return 0;
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final s = data.getInt16(i * 2, Endian.little);
      sumSquares += s * s;
    }
    return math.sqrt(sumSquares / sampleCount);
  }

  Uint8List _wrapPcmAsWav(Uint8List pcmBytes, {required int sampleRate, required int numChannels}) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final header = BytesBuilder();
    void writeString(String s) => header.add(ascii.encode(s));
    void writeUint32(int v) => header.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void writeUint16(int v) => header.add([v & 0xff, (v >> 8) & 0xff]);

    writeString('RIFF');
    writeUint32(36 + pcmBytes.length);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(numChannels);
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    writeString('data');
    writeUint32(pcmBytes.length);

    final out = BytesBuilder();
    out.add(header.takeBytes());
    out.add(pcmBytes);
    return out.takeBytes();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    moodNotifier.dispose();
  }
}
