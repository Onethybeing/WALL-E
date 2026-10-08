import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, VoidCallback;
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine.dart' show BuiltInKeyword;
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

/// TODO: paste a free AccessKey from https://console.picovoice.ai here before
/// this will actually run. Using a built-in keyword for now ("computer") as
/// a placeholder -- train a custom "Hey WALL-E" model on the same console
/// once this is confirmed working, then swap fromBuiltInKeywords for
/// fromKeywordPaths pointing at the trained .ppn file.
const String _picovoiceAccessKey = 'YOUR_PICOVOICE_ACCESS_KEY_HERE';

/// Always-on wake-word listening ("Hey WALL-E" once a custom model is
/// trained). Android/iOS only -- Porcupine has no web implementation.
class WakeWordListener {
  WakeWordListener({required this.onWake});

  final VoidCallback onWake;
  PorcupineManager? _manager;

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (!isSupported) return;
    if (_picovoiceAccessKey == 'YOUR_PICOVOICE_ACCESS_KEY_HERE') {
      // Not configured yet -- fail quietly rather than crash the app, since
      // the rest of the pet works fine without wake-word detection.
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) return;

    try {
      _manager = await PorcupineManager.fromBuiltInKeywords(
        _picovoiceAccessKey,
        [BuiltInKeyword.COMPUTER],
        (keywordIndex) => onWake(),
      );
      await _manager!.start();
    } on PorcupineException catch (_) {
      // Bad access key, unsupported device, etc -- degrade silently, same
      // reasoning as above: wake-word is a nice-to-have, not core function.
      _manager = null;
    }
  }

  Future<void> stop() async {
    await _manager?.stop();
    await _manager?.delete();
    _manager = null;
  }
}
