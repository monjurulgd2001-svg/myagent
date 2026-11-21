import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Realistic phone mockup preview: shows a generated wallpaper as it
/// would look on a device — plain wallpaper, lock screen, home screen,
/// an in-app (chat) view and an incoming call screen.
enum MockupMode { wallpaper, lock, home, chat, call }

/// Phone hardware variants for the device preview.
enum DeviceModel { island, notch, punch, edge, fold }

extension DeviceModelSpec on DeviceModel {
  String get label => switch (this) {
        DeviceModel.island => 'Island Pro',
        DeviceModel.notch => 'Classic Notch',
        DeviceModel.punch => 'Punch Hole',
        DeviceModel.edge => 'Edge Curve',
        DeviceModel.fold => 'Fold Pro',
      };

  double get radius => switch (this) {
        DeviceModel.island => 46,
        DeviceModel.notch => 42,
        DeviceModel.punch => 36,
        DeviceModel.edge => 44,
        DeviceModel.fold => 38,
      };

  Color get bodyColor => switch (this) {
        DeviceModel.island => const Color(0xFF0b0b0e),
        DeviceModel.notch => const Color(0xFF0e0e12),
        DeviceModel.punch => const Color(0xFF1a1d26),
        DeviceModel.edge => const Color(0xFFd4d8e0),
        DeviceModel.fold => const Color(0xFF101014),
      };

  Color get borderColor => switch (this) {
        DeviceModel.island => const Color(0xFF3d3d44),
        DeviceModel.notch => const Color(0xFF2c2c34),
        DeviceModel.punch => const Color(0xFF4d5468),
        DeviceModel.edge => const Color(0xFF9aa0ae),
        DeviceModel.fold => const Color(0xFF3a3a44),
      };

  List<Color> get backColors => switch (this) {
        DeviceModel.island => const [Color(0xFF2a2a31), Color(0xFF17171c)],
        DeviceModel.notch => const [Color(0xFF1c1c22), Color(0xFF101014)],
        DeviceModel.punch => const [Color(0xFF232936), Color(0xFF141824)],
        DeviceModel.edge => const [Color(0xFFe4e8f0), Color(0xFFb7bdcb)],
        DeviceModel.fold => const [Color(0xFF232329), Color(0xFF121216)],
      };

  /// Slimmer side bezels on the curved-edge model.
  EdgeInsets get bezel => switch (this) {
        DeviceModel.edge => const EdgeInsets.fromLTRB(5, 9, 5, 9),
        _ => const EdgeInsets.all(9),
      };

  /// Front camera / notch cutout.
  Widget notchWidget() => switch (this) {
        DeviceModel.island => const Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 86,
                  height: 25,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius:
                          BorderRadius.all(Radius.circular(13)),
                    ),
                  ),
                ),
              ),
            ),
        DeviceModel.notch => Positioned(
              top: 9,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 150,
                  height: 27,
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(16)),
                  ),
                ),
              ),
            ),
        DeviceModel.punch => Positioned(
              top: 25,
              left: 0,
              right: 0,
              child: Center(child: _hole(15)),
            ),
        DeviceModel.edge => Positioned(
              top: 23,
              left: 0,
              right: 0,
              child: Center(child: _hole(13)),
            ),
        // Foldable inner display: small punch-hole camera, top center.
        DeviceModel.fold => Positioned(
              top: 22,
              left: 0,
              right: 0,
              child: Center(child: _hole(12)),
            ),
      };

  /// iPhone-style left buttons vs Android-style right buttons.
  List<Widget> sideButtons() => switch (this) {
        DeviceModel.island || DeviceModel.notch => [
              Positioned(
                  left: -4,
                  top: 110,
                  child: _PhoneFrame.sideButton(
                      height: 56, color: borderColor)),
              Positioned(
                  left: -4,
                  top: 176,
                  child: _PhoneFrame.sideButton(
                      height: 88, color: borderColor)),
              Positioned(
                  right: -4,
                  top: 150,
                  child: _PhoneFrame.sideButton(
                      height: 72, color: borderColor)),
            ],
        DeviceModel.punch || DeviceModel.edge || DeviceModel.fold => [
              Positioned(
                  right: -4,
                  top: 130,
                  child: _PhoneFrame.sideButton(
                      height: 80, color: borderColor)),
              Positioned(
                  right: -4,
                  top: 220,
                  child: _PhoneFrame.sideButton(
                      height: 56, color: borderColor)),
            ],
      };

  static Widget _hole(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black,
          shape: BoxShape.circle,
          border:
              Border.all(color: const Color(0xFF2a2e3a), width: 2),
        ),
      );
}

