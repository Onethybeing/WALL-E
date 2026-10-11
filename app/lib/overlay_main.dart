import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'main.dart' show Mood, MoodIndicator;

/// Entry point for the persistent "Dynamic Island"-style overlay -- a
/// second, independent FlutterEngine the OS renders on top of whatever app
/// is currently in the foreground (see bridge_server.dart's /overlay/*
/// endpoints and tools.py's show_floating_overlay). The name `overlayMain`
/// is not arbitrary: flutter_overlay_window's native side looks up this
/// exact top-level function by name as the Dart entry point.
@pragma("vm:entry-point")
void overlayMain() {
  runApp(const _OverlayApp());
}

Color _colorFor(Mood mood) => switch (mood) {
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

    // main.dart's _EyesScreenState forwards mood changes here via
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
    final color = _colorFor(_mood);
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
