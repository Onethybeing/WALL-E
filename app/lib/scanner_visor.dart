import 'dart:math';
import 'package:flutter/material.dart';

/// The WALL-E character redesign (GitHub issue #15): a gunmetal dome head
/// with ear fins and a single equalizer-style visor, chosen by the project
/// owner after reviewing three concepts live (binocular movie-accurate
/// eyes, a softer EVE-style face plate, and this scanner visor).
///
/// Self-contained on purpose (only dart:math + material, no plugins) so the
/// exact same widget can be shared between the full-screen main app
/// (EyesScreen) and the floating overlay's separate isolate/engine
/// (_OverlayApp in main.dart), rather than keeping two drifting copies of
/// the same design in sync by hand.
class ScannerVisorFace extends StatelessWidget {
  const ScannerVisorFace({
    super.key,
    required this.moodName,
    required this.phase,
    this.lookOffset = Offset.zero,
  });

  /// The brain-side mood state name (see brain/mood_bridge.py's
  /// VALID_STATES) or a Mood enum's `.name` -- either way, a plain string so
  /// this file never needs to import main.dart's Mood enum (which would
  /// create a main.dart <-> scanner_visor.dart import cycle).
  final String moodName;

  /// A monotonically increasing value driving the visor's idle "scanning"
  /// animation -- not real audio analysis, just enough motion that the
  /// segments read as alive rather than a static snapshot.
  final double phase;

  /// -1..1 on each axis, from face tracking -- tilts the whole head toward
  /// whoever it's looking at, the scanner-visor equivalent of eye movement.
  final Offset lookOffset;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(moodName);
    return Transform.translate(
      offset: lookOffset * 14,
      child: Transform.rotate(
        angle: lookOffset.dx * 0.10,
        child: _Dome(style: style, phase: phase),
      ),
    );
  }
}

class _VisorStyle {
  const _VisorStyle(this.color, this.amplitude, this.speed, this.energy);
  final Color color;
  final double amplitude; // px a segment can grow beyond its base height
  final double speed; // oscillation speed multiplier
  final double energy; // base glow/opacity intensity, 0..1
}

const _idle = _VisorStyle(Color(0xFFD98E4A), 8, 0.9, 0.55);

_VisorStyle _styleFor(String mood) => switch (mood) {
      'listening' => const _VisorStyle(Color(0xFF4DD8E6), 16, 2.6, 0.9),
      'thinking' => const _VisorStyle(Color(0xFFB07CF2), 14, 1.8, 0.85),
      'searching' => const _VisorStyle(Color(0xFFE6C84D), 18, 3.2, 0.85),
      'speaking' => const _VisorStyle(Color(0xFF6FE6A3), 20, 4.0, 1.0),
      'error' => const _VisorStyle(Color(0xFFE65C5C), 5, 0.6, 0.9),
      'takingPhoto' || 'taking_photo' => const _VisorStyle(Color(0xFFFFFFFF), 24, 7.0, 1.0),
      _ => _idle,
    };

const _segmentCount = 9;

class _Dome extends StatelessWidget {
  const _Dome({required this.style, required this.phase});
  final _VisorStyle style;
  final double phase;

  static const _metal = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3A3F44), Color(0xFF1A1D20)],
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 420,
      height: 260,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(left: -14, top: 90, child: _fin()),
          Positioned(right: -14, top: 90, child: _fin()),
          Container(
            width: 420,
            height: 260,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(210),
                topRight: Radius.circular(210),
                bottomLeft: Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
              gradient: _metal,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 60, offset: const Offset(0, 24)),
                BoxShadow(color: Colors.white.withValues(alpha: 0.08), blurRadius: 1, offset: const Offset(0, 2)),
              ],
            ),
            child: Center(child: _Visor(style: style, phase: phase)),
          ),
        ],
      ),
    );
  }

  Widget _fin() => Container(
        width: 36,
        height: 84,
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          gradient: _metal,
        ),
      );
}

class _Visor extends StatelessWidget {
  const _Visor({required this.style, required this.phase});
  final _VisorStyle style;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF060606),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(_segmentCount, (i) {
          final wave = (sin(phase * style.speed + i * 0.9) + 1) / 2; // 0..1
          final height = 10 + wave * style.amplitude;
          return Container(
            width: 20,
            height: height,
            decoration: BoxDecoration(
              color: style.color,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [BoxShadow(color: style.color.withValues(alpha: style.energy), blurRadius: 10)],
            ),
          );
        }),
      ),
    );
  }
}
