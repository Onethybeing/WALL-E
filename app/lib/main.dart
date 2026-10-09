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

/// An accent color for each mood, used by the overlay in
/// _EyesScreenState.build() -- the Rive rig itself has no mood animations
/// (it's purely an eye-tracking rig), so mood is communicated via this
/// overlay rather than by changing the eyes' own artwork.
Color? _colorFor(Mood mood) => switch (mood) {
      Mood.listening => Colors.cyanAccent,
      Mood.thinking => Colors.purpleAccent,
      Mood.searching => Colors.yellowAccent,
      Mood.speaking => Colors.greenAccent,
      Mood.takingPhoto => Colors.orangeAccent,
      Mood.error => Colors.redAccent,
      _ => null,
    };

/// A small per-mood animated indicator, replacing what used to be a plain
/// text label ("listening...", "thinking...", etc) -- see GitHub issue #6.
/// Driven by `phase`, a monotonically increasing value ticking at ~60fps
/// (see _EyesScreenState._onTick), rather than its own AnimationController.
class MoodIndicator extends StatelessWidget {
  const MoodIndicator({super.key, required this.mood, required this.color, required this.phase});

  final Mood mood;
  final Color color;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return switch (mood) {
      Mood.listening => _breathingRing(),
      Mood.thinking => _bouncingDots(),
      Mood.searching => _spinningArc(),
      Mood.speaking => _equalizerBars(),
      Mood.takingPhoto => _shutterPulse(),
      Mood.error => _slowBlink(),
      _ => const SizedBox.shrink(),
    };
  }

  // A ring that breathes in and out, like something actively paying attention.
  Widget _breathingRing() {
    final pulse = (sin(phase) + 1) / 2; // 0..1
    return Container(
      width: 36 + pulse * 16,
      height: 36 + pulse * 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 4),
      ),
    );
  }

  // Three dots bouncing in sequence, like a classic "thinking" indicator.
  Widget _bouncingDots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final bounce = (sin(phase * 2 - i * 0.8) + 1) / 2;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Transform.translate(
            offset: Offset(0, -bounce * 10),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
        );
      }),
    );
  }

  // A partial ring that spins continuously, like a search/loading spinner.
  Widget _spinningArc() {
    return Transform.rotate(
      angle: phase * 2,
      child: SizedBox(
        width: 36,
        height: 36,
        child: CustomPaint(painter: _ArcPainter(color: color)),
      ),
    );
  }

  // Vertical bars pulsing at different rates, like an audio equalizer.
  Widget _equalizerBars() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final h = 8 + ((sin(phase * (2.5 + i * 0.9) + i) + 1) / 2) * 24;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            width: 6,
            height: h,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
        );
      }),
    );
  }

  // A quick bright flash that fades, like a camera shutter.
  Widget _shutterPulse() {
    final flash = ((sin(phase * 3) + 1) / 2).clamp(0.0, 1.0);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.3 + flash * 0.7),
      ),
    );
  }

  // A slow, steady blink -- deliberately calmer than the others so an error
  // doesn't feel as urgent/animated as an active task.
  Widget _slowBlink() {
    final blink = (sin(phase * 0.6) + 1) / 2;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.4 + blink * 0.6), width: 4),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Offset.zero & size, 0, pi * 1.3, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) => oldDelegate.color != color;
}

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

  // Drives the mood indicator's pulse -- reuses the existing 60fps ticker
  // rather than a second AnimationController, see _onTick.
  double _pulsePhase = 0;

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
    _bridgeServer.pauseFaceCamera = () async => _faceTracker?.stop();
    _bridgeServer.resumeFaceCamera = () async => _faceTracker?.start();
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
      _pulsePhase += 0.06;
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
    final color = _colorFor(_mood);
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
            if (color != null)
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
                          border: Border.all(color: color, width: 6),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 28,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: MoodIndicator(mood: _mood, color: color, phase: _pulsePhase),
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