Future<void> showDevicePreview(
  BuildContext context, {
  required String imageUrl,
  required String title,
  List<({String imageUrl, String label})>? stages,
  int initialIndex = 0,
}) {
  return showDialog(
    context: context,
    builder: (_) => _DevicePreviewDialog(
      imageUrl: imageUrl,
      title: title,
      stages: stages,
      initialIndex: initialIndex,
    ),
  );
}

class _DevicePreviewDialog extends StatefulWidget {
  final String imageUrl;
  final String title;
  final List<({String imageUrl, String label})>? stages;
  final int initialIndex;
  const _DevicePreviewDialog({
    required this.imageUrl,
    required this.title,
    this.stages,
    this.initialIndex = 0,
  });

  @override
  State<_DevicePreviewDialog> createState() => _DevicePreviewDialogState();
}

class _DevicePreviewDialogState extends State<_DevicePreviewDialog>
    with SingleTickerProviderStateMixin {
  MockupMode _mode = MockupMode.lock;
  DeviceModel _device = DeviceModel.island;
  late int _stageIndex;

  String get _currentImageUrl {
    final s = widget.stages;
    if (s == null || s.isEmpty) return widget.imageUrl;
    return s[_stageIndex.clamp(0, s.length - 1)].imageUrl;
  }
  double _rotX = 0.0;
  double _rotY = 0.0;
  double _zoom = 1.0;

  /// Fold/unfold animation for the foldable (0 = folded, 1 = unfolded).
  late final AnimationController _foldCtl;
  late final Animation<double> _foldAnim;

  @override
  void initState() {
    super.initState();
    _stageIndex = widget.initialIndex;
    _foldCtl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _foldAnim =
        CurvedAnimation(parent: _foldCtl, curve: Curves.easeInOutCubic);
    _foldAnim.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _foldCtl.dispose();
    super.dispose();
  }

  /// Animated phone width: the foldable morphs from a narrow folded
  /// phone to a wide unfolded one.
  double get _phoneWidth => _device == DeviceModel.fold
      ? lerpDouble(228.0, 480.0, _foldAnim.value)!
      : 276.0;

  void _toggleFold() {
    if (_foldAnim.value > 0.5 ||
        _foldCtl.status == AnimationStatus.forward) {
      _foldCtl.reverse();
    } else {
      _foldCtl.forward();
    }
  }

  void _selectDevice(DeviceModel d) {
    setState(() => _device = d);
    if (d == DeviceModel.fold) {
      // Showcase the unfold animation on select.
      _foldCtl.reset();
      _foldCtl.forward();
    } else {
      _foldCtl.value = 0.0;
    }
  }

  void _resetView() => setState(() {
        _rotX = 0.0;
        _rotY = 0.0;
        _zoom = 1.0;
      });

  void _bumpZoom(double d) => setState(() {
        _zoom = clampDouble(_zoom + d, 0.6, 2.0);
      });

  static const _labels = {
    MockupMode.wallpaper: 'Wallpaper',
    MockupMode.lock: 'Lock',
    MockupMode.home: 'Home',
    MockupMode.chat: 'App',
    MockupMode.call: 'Call',
  };

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Keep the zoomed phone inside the dialog width (no overflow clipping).
    final fitCap = clampDouble(
        (MediaQuery.of(context).size.width - 64) / _phoneWidth, 0.6, 2.0);
    final effZoom = clampDouble(_zoom, 0.6, fitCap);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.smartphone_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Device preview',
                        style: textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_outlined),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final m in MockupMode.values)
                    ChoiceChip(
                      label: Text(_labels[m]!),
                      selected: _mode == m,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _mode = m),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final d in DeviceModel.values)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: _device == d,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _selectDevice(d),
                    ),
                ],
              ),
              if (widget.stages != null && widget.stages!.length > 1) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var i = 0; i < widget.stages!.length; i++)
                      ChoiceChip(
                        label: Text(widget.stages![i].label),
                        selected: _stageIndex == i,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _stageIndex = i),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Rotatable (360 deg) + zoomable phone area.
              SizedBox(
                height: 560 * effZoom + 24,
                child: Center(
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        _bumpZoom(e.scrollDelta.dy < 0 ? 0.1 : -0.1);
                      }
                    },
                    child: GestureDetector(
                      onPanUpdate: (d) => setState(() {
                        _rotY += d.delta.dx * 0.012;
                        _rotX += d.delta.dy * 0.012;
                      }),
                      onDoubleTap: _resetView,
                      child: Transform.scale(
                        scale: effZoom,
                        alignment: Alignment.center,
                        child: _PhoneFrame(
                          imageUrl: _currentImageUrl,
                          mode: _mode,
                          device: _device,
                          rotX: _rotX,
                          rotY: _rotY,
                          width: _phoneWidth,
                          crease: _device == DeviceModel.fold
                              ? _foldAnim.value
                              : 0.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_device == DeviceModel.fold)
                    IconButton(
                      tooltip:
                          _foldAnim.value > 0.5 ? 'Fold' : 'Unfold',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(_foldAnim.value > 0.5
                          ? Icons.unfold_less
                          : Icons.unfold_more),
                      onPressed: _toggleFold,
                    ),
                  IconButton(
                    tooltip: 'Zoom out',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_out_outlined),
                    onPressed:
                        _zoom > 0.6 ? () => _bumpZoom(-0.2) : null,
                  ),
                  SizedBox(
                    width: 52,
                    child: Center(
                      child: Text('${(effZoom * 100).round()}%',
                          style: textTheme.bodySmall),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zoom in',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_in_outlined),
                    onPressed:
                        _zoom < 2.0 ? () => _bumpZoom(0.2) : null,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Reset view',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh_outlined),
                    onPressed: _resetView,
                  ),
                ],
              ),
              Text(
                  'Drag to rotate 360 deg. Scroll or use the buttons to zoom. Double-tap to reset.',
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 4),
              Text(_labels[_mode]!,
                  style: textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One face queued for back-to-front drawing.
class _DrawFace {
  final Matrix4 transform;
  final Widget child;

  /// View-space z of the face center (painter's order).
  final double z;

  const _DrawFace(this.transform, this.child, this.z);
}

/// Phone hardware frame with a subtle 3D tilt, bezel, dynamic island,
/// side buttons and shadow.
class _PhoneFrame extends StatelessWidget {
  final String imageUrl;
  final MockupMode mode;
  final double rotX;
  final double rotY;
  final DeviceModel device;

  /// Rendered phone width (the foldable animates this).
  final double width;

  /// 0..1 fold crease visibility (foldable only).
  final double crease;

  const _PhoneFrame(
      {required this.imageUrl,
      required this.mode,
      this.device = DeviceModel.island,
      this.rotX = 0.0,
      this.rotY = 0.0,
      this.width = _w,
      this.crease = 0.0});

  static const _w = 276.0;
  static const _h = 572.0;

  /// Visual thickness of the phone (front/back sit at +/- half).
  static const _thickness = 16.0;

  @override
  Widget build(BuildContext context) {
    // Phone rotation: points go through R_y then R_x
    // (M_outer = P * R_x * R_y).
    final cx = cos(rotX);
    final cy = cos(rotY);
    const t = _thickness / 2;
    const eps = 0.02;

    // Flat phone: no 3D side walls - front/back only, painter sorted.
    final faces = <_DrawFace>[];
    // Front / back.
    if (cx * cy > eps) {
      faces.add(_DrawFace(
        Matrix4.identity()..translate(0.0, 0.0, t),
        _frontBody(),
        t * cx * cy,
      ));
    }
    if (-cx * cy > eps) {
      faces.add(_DrawFace(
        // Same orientation trick as the old whole-phone flip:
        // rotate pi about Y, then sit behind.
        Matrix4.identity()
          ..translate(0.0, 0.0, -t)
          ..rotateY(pi),
        _backBody(),
        -t * cx * cy,
      ));
    }
    // Painter's algorithm: back-to-front.
    faces.sort((a, b) => a.z.compareTo(b.z));
    return Transform(
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..rotateX(rotX)
        ..rotateY(rotY),
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (final f in faces)
            Transform(
              transform: f.transform,
              alignment: Alignment.center,
              child: f.child,
            ),
        ],
      ),
    );
  }

  /// How tilted the phone is (0 = head-on, 1 = edge-on). A real fold
  /// crease only catches the light at an angle, so its visibility
  /// follows the tilt.
  double get _tilt {
    double norm(double r) {
      var a = r % (2 * pi);
      if (a > pi) a -= 2 * pi;
      if (a < -pi) a += 2 * pi;
      return (a.abs() / (pi / 2)).clamp(0.0, 1.0);
    }

    return max(norm(rotX), norm(rotY));
  }

  /// Hinge barrel on the spine edge: prominent when folded, melts
  /// away as the phone unfolds.
  Widget _hingeBarrel() => Positioned(
        left: 3,
        top: 64,
        bottom: 64,
        width: 12,
        child: IgnorePointer(
          child: Opacity(
            opacity: (1 - crease).clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xFF45454f),
                    Color(0xFF17171c),
                    Color(0xFF2b2b33),
                  ],
                ),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 6,
                      offset: Offset(2, 0)),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 9; i++)
                    Container(
                      height: 2,
                      margin:
                          const EdgeInsets.symmetric(horizontal: 2.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _frontBody() => Container(
        width: width,
        height: _h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(device.radius),
          color: device.bodyColor,
          border: Border.all(color: device.borderColor, width: 2.5),
          boxShadow: const [
            BoxShadow(
                color: Color(0x66000000),
                blurRadius: 32,
                offset: Offset(0, 18)),
            BoxShadow(
                color: Color(0x22000000),
                blurRadius: 8,
                offset: Offset(0, 4)),
          ],
        ),
        child: Stack(
          children: [
            ...device.sideButtons(),
            // screen
            Positioned.fill(
              child: Padding(
                padding: device.bezel,
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(device.radius - 9),
                  child:
                      _MockupScreen(imageUrl: imageUrl, mode: mode),
                ),
              ),
            ),
            device.notchWidget(),
            // Hinge barrel on the spine edge (foldable, folded state).
            if (device == DeviceModel.fold && crease < 0.99)
              _hingeBarrel(),
            // Fold crease: a faint narrow valley that only catches the
            // light at an angle - nearly invisible head-on, like the
            // real inner display.
            if (crease > 0.01)
              Positioned(
                top: 0,
                bottom: 0,
                left: width / 2 - 4,
                width: 8,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: crease * (0.12 + 0.88 * _tilt),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.22),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  /// Back panel with a per-device camera module.
  Widget _backBody() => Container(
        width: width,
        height: _h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(device.radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: device.backColors,
          ),
          border: Border.all(color: device.borderColor, width: 2.5),
          boxShadow: const [
            BoxShadow(
                color: Color(0x66000000),
                blurRadius: 32,
                offset: Offset(0, 18)),
            BoxShadow(
                color: Color(0x22000000),
                blurRadius: 8,
                offset: Offset(0, 4)),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              top: 18,
              left: 18,
              child: _cameraModule(),
            ),
            // Foldable hinge seam on the back panel.
            if (device == DeviceModel.fold)
              Positioned(
                top: 12,
                bottom: 12,
                left: width / 2 - 1,
                width: 2,
                child: Container(
                    color: Colors.black.withOpacity(0.45)),
              ),
            // Hinge barrel on the spine edge (folded state).
            if (device == DeviceModel.fold && crease < 0.99)
              _hingeBarrel(),
            // subtle branding dot
            Center(
              child: Opacity(
                opacity: 0.35,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0xFF6b6b76), width: 2),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Center(
                    child: Text('MH',
                        style: TextStyle(
                            color: Color(0xFF9a9aa5),
                            fontWeight: FontWeight.w800,
                            fontSize: 13)),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  /// Camera hardware per device: triple plateau, vertical dual, or
  /// single large lens.
  Widget _cameraModule() => switch (device) {
        DeviceModel.notch => Container(
              width: 64,
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0xFF202026),
                borderRadius: BorderRadius.circular(32),
                border:
                    Border.all(color: const Color(0xFF484850), width: 1.5),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [_lens(), _lens()],
              ),
            ),
        DeviceModel.edge => Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xFF2a2e38),
                shape: BoxShape.circle,
                border:
                    Border.all(color: const Color(0xFF8a90a0), width: 2),
              ),
              child: Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0d1526),
                    border: Border.all(
                        color: const Color(0xFF5a5a66), width: 3),
                  ),
                  child: Center(
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF2b4a7a),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        // Foldable: vertical triple-lens camera strip.
        DeviceModel.fold => Container(
              width: 54,
              height: 168,
              decoration: BoxDecoration(
                color: const Color(0xFF1e1e24),
                borderRadius: BorderRadius.circular(27),
                border:
                    Border.all(color: const Color(0xFF484850), width: 1.5),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [_lens(), _lens(), _lens()],
              ),
            ),
        _ => Container(
              width: 118,
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0xFF232329),
                borderRadius: BorderRadius.circular(28),
                border:
                    Border.all(color: const Color(0xFF484850), width: 1.5),
              ),
              child: Stack(
                children: [
                  Positioned(top: 12, left: 12, child: _lens()),
                  Positioned(top: 12, right: 12, child: _lens()),
                  Positioned(bottom: 12, left: 12, child: _lens()),
                  Positioned(
                    bottom: 22,
                    right: 20,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFFF3c4),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      };

  Widget _lens() => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF0d1526),
          border: Border.all(color: const Color(0xFF5a5a66), width: 3),
        ),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF2b4a7a),
            ),
          ),
        ),
      );

  static Widget sideButton(
          {required double height, required Color color}) =>
      Container(
        width: 4,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

/// Renders either a network URL (http/https) or a local file path.
Widget _buildMockupImage(String source) {
  final isNet = source.startsWith('http://') || source.startsWith('https://');
  if (isNet) {
    return Image.network(
      source,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(color: Colors.black87),
    );
  }
  final f = File(source);
  if (!f.existsSync()) return Container(color: Colors.black87);
  return Image.file(
    f,
    fit: BoxFit.cover,
    errorBuilder: (_, __, ___) => Container(color: Colors.black87),
  );
}

class _MockupScreen extends StatelessWidget {
  final String imageUrl;
  final MockupMode mode;

  const _MockupScreen({required this.imageUrl, required this.mode});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildMockupImage(imageUrl),
        switch (mode) {
          MockupMode.wallpaper => const SizedBox.shrink(),
          MockupMode.lock => const _LockOverlay(),
          MockupMode.home => const _HomeOverlay(),
          MockupMode.chat => const _ChatOverlay(),
          MockupMode.call => _CallOverlay(imageUrl: imageUrl),
        },
      ],
    );
  }
}

