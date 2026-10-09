import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rive/rive.dart';

import 'bridge_server.dart';
import 'face_tracking.dart';
import 'rive_eyes.dart';
// Wake-word is temporarily disabled -- sherpa-onnx's keyword spotter
// crashes natively (Ort::Exception in the encoder's Reshape node, Fatal
// signal 6/SIGABRT) with this exact kws-zipformer-gigaspeech model on real
// hardware, reproducibly, regardless of audio chunk size fed to it. Verified
// the model files match the official release and the Dart-side config
// matches sherpa-onnx's own reference example -- this looks like a genuine
// upstream incompatibility between sherpa_onnx 1.13.8's bundled ONNX
// Runtime and this model's exported graph, not a bug in our integration
// code. See wake_word.dart for the full (otherwise working) implementation.
// import 'wake_word.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RiveFile.initialize();
  // Lock the app to landscape since the eyes are designed for a wide screen.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const WallEApp());
}

class WallEApp extends StatelessWidget {
  const WallEApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'WALL-E',
      debugShowCheckedModeBanner: false,
      home: EyesScreen(),
    );
  }
}

/// The pet's current expression. `idle`/`happy`/`surprised`/`thinking` are
/// driven by the tap-to-cycle demo; `searching`/`speaking`/`takingPhoto` are
/// driven for real by the brain via BridgeServer.moodNotifier (see
/// _EyesScreenState's bridge listener below and brain/mood_bridge.py on the
/// Python side).
enum Mood { idle, happy, surprised, thinking, listening, searching, speaking, takingPhoto, error }

/// Maps the state strings the brain POSTs to /mood (brain/mood_bridge.py's
/// VALID_STATES) onto the Mood enum above. Keep both lists in sync.
Mood? _moodFromBrainState(String state) => switch (state) {
      'idle' => Mood.idle,
      'listening' => Mood.listening,
      'thinking' => Mood.thinking,
      'searching' => Mood.searching,
      'speaking' => Mood.speaking,
      'taking_photo' => Mood.takingPhoto,
      'error' => Mood.error,
      _ => null,
    };

/// A short label + accent color for each mood, used by the overlay in
/// _EyesScreenState.build() -- the Rive rig itself has no mood animations
/// (it's purely an eye-tracking rig), so mood is communicated via this
/// overlay rather than by changing the eyes' own artwork.
({String label, Color color})? _overlayFor(Mood mood) => switch (mood) {
      Mood.listening => (label: 'listening...', color: Colors.cyanAccent),
      Mood.thinking => (label: 'thinking...', color: Colors.purpleAccent),
      Mood.searching => (label: 'searching...', color: Colors.yellowAccent),
      Mood.speaking => (label: 'speaking...', color: Colors.greenAccent),
      Mood.takingPhoto => (label: 'taking a photo...', color: Colors.orangeAccent),
      Mood.error => (label: "couldn't reach the internet", color: Colors.redAccent),
      _ => null,
    };

/// The main screen: a black background with two animated eyes centered on it.
class EyesScreen extends StatefulWidget {
  const EyesScreen({super.key});

  @override
  State<EyesScreen> createState() => _EyesScreenState();
}

class _EyesScreenState extends State<EyesScreen>
    with SingleTickerProviderStateMixin {
  // A Ticker fires a callback on every animation frame (~60 times/sec).
  // AnimationController uses that ticker to track elapsed time for us.
  late AnimationController _controller;

  // Where the pupils are currently drawn, and where they're easing towards.
  // Keeping these separate (rather than jumping straight to a new target)
  // is what makes the look-around motion feel smooth instead of twitchy.
  Offset _lookOffset = Offset.zero;
  Offset _lookTarget = Offset.zero;

  Mood _mood = Mood.idle;

  FaceTracker? _faceTracker;
  bool _faceTrackingActive = false;

  final BridgeServer _bridgeServer = BridgeServer();

  // WakeWordListener? _wakeWordListener; // disabled -- see import comment above

  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16), // ~one frame, just a ticker
    )..addListener(_onTick);
    _controller.repeat();
    _setUpLookBehaviour();
    _bridgeServer.start();
    _bridgeServer.moodNotifier.addListener(_onBrainMoodChanged);
    // Wake-word setup disabled for now -- see import comment above.
  }

  void _onBrainMoodChanged() {
    final mood = _moodFromBrainState(_bridgeServer.moodNotifier.value);
    if (mood != null && mounted) {
      setState(() => _mood = mood);
    }
  }

  void _setUpLookBehaviour() {
    if (FaceTracker.isSupported) {
      _faceTracker = FaceTracker(
        onFaceOffset: (offset) {
          _faceTrackingActive = true;
          _lookTarget = offset;
        },
      );
      _faceTracker!.start();
      // If we lose the face for a while, fall back to idle drifting so the
      // pet doesn't freeze staring at a stale point.
      _scheduleNextLook(onlyIfNoFace: true);
    } else {
      // Web/desktop preview: no camera tracking available, just drift idly.
      _scheduleNextLook(onlyIfNoFace: false);
    }
  }

  void _onTick() {
    // Ease the current look position towards the target every frame --
    // this is what turns discrete target updates into smooth motion.
    setState(() {
      _lookOffset = Offset.lerp(_lookOffset, _lookTarget, 0.12)!;
    });
  }

  void _scheduleNextLook({required bool onlyIfNoFace}) {
    final delay = Duration(milliseconds: 1500 + _random.nextInt(2500));
    Future.delayed(delay, () {
      if (!mounted) return;
      if (!onlyIfNoFace || !_faceTrackingActive) {
        _lookTarget = Offset(
          _random.nextDouble() * 2 - 1,
          _random.nextDouble() * 2 - 1,
        );
      }
      // Face tracking "goes stale" after a bit so losing the face resumes drifting.
      _faceTrackingActive = false;
      _scheduleNextLook(onlyIfNoFace: onlyIfNoFace);
    });
  }

  /// Tapping the eyes tells the brain (running its own trigger server in
  /// Termux, see agent.py's `serve()`/_TriggerHandler) to start one full
  /// voice turn: listen, think, speak. This is the manual stand-in for the
  /// wake-word trigger until that's working again (see wake_word.dart).
  Future<void> _triggerVoiceTurn() async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:8100/trigger'));
      await request.close();
      client.close();
    } catch (_) {
      // Brain's trigger server isn't running (e.g. agent.py --serve hasn't
      // been started in Termux yet) -- nothing to show the user for this,
      // the eyes simply won't react, which is itself the signal.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _faceTracker?.stop();
    _bridgeServer.moodNotifier.removeListener(_onBrainMoodChanged);
    _bridgeServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _overlayFor(_mood);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _triggerVoiceTurn,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            SizedBox.expand(
              child: RiveEyes(lookOffset: _lookOffset),
            ),
            if (overlay != null)
              IgnorePointer(
                child: Stack(
                  children: [
                    // A colored border glow around the whole screen -- cheap,
                    // visible from across a room, and doesn't require the
                    // Rive rig itself to support mood animations.
                    Positioned.fill(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          border: Border.all(color: overlay.color, width: 6),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 24,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Text(
                          overlay.label,
                          style: TextStyle(
                            color: overlay.color,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
