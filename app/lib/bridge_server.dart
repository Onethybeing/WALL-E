import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:geolocator/geolocator.dart';

const _mediaChannel = MethodChannel('com.sourav.walle/media');

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
    await _mediaChannel.invokeMethod('dispatchMediaKey', {'keyCode': keyCode});
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

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    moodNotifier.dispose();
  }
}