/// White text with a soft shadow so it stays legible on any wallpaper.
class _ShadedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const _ShadedText(this.text, {this.style});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: (style ?? const TextStyle()).copyWith(
        color: Colors.white,
        shadows: const [
          Shadow(color: Colors.black54, blurRadius: 8),
          Shadow(color: Colors.black38, blurRadius: 2),
        ],
      ),
    );
  }
}

String _clockNow() {
  final n = DateTime.now();
  final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
  return '$h:${n.minute.toString().padLeft(2, '0')}';
}

String _dateNow() {
  const days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday'
  ];
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];
  final n = DateTime.now();
  return '${days[n.weekday - 1]}, ${months[n.month - 1]} ${n.day}';
}

/// Dark gradient at top/bottom for overlay legibility.
Widget _scrim({bool top = true, bool bottom = true}) => Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              if (top) Colors.black.withOpacity(0.45) else Colors.transparent,
              Colors.transparent,
              Colors.transparent,
              if (bottom)
                Colors.black.withOpacity(0.5)
              else
                Colors.transparent,
            ],
            stops: const [0.0, 0.28, 0.62, 1.0],
          ),
        ),
      ),
    );

class _LockOverlay extends StatelessWidget {
  const _LockOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _scrim(),
        Column(
          children: [
            const SizedBox(height: 44),
            const Icon(Icons.lock_outline,
                color: Colors.white, size: 18),
            const SizedBox(height: 6),
            _ShadedText(_clockNow(),
                style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.w200,
                    height: 1.0)),
            const SizedBox(height: 4),
            _ShadedText(_dateNow(),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
            const SizedBox(height: 18),
            _notification(
                Icons.message_outlined, 'Messages', 'Maya', 'See you at 7!', '9:12'),
            const SizedBox(height: 8),
            _notification(Icons.mail_outline, 'Mail', 'Zedge',
                'Your upload was approved', '8:47'),
            const Spacer(),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _roundButton(Icons.flashlight_on_outlined),
                  _roundButton(Icons.photo_camera_outlined),
                ],
              ),
            ),
            Center(
              child: Container(
                width: 120,
                height: 4.5,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _notification(IconData icon, String app, String title, String body,
      String time) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.22),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 20, color: Colors.black87),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(app,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(time,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                  ],
                ),
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Text(body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundButton(IconData icon) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.35),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      );
}

