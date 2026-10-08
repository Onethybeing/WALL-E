import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:rive/rive.dart';
import 'package:rive_common/math.dart' show Vec2D;

/// Renders the animated eyes from assets/rive/eyes.riv and drives the
/// look-direction via the state machine's pointer-move listener (the rig
/// was built with Rive's "eyes follow cursor" hitbox+listener pattern, not
/// named Number inputs -- so we feed it synthetic pointer positions rather
/// than setting state-machine inputs directly).
class RiveEyes extends StatefulWidget {
  const RiveEyes({super.key, required this.lookOffset});

  /// -1..1 on each axis, same convention the old CustomPainter eyes used.
  final Offset lookOffset;

  @override
  State<RiveEyes> createState() => _RiveEyesState();
}

class _RiveEyesState extends State<RiveEyes> {
  Artboard? _artboard;
  StateMachineController? _controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      debugPrint('WALLE_RIVE: loading asset...');
      final bytes = await rootBundle.load('assets/rive/eyes.riv');
      debugPrint('WALLE_RIVE: loaded ${bytes.lengthInBytes} bytes, importing...');
      final file = RiveFile.import(bytes);
      final artboard = file.mainArtboard;
      debugPrint(
        'WALLE_RIVE: artboard="${artboard.name}" size=${artboard.width}x${artboard.height} '
        'animations=${artboard.animations.map((a) => a.name).toList()} '
        'stateMachines=${artboard.stateMachines.map((s) => s.name).toList()}',
      );

      StateMachineController? controller;
      if (artboard.stateMachines.isNotEmpty) {
        final smName = artboard.stateMachines.first.name;
        controller = StateMachineController.fromArtboard(artboard, smName);
        debugPrint(
          'WALLE_RIVE: controller for "$smName" -> ${controller != null}, '
          'inputs=${controller?.inputs.map((i) => '${i.name}(${i.runtimeType})').toList()}',
        );
      } else {
        debugPrint('WALLE_RIVE: no state machines on this artboard at all');
      }

      if (controller != null) {
        artboard.addController(controller);
      }

      if (!mounted) return;
      setState(() {
        _artboard = artboard;
        _controller = controller;
      });
    } catch (e, stack) {
      debugPrint('WALLE_RIVE: EXCEPTION loading rive file: $e\n$stack');
    }
  }

  @override
  void didUpdateWidget(covariant RiveEyes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lookOffset != oldWidget.lookOffset) {
      _feedLookOffset();
    }
  }

  void _feedLookOffset() {
    final artboard = _artboard;
    final controller = _controller;
    if (artboard == null || controller == null) return;

    // Map our -1..1 lookOffset to a position within the artboard's own
    // coordinate space, then feed it in as if it were a real pointer --
    // this is what the rig's hitbox listener actually responds to.
    final center = Offset(artboard.width / 2, artboard.height / 2);
    final radius = Offset(artboard.width / 2, artboard.height / 2);
    final target = center + Offset(widget.lookOffset.dx * radius.dx, widget.lookOffset.dy * radius.dy);

    controller.pointerMove(Vec2D.fromOffset(target));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artboard = _artboard;
    if (artboard == null) return const SizedBox.shrink();
    return Rive(artboard: artboard, fit: BoxFit.cover);
  }
}
