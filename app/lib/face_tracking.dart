import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

/// Watches the front camera and reports where the nearest face is, as an
/// offset in -1..1 on each axis (same convention the Eye painter already
/// uses for lookOffset) -- so the pet's eyes can track a real person instead
/// of just drifting randomly.
///
/// Android/iOS only: google_mlkit_face_detection has no web implementation,
/// so callers must not construct this on web (see kIsWeb checks in main.dart).
class FaceTracker {
  FaceTracker({required this.onFaceOffset});

  final void Function(Offset) onFaceOffset;

  CameraController? _controller;
  FaceDetector? _detector;
  bool _busy = false;

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (!isSupported) return;

    final status = await Permission.camera.request();
    if (!status.isGranted) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) return; // no camera hardware/permission -- nothing to track with
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _detector = FaceDetector(
      options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate),
    );

    _controller = CameraController(
      front,
      // "low" produced a visibly imprecise/laggy-feeling track -- medium
      // gives ML Kit enough resolution to place the bounding box accurately
      // while still being far cheaper than anything close to full-res.
      ResolutionPreset.medium,
      enableAudio: false,
      // Force single-plane NV21 output on Android so _toInputImage's
      // plane-concatenation logic is valid -- the platform default is
      // YUV_420_888 (3 planes with independent strides), which it is not.
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _controller!.initialize();
    await _controller!.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    if (_busy || _detector == null || _controller == null) return;
    _busy = true;
    _processFrame(image).whenComplete(() => _busy = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      final inputImage = _toInputImage(image);
      if (inputImage == null) return;
      final faces = await _detector!.processImage(inputImage);
      if (faces.isEmpty) return;

      final face = faces.first;
      final box = face.boundingBox;
      final centerX = box.center.dx / image.width;
      final centerY = box.center.dy / image.height;

      // Map 0..1 image-space coords to -1..1 look-offset, flipped for mirror.
      final offset = Offset((0.5 - centerX) * 2, (centerY - 0.5) * 2);
      onFaceOffset(offset);
    } catch (_) {
      // Dropped frames/decoding hiccups are fine to ignore -- next frame retries.
    }
  }

  // The camera sensor's orientation is a fixed hardware property measured
  InputImage? _toInputImage(CameraImage image) {
    final camera = _controller?.description;
    if (camera == null) return null;

    final bytes = image.planes.fold<List<int>>(
      [],
      (acc, plane) => acc..addAll(plane.bytes),
    );

    return InputImage.fromBytes(
      bytes: Uint8List.fromList(bytes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
            InputImageRotation.rotation0deg,
        // We explicitly requested ImageFormatGroup.nv21 above, so trust that
        // rather than re-deriving it from the platform's raw format code.
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Future<void> stop() async {
    await _controller?.stopImageStream();
    await _controller?.dispose();
    await _detector?.close();
    _controller = null;
    _detector = null;
  }
}