class _HomeOverlay extends StatelessWidget {
  const _HomeOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _scrim(top: true, bottom: false),
        Column(
          children: [
            const SizedBox(height: 40),
            const _StatusBar(),
            const SizedBox(height: 14),
            Expanded(
              child: GridView.count(
                crossAxisCount: 4,
                physics: const NeverScrollableScrollPhysics(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14),
                mainAxisSpacing: 14,
                crossAxisSpacing: 6,
                children: const [
                  _AppIcon(Icons.phone, Color(0xFF34c759), 'Phone'),
                  _AppIcon(Icons.message, Color(0xFF30b455), 'Messages'),
                  _AppIcon(Icons.public, Color(0xFF0a84ff), 'Browser'),
                  _AppIcon(Icons.photo_camera, Color(0xFF8e8e93), 'Camera'),
                  _AppIcon(Icons.photo_library, Color(0xFFff9f0a), 'Photos'),
                  _AppIcon(Icons.map, Color(0xFF30b455), 'Maps'),
                  _AppIcon(Icons.music_note, Color(0xFFff375f), 'Music'),
                  _AppIcon(Icons.access_time, Color(0xFF1c1c1e), 'Clock'),
                  _AppIcon(Icons.note_alt, Color(0xFFffd60a), 'Notes'),
                  _AppIcon(Icons.calendar_month, Color(0xFFff453a), 'Calendar'),
                  _AppIcon(Icons.mail, Color(0xFF0a84ff), 'Mail'),
                  _AppIcon(Icons.settings, Color(0xFF8e8e93), 'Settings'),
                  _AppIcon(Icons.play_arrow, Color(0xFF0a84ff), 'Videos'),
                  _AppIcon(Icons.shopping_bag, Color(0xFFbf5af2), 'Store'),
                  _AppIcon(Icons.account_balance_wallet, Color(0xFF30d158), 'Wallet'),
                  _AppIcon(Icons.health_and_safety, Color(0xFFff6482), 'Health'),
                ],
              ),
            ),
            // dock
            Container(
              margin:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.25),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _AppIcon(Icons.phone, Color(0xFF34c759), '', small: true),
                  _AppIcon(Icons.public, Color(0xFF0a84ff), '', small: true),
                  _AppIcon(Icons.message, Color(0xFF30b455), '', small: true),
                  _AppIcon(Icons.music_note, Color(0xFFff375f), '', small: true),
                ],
              ),
            ),
            Container(
              width: 120,
              height: 4.5,
              margin: const EdgeInsets.only(bottom: 8, top: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Row(
        children: [
          _ShadedText(_clockNow(),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          const Icon(Icons.signal_cellular_alt,
              color: Colors.white, size: 14),
          const SizedBox(width: 4),
          const Icon(Icons.wifi, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          const Icon(Icons.battery_full,
              color: Colors.white, size: 16),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final bool small;

  const _AppIcon(this.icon, this.color, this.label, {this.small = false});

  @override
  Widget build(BuildContext context) {
    final size = small ? 46.0 : 52.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, color.withOpacity(0.75)],
            ),
            borderRadius: BorderRadius.circular(size * 0.28),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2)),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.52),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 3),
          _ShadedText(label,
              style: const TextStyle(fontSize: 10)),
        ],
      ],
    );
  }
}

