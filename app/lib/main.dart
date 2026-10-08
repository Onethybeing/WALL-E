import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge_server.dart';
import 'face_tracking.dart';
// Wake-word is temporarily disabled -- see pubspec.yaml and wake_word.dart
// for why (an upstream dependency conflict, not our code).
// import 'wake_word.dart';

void main() {
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

/// The pet's current expression. Later this gets driven by the agent's state
/// (listening / thinking / speaking) instead of the tap-to-cycle demo below.
enum Mood { idle, happy, surprised, thinking }

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

  // Current blink progress: 0.0 = eyes fully open, 1.0 = fully shut.
  double _blink = 0.0;

  // Where the pupils are currently drawn, and where they're easing towards.
  // Keeping these separate (rather than jumping straight to a new target)
  // is what makes the look-around motion feel smooth instead of twitchy.
  Offset _lookOffset = Offset.zero;
  Offset _lookTarget = Offset.zero;

  Mood _mood = Mood.idle;

  FaceTracker? _faceTracker;
  bool _faceTrackingActive = false;

  final BridgeServer _bridgeServer = BridgeServer();

  // WakeWordListener? _wakeWordListener; // disabled -- see pubspec.yaml

  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16), // ~one frame, just a ticker
    )..addListener(_onTick);
    _scheduleNextBlink();
    _controller.repeat();
    _setUpLookBehaviour();
    _bridgeServer.start();
    // Wake-word setup disabled for now -- see pubspec.yaml for why.
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

  void _scheduleNextBlink() {
    final delay = Duration(milliseconds: 2000 + _random.nextInt(3000));
    Future.delayed(delay, () async {
      if (!mounted) return;
      await _playBlink();
      _scheduleNextBlink();
    });
  }

  Future<void> _playBlink() async {
    const steps = 10;
    for (int i = 0; i <= steps; i++) {
      if (!mounted) return;
      setState(() => _blink = i / steps);
      await Future.delayed(const Duration(milliseconds: 15));
    }
    for (int i = steps; i >= 0; i--) {
      if (!mounted) return;
      setState(() => _blink = i / steps);
      await Future.delayed(const Duration(milliseconds: 15));
    }
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

  void _cycleMood() {
    setState(() {
      _mood = Mood.values[(_mood.index + 1) % Mood.values.length];
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _faceTracker?.stop();
    _bridgeServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // Tap-to-cycle is a stand-in until the agent's own state drives mood.
        onTap: _cycleMood,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Eye(blink: _blink, lookOffset: _lookOffset, mood: _mood),
              const SizedBox(width: 48),
              Eye(blink: _blink, lookOffset: _lookOffset, mood: _mood),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single eye: a cyan circle (sclera) with a dark pupil that can move,
/// an eyelid that closes based on [blink] (0 = open, 1 = shut), and a shape
/// that changes with [mood].
class Eye extends StatelessWidget {
  const Eye({
    super.key,
    required this.blink,
    required this.lookOffset,
    required this.mood,
  });

  final double blink;
  final Offset lookOffset;
  final Mood mood;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: CustomPaint(
        painter: _EyePainter(blink: blink, lookOffset: lookOffset, mood: mood),
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  _EyePainter({required this.blink, required this.lookOffset, required this.mood});

  final double blink;
  final Offset lookOffset;
  final Mood mood;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Mood affects overall eye size and pupil size, on top of the blink animation.
    final sizeScale = switch (mood) {
      Mood.surprised => 1.2,
      Mood.thinking => 0.85,
      _ => 1.0,
    };
    final pupilScale = switch (mood) {
      Mood.surprised => 0.55,
      Mood.thinking => 0.35,
      _ => 0.4,
    };
    final radius = (size.width / 2) * sizeScale;

    const cyan = Color(0xFF00F6FF);
    final scleraPaint = Paint()..color = cyan;
    final pupilPaint = Paint()..color = Colors.black;

    final openness = 1.0 - blink;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1.0, openness.clamp(0.05, 1.0));
    canvas.translate(-center.dx, -center.dy);

    for (final glow in [
      (radius * 1.9, 0.10),
      (radius * 1.5, 0.18),
      (radius * 1.2, 0.30),
    ]) {
      final glowPaint = Paint()
        ..color = cyan.withOpacity(glow.$2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24);
      canvas.drawCircle(center, glow.$1, glowPaint);
    }

    if (mood == Mood.happy) {
      // A happy eye is its own almond/crescent shape (like ^) -- two curves
      // meeting at the same left/right corner points, not a clipped circle
      // (clipping a circle against a mismatched curve left a visible kink).
      final left = Offset(center.dx - radius, center.dy);
      final right = Offset(center.dx + radius, center.dy);
      final happyPath = Path()
        ..moveTo(left.dx, left.dy)
        ..quadraticBezierTo(center.dx, center.dy - radius * 1.1, right.dx, right.dy)
        ..quadraticBezierTo(center.dx, center.dy - radius * 0.3, left.dx, left.dy)
        ..close();
      canvas.drawPath(happyPath, scleraPaint);
    } else {
      canvas.drawCircle(center, radius, scleraPaint);

      final pupilRadius = radius * pupilScale;
      final maxPupilShift = radius - pupilRadius - 8;
      final pupilCenter = center + lookOffset * maxPupilShift;
      canvas.drawCircle(pupilCenter, pupilRadius, pupilPaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EyePainter oldDelegate) {
    return oldDelegate.blink != blink ||
        oldDelegate.lookOffset != lookOffset ||
        oldDelegate.mood != mood;
  }
}
