import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:rive/rive.dart' hide RadialGradient;

import 'bridge_server.dart';
import 'face_tracking.dart';
import 'rive_eyes.dart';
// Wake-word: sherpa-onnx's keyword spotter crashed natively (Ort::Exception
// in the encoder's Reshape node, Fatal signal 6/SIGABRT) and Porcupine's
// plugin still hardcodes a conflicting compileSdkVersion -- both dropped.
// wake_word.dart now uses speech_to_text (Android's own SpeechRecognizer)
// instead, which has neither problem. See that file's doc comment.
import 'wake_word.dart';

/// Entry point for the persistent "Dynamic Island"-style overlay -- a
/// second, independent FlutterEngine the OS renders on top of whatever app
/// is currently in the foreground (see bridge_server.dart's /overlay/*
/// endpoints and tools.py's show_floating_overlay). The name `overlayMain`
/// is not arbitrary: flutter_overlay_window's native side looks up this
/// exact top-level function by name as the Dart entry point.
///
/// Lives in main.dart itself, not a separate file, after hitting "Could not
/// resolve main entrypoint function" at runtime (confirmed via logcat) --
/// a separate overlay_main.dart file merely imported from here (even with
/// the @pragma) still got tree-shaken out of the compiled snapshot since
/// nothing actually referenced anything from it. A top-level function in
/// the library that's already guaranteed to be kept can't be stripped.
@pragma("vm:entry-point")
void overlayMain() {
  runApp(const _OverlayApp());
}

Color _overlayColorFor(Mood mood) => switch (mood) {
      Mood.listening => Colors.cyanAccent,
      Mood.thinking => Colors.purpleAccent,
      Mood.searching => Colors.yellowAccent,
      Mood.speaking => Colors.greenAccent,
      Mood.takingPhoto => Colors.orangeAccent,
      Mood.error => Colors.redAccent,
      _ => Colors.white70,
    };

class _OverlayApp extends StatefulWidget {
  const _OverlayApp();