/// In-app view: a chat app with the wallpaper as the chat background.
class _ChatOverlay extends StatelessWidget {
  const _ChatOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // dim the wallpaper slightly so bubbles read well
        Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.25))),
        Column(
          children: [
            Container(
              padding: const EdgeInsets.only(
                  top: 44, left: 8, right: 8, bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1c1c1e).withOpacity(0.92),
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.arrow_back,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 6),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [
                        Color(0xFFbf5af2),
                        Color(0xFF0a84ff)
                      ]),
                    ),
                    child: const Center(
                        child: Text('M',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700))),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Maya',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                        Text('online',
                            style: TextStyle(
                                color: Colors.white60, fontSize: 11)),
                      ],
                    ),
                  ),
                  const Icon(Icons.videocam_outlined,
                      color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Icon(Icons.call_outlined,
                      color: Colors.white70, size: 20),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: const [
                  _Bubble('That wallpaper is unreal', false),
                  _Bubble('Right? Made it this morning', true),
                  _Bubble('Send me the night version too', false),
                  _Bubble('Done — check your lock screen', true),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.all(10),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2c2c2e).withOpacity(0.95),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                children: [
                  Expanded(
                    child: Text('Message',
                        style: TextStyle(
                            color: Colors.white38, fontSize: 14)),
                  ),
                  Icon(Icons.send_outlined,
                      color: Colors.white70, size: 20),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool mine;
  const _Bubble(this.text, this.mine);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 180),
        decoration: BoxDecoration(
          color: mine
              ? const Color(0xFF0a84ff).withOpacity(0.92)
              : const Color(0xFF2c2c2e).withOpacity(0.92),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
      ),
    );
  }
}

