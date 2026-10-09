import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, VoidCallback, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Always-on wake-word listening for "Hey WALL E", via sherpa-onnx's
/// open-vocabulary keyword spotter (assets/sherpa_kws/ -- a small zipformer
/// transducer trained on GigaSpeech, Apache-2.0). Unlike Porcupine, this
/// needs no per-keyword training or account: the keyword is just a line of
/// BPE-tokenized text (keywords.txt) matched against a generic acoustic
/// model. Android/iOS only.
class WakeWordListener {
  WakeWordListener({required this.onWake});

  final VoidCallback onWake;

  sherpa_onnx.KeywordSpotter? _spotter;
  sherpa_onnx.OnlineStream? _stream;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  bool _bindingsReady = false;

  // The model expects waveform fed in a fixed chunk size (matching the
  // official sherpa-onnx Dart example's 1600 samples = 0.1s @16kHz) --
  // feeding it whatever irregular chunk sizes the live mic stream happens
  // to deliver crashes the native side with a reshape error inside the
  // encoder's internal cache handling. So we buffer raw samples here and
  // only ever call acceptWaveform in exact 1600-sample increments.
  static const int _chunkSize = 1600;
  final List<double> _sampleBuffer = [];

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (!isSupported) return;

    try {
      if (!await _recorder.hasPermission()) return;

      if (!_bindingsReady) {
        sherpa_onnx.initBindings();
        _bindingsReady = true;
      }

      final modelConfig = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: await _copyAsset('assets/sherpa_kws/encoder.onnx'),
          decoder: await _copyAsset('assets/sherpa_kws/decoder.onnx'),
          joiner: await _copyAsset('assets/sherpa_kws/joiner.onnx'),
        ),
        tokens: await _copyAsset('assets/sherpa_kws/tokens.txt'),
        numThreads: 1,
      );
      final config = sherpa_onnx.KeywordSpotterConfig(
        model: modelConfig,
        keywordsFile: await _copyAsset('assets/sherpa_kws/keywords.txt'),
      );
      _spotter = sherpa_onnx.KeywordSpotter(config);
      _stream = _spotter!.createStream();

      final audioStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
      );
      _audioSub = audioStream.listen(_onAudio);
    } catch (e) {
      // Model failed to load, mic denied, unsupported device, etc -- wake
      // word is a nice-to-have, the rest of the pet works fine without it.
      debugPrint('WakeWordListener failed to start: $e');
      await stop();
    }
  }

  void _onAudio(Uint8List bytes) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return;

    _sampleBuffer.addAll(_pcm16ToFloat32(bytes));

    while (_sampleBuffer.length >= _chunkSize) {
      final chunk = Float32List.fromList(_sampleBuffer.sublist(0, _chunkSize));
      _sampleBuffer.removeRange(0, _chunkSize);

      stream.acceptWaveform(samples: chunk, sampleRate: 16000);
      while (spotter.isReady(stream)) {
        spotter.decode(stream);
        final result = spotter.getResult(stream);
        if (result.keyword.isNotEmpty) {
          spotter.reset(stream);
          onWake();
        }
      }
    }
  }

  Float32List _pcm16ToFloat32(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final out = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  Future<String> _copyAsset(String assetPath) async {
    final dir = await getApplicationSupportDirectory();
    final target = p.join(dir.path, p.basename(assetPath));
    final data = await rootBundle.load(assetPath);
    final targetFile = File(target);
    if (!await targetFile.exists() || await targetFile.length() != data.lengthInBytes) {
      await targetFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    return target;
  }

  Future<void> stop() async {
    await _audioSub?.cancel();
    _audioSub = null;
    _sampleBuffer.clear();
    await _recorder.stop();
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}