  @override
  State<_OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<_OverlayApp> with SingleTickerProviderStateMixin {
  Mood _mood = Mood.idle;
  double _phase = 0;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      setState(() => _phase += 0.06);
    })..start();

    // _EyesScreenState forwards mood changes here via
    // FlutterOverlayWindow.shareData(moodStateString) -- see its
    // moodNotifier listener. This overlay has no direct access to that
    // ValueNotifier since it runs in a completely separate isolate/engine.
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is! String) return;
      for (final mood in Mood.values) {
        if (mood.name == data) {
          if (mounted) setState(() => _mood = mood);
          break;
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _onTap() async {
    // Same trigger the main eyes screen's tap uses -- loopback-only, so
    // this works regardless of which app/overlay is currently visible.
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:8100/trigger'));
      await request.close();
      client.close();
    } catch (_) {
      // Brain's trigger server isn't running -- nothing to show for this.
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _overlayColorFor(_mood);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          onTap: _onTap,
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.55),
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 18, spreadRadius: 1)],
              ),
              child: Center(
                child: _mood == Mood.idle
                    ? Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.withValues(alpha: 0.5 + (sin(_phase) + 1) / 2 * 0.3),
                        ),
                      )
                    : Transform.scale(
                        scale: 0.6,
                        child: MoodIndicator(mood: _mood, color: color, phase: _phase),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    final shape = switch (mood) {
      Mood.listening => _breathingRing(),
      Mood.thinking => _bouncingDots(),
      Mood.searching => _spinningArc(),
      Mood.speaking => _equalizerBars(),
      Mood.takingPhoto => _shutterPulse(),
      Mood.error => _slowBlink(),
      _ => null,
    };
    if (shape == null) return const SizedBox.shrink();
    // A soft ambient glow behind every shape -- turns flat UI chips into
    // something that reads as light rather than a widget.
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 28, spreadRadius: 2)],
      ),
      child: shape,
    );
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

  WakeWordListener? _wakeWordListener;
  // True from the moment the brain leaves "idle" until it returns to it --
  // tracks whether the wake-word listener needs resuming once the current
  // voice turn (which may hop through several listen/think/speak rounds)
  // is genuinely finished, not just between hops.
  bool _voiceTurnInProgress = false;

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
    if (WakeWordListener.isSupported) {
      _wakeWordListener = WakeWordListener(onWake: _onWakeWordDetected);
      _wakeWordListener!.start();
    }
  }

  /// Only fires a voice turn if the pet is genuinely idle -- a stray match
  /// against TTS audio bleeding back into the mic, or a wake phrase heard
  /// mid-turn, should not interrupt or double-trigger a turn already in
  /// flight.
  void _onWakeWordDetected() {
    if (_mood == Mood.idle) {
      _triggerVoiceTurn();
    }
  }

  void _onBrainMoodChanged() {
    final mood = _moodFromBrainState(_bridgeServer.moodNotifier.value);
    if (mood != null && mounted) {
      setState(() => _mood = mood);
    }
    if (mood == Mood.idle) {
      if (_voiceTurnInProgress) {
        _voiceTurnInProgress = false;
        // speech_to_text's own SpeechRecognizer can't share the mic with
        // the raw recorder mic_listen() just used -- only safe to resume
        // listening for the wake word once the brain is truly done, not
        // between the conversational hops within a single turn.
        _wakeWordListener?.resume();
      }
    } else {
      _voiceTurnInProgress = true;
    }
    // Forward to the floating overlay too, if it's up -- it runs in a
    // completely separate isolate/engine with no access to this
    // ValueNotifier directly, so FlutterOverlayWindow.shareData is the
    // only channel between them (overlay_main.dart listens on the other
    // end). No-ops harmlessly if the overlay isn't currently showing.
    FlutterOverlayWindow.shareData(_bridgeServer.moodNotifier.value);
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
  ///
  /// A second tap *while already listening* stops the recording right
  /// away instead of starting a new turn -- this device's mic noise floor
  /// never fully quiets down (confirmed via direct measurement), so
  /// automatic silence detection alone isn't reliable here; tapping again
  /// is the reliable "I'm done talking" signal.
  Future<void> _triggerVoiceTurn() async {
    if (_mood == Mood.listening) {
      _bridgeServer.stopListening();
      return;
    }
    if (_mood != Mood.idle) {
      // Busy but not listening (thinking/searching/speaking) -- a tap here
      // means "stop", same as tapping again while listening does. Hits
      // agent.py's POST /stop, which kills audio playback immediately and
      // cuts the rest of the turn short (see mood_bridge.stop_requested).
      try {
        final client = HttpClient();
        final request = await client.postUrl(Uri.parse('http://127.0.0.1:8100/stop'));
        await request.close();
        client.close();
      } catch (_) {}
      return;
    }
    // Hand the mic over fully before the brain's own listen() call starts --
    // Android can't run SpeechRecognizer and the raw-PCM recorder at once.
    await _wakeWordListener?.pause();
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:8100/trigger'));
      await request.close();
      client.close();
    } catch (_) {
      // Brain's trigger server isn't running (e.g. agent.py --serve hasn't
      // been started in Termux yet) -- nothing to show the user for this,
      // the eyes simply won't react, which is itself the signal. Since no
      // turn actually started, mood will never come back around to "idle"
      // to resume the wake-word listener -- undo the pause ourselves.
      _wakeWordListener?.resume();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _faceTracker?.stop();
    _bridgeServer.moodNotifier.removeListener(_onBrainMoodChanged);
    _bridgeServer.stop();
    _wakeWordListener?.stop();
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
                    // A soft colored vignette instead of a hard rectangular
                    // border -- transparent at the center so the eyes stay
                    // clear, breathing gently with the mood pulse towards
                    // the edges. Replaces the old flat 6px frame.
                    Positioned.fill(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.center,
                            radius: 1.2,
                            colors: [
                              color.withValues(alpha: 0),
                              color.withValues(alpha: 0.22 + (sin(_pulsePhase) + 1) / 2 * 0.1),
                            ],
                            stops: const [0.45, 1.0],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 36,
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