/// Incoming call screen over a blurred wallpaper.
class _CallOverlay extends StatelessWidget {
  final String imageUrl;
  const _CallOverlay({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: _buildMockupImage(imageUrl),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.62),
                Colors.black.withOpacity(0.30),
                Colors.black.withOpacity(0.68),
              ],
            ),
          ),
        ),
        Column(
          children: [
            const SizedBox(height: 64),
            const Text('Incoming call',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 16),
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [
                  Color(0xFFbf5af2),
                  Color(0xFF0a84ff)
                ]),
                border: Border.all(
                    color: Colors.white.withOpacity(0.6), width: 2),
              ),
              child: const Center(
                  child: Text('M',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w700))),
            ),
            const SizedBox(height: 12),
            const Text('Maya Chen',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600)),
            const Text('mobile',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 40, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      _callButton(Icons.message_outlined,
                          Colors.white.withOpacity(0.25)),
                      const SizedBox(height: 6),
                      const Text('Message',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                  Column(
                    children: [
                      _callButton(Icons.alarm_outlined,
                          Colors.white.withOpacity(0.25)),
                      const SizedBox(height: 6),
                      const Text('Remind',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 44, vertical: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _callButton(Icons.call_end, const Color(0xFFff453a),
                      big: true),
                  _callButton(Icons.call, const Color(0xFF30d158),
                      big: true),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ],
    );
  }

  Widget _callButton(IconData icon, Color bg, {bool big = false}) {
    final s = big ? 62.0 : 46.0;
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white, size: s * 0.48),
    );
  }
}
