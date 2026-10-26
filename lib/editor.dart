import 'dart:math' as math;
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'engine/upscale.dart';
import 'theme.dart';

enum Phase { setup, downloading, running, done, error }

/// Timestamp file name like 20261026_004512.png. Nothing else about the photo goes into the name.
String saveName(DateTime t) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}.png';
}

class EditorScreen extends StatefulWidget {
  final Uint8List source;
  // Only used by tests and screenshots.
  final Phase? demoPhase;
  final Uint8List? demoResult;
  final double demoProgress;
  final Size? demoSize;
  const EditorScreen({super.key, required this.source, this.demoPhase, this.demoResult, this.demoProgress = 0, this.demoSize});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const _media = MethodChannel('pixelfixo/media');
  int scale = 4;
  UpModel model = UpModel.fast;
  bool natural = true, color = false, grain = false;
  Phase phase = Phase.setup;
  double progress = 0;
  String? error;
  UpscaleResult? result;
  Uint8List? resultPng;
  int outW = 0, outH = 0;
  Size? size;
  final Map<UpModel, bool> ready = {UpModel.fast: true};
  bool _cancel = false;
  final _watch = Stopwatch();
  bool saved = false;

  @override
  void initState() {
    super.initState();
    if (widget.demoPhase != null) {
      phase = widget.demoPhase!;
      resultPng = widget.demoResult;
      progress = widget.demoProgress;
      size = widget.demoSize;
      ready[UpModel.ultra] = true;
      return;
    }
    _readSize();
    for (final m in UpModel.values) {
      Upscaler.ready(m).then((v) => mounted ? setState(() => ready[m] = v) : null);
    }
  }

  Future<void> _readSize() async {
    final buf = await ui.ImmutableBuffer.fromUint8List(widget.source);
    final d = await ui.ImageDescriptor.encoded(buf);
    if (mounted) setState(() => size = Size(d.width.toDouble(), d.height.toDouble()));
    d.dispose();
    buf.dispose();
  }

  PostOptions get _post => PostOptions(texture: natural ? .3 : .6, grain: grain, vibrance: color ? .12 : 0);

  Future<void> _go() async {
    _cancel = false;
    setState(() {
      error = null;
      saved = false;
      progress = 0;
    });
    try {
      if (ready[model] != true) {
        setState(() => phase = Phase.downloading);
        await Upscaler.download(model, progress: (p) => mounted ? setState(() => progress = p) : null, cancelled: () => _cancel);
        ready[model] = true;
        progress = 0;
      }
      setState(() => phase = Phase.running);
      _watch
        ..reset()
        ..start();
      final r = await Upscaler.run(widget.source, scale, model, post: _post, progress: (p) => mounted ? setState(() => progress = p) : null, cancelled: () => _cancel);
      if (!mounted) return;
      setState(() {
        result = r;
        resultPng = r.png;
        outW = r.w;
        outH = r.h;
        phase = Phase.done;
      });
    } on UpscaleCancelled {
      if (mounted) setState(() => phase = Phase.setup);
    } catch (e) {
      if (mounted) {
        setState(() {
          phase = Phase.error;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      _watch.stop();
    }
  }

  Future<void> _save() async {
    final png = resultPng;
    if (png == null) return;
    final f = File('${(await getTemporaryDirectory()).path}/out_${DateTime.now().microsecondsSinceEpoch}.png');
    await f.writeAsBytes(png);
    try {
      await _media.invokeMethod('save', {'path': f.path, 'name': saveName(DateTime.now()), 'mime': 'image/png'});
      if (!mounted) return;
      setState(() => saved = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to Pictures/Pixelfixo'), behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e'), behavior: SnackBarBehavior.floating));
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  String? get _eta {
    if (phase != Phase.running) return null;
    if (progress >= 1) return 'Finishing up';
    if (progress < .05 || _watch.elapsedMilliseconds < 1500) return 'Getting started';
    final left = _watch.elapsedMilliseconds / 1000 * (1 - progress) / progress;
    return '${estimateText(left)} left';
  }

  @override
  Widget build(BuildContext context) {
    final busy = phase == Phase.downloading || phase == Phase.running;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (did, _) {
        if (!did) _cancel = true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(phase == Phase.done ? 'Before and after' : 'Upscale'),
          actions: [
            if (phase == Phase.done)
              IconButton(tooltip: 'Change settings', icon: const Icon(Icons.tune), onPressed: () => setState(() => phase = Phase.setup)),
          ],
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, .03), end: Offset.zero).animate(a), child: c)),
            child: switch (phase) {
              Phase.done => _done(context),
              _ => _setup(context, busy),
            },
          ),
        ),
      ),
    );
  }

  Widget _done(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final r = result;
    return Column(key: const ValueKey('done'), children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CompareSlider(before: widget.source, after: resultPng!, outW: outW, outH: outH),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          r == null ? 'Drag to compare' : '${r.srcW} x ${r.srcH}  to  ${r.w} x ${r.h}${r.shrunk ? ' (big photo, shrunk a bit first)' : ''}',
          style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.photo_library_outlined, size: 20), label: const Text('New photo'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(onPressed: saved ? null : _save, icon: Icon(saved ? Icons.check : Icons.download_outlined, size: 20), label: Text(saved ? 'Saved' : 'Save'))),
        ]),
      ),
    ]);
  }

  Widget _setup(BuildContext context, bool busy) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final s = size;
    final est = s == null ? null : estimateText(estimateSeconds(model, s.width.round(), s.height.round()));
    return Column(key: const ValueKey('setup'), children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: c.surfaceContainerHighest,
              constraints: const BoxConstraints(maxHeight: 260),
              child: Image.memory(widget.source, fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
          if (s != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text('${s.width.round()} x ${s.height.round()}  to  ${s.width.round() * scale} x ${s.height.round() * scale}',
                  style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            ),
          const SizedBox(height: 28),
          _section(context, 'Size', Segmented<int>(items: const [(2, '2x'), (3, '3x'), (4, '4x')], value: scale, onChanged: busy ? null : (v) => setState(() => scale = v))),
          const SizedBox(height: 28),
          _section(context, 'Mode', Column(children: [for (final m in UpModel.values) _modeTile(context, m, busy)])),
          const SizedBox(height: 28),
          _section(context, 'Look', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Segmented<bool>(items: const [(true, 'Natural'), (false, 'More texture')], value: natural, onChanged: busy ? null : (v) => setState(() => natural = v)),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restore color'),
              subtitle: const Text('Gentle lift for faded photos, skin stays as it is'),
              value: color,
              onChanged: busy ? null : (v) => setState(() => color = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Film grain'),
              subtitle: const Text('A light grain so it looks like a photo, not a render'),
              value: grain,
              onChanged: busy ? null : (v) => setState(() => grain = v),
            ),
            Row(children: [
              Icon(Icons.info_outline, size: 16, color: c.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text('Blocky JPEGs get cleaned up on their own.', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant))),
            ]),
          ])),
          if (phase == Phase.error) ...[
            const SizedBox(height: 12),
            Card(
              color: c.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, color: c.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(child: Text(error ?? 'Something went wrong', style: TextStyle(color: c.onErrorContainer))),
                ]),
              ),
            ),
          ],
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: busy ? _progress(context) : Column(children: [
            if (est != null && phase != Phase.error)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('$est${ready[model] == true ? '' : ' after a one time ${(model.approxBytes / 1e6).round()} MB download'}', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
              ),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: _go, child: Text(phase == Phase.error ? 'Try again' : 'Upscale ${scale}x'))),
          ]),
        ),
      ),
    ]);
  }

  Widget _progress(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final label = phase == Phase.downloading ? 'Downloading ${model.label} model' : 'Upscaling';
    return Column(children: [
      Row(children: [
        Text(label, style: t.titleSmall),
        const Spacer(),
        Text(phase == Phase.downloading ? '${(progress * 100).round()}%' : (_eta ?? ''), style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
      ]),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: progress.clamp(0, 1)),
          duration: const Duration(milliseconds: 300),
          builder: (_, v, _) => Stack(children: [
            Container(height: 4, color: c.surfaceContainerHighest),
            FractionallySizedBox(widthFactor: v, child: Container(height: 4, color: c.onSurface)),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => _cancel = true, icon: const Icon(Icons.close_rounded), label: const Text('Cancel'))),
    ]);
  }

  Widget _section(BuildContext context, String title, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(title),
        child,
      ]);

  Widget _modeTile(BuildContext context, UpModel m, bool busy) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final sel = m == model;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sel ? c.onSurface : c.outlineVariant, width: sel ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : () => setState(() => model = m),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(switch (m) { UpModel.fast => Icons.bolt_outlined, UpModel.high => Icons.high_quality_outlined, UpModel.ultra => Icons.hd_outlined, UpModel.art => Icons.brush_outlined }, size: 22, color: sel ? c.onSurface : c.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.label, style: t.titleSmall),
                  Text(m.hint, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                ]),
              ),
              if (ready[m] != true) Text('${(m.approxBytes / 1e6).round()} MB', style: t.labelSmall?.copyWith(color: c.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Drag the round handle to wipe between the original (left) and the upscaled result (right).
/// Pinch or double tap anywhere else to zoom; both sides follow the same zoom.
class CompareSlider extends StatefulWidget {
  final Uint8List before, after;
  final double initial;
  final int outW, outH;
  const CompareSlider({super.key, required this.before, required this.after, this.initial = .5, this.outW = 0, this.outH = 0});
  @override
  State<CompareSlider> createState() => _CompareSliderState();
}

class _CompareSliderState extends State<CompareSlider> {
  late double x = widget.initial;
  bool peek = false;
  final _tc = TransformationController();
  Offset _tap = Offset.zero;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// Zoom where one output pixel is one physical screen pixel.
  double _fullScale(Size box) {
    if (widget.outW <= 0 || widget.outH <= 0) return 4;
    final fit = math.min(box.width / widget.outW, box.height / widget.outH);
    return math.max(2.0, 1 / (fit * MediaQuery.of(context).devicePixelRatio));
  }

  void _doubleTap(Size box) {
    if (_tc.value.getMaxScaleOnAxis() > 1.01) {
      _tc.value = Matrix4.identity();
      return;
    }
    final z = _fullScale(box);
    _tc.value = Matrix4.identity()
      ..translateByDouble(-_tap.dx * (z - 1), -_tap.dy * (z - 1), 0, 1)
      ..scaleByDouble(z, z, z, 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, box = Size(c.maxWidth, c.maxHeight);
      Widget pic(Uint8List b, FilterQuality q) => Image.memory(b, fit: BoxFit.contain, width: w, height: c.maxHeight, filterQuality: q, gaplessPlayback: true);
      final split = peek ? 1.0 : x;
      final zoomed = _tc.value.getMaxScaleOnAxis() > 1.01;
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
          GestureDetector(
            onDoubleTapDown: (d) => _tap = d.localPosition,
            onDoubleTap: () => _doubleTap(box),
            onLongPressStart: (_) => setState(() => peek = true),
            onLongPressEnd: (_) => setState(() => peek = false),
            child: InteractiveViewer(transformationController: _tc, maxScale: math.max(8.0, _fullScale(box) * 2), child: pic(widget.after, FilterQuality.medium)),
          ),
          // The original follows the same zoom and pan, cut at the divider in screen space, drawn pixel for pixel.
          IgnorePointer(
            child: ClipRect(clipper: _Left(split), child: Transform(transform: _tc.value, child: pic(widget.before, FilterQuality.none))),
          ),
          Positioned(left: split * w - 1, top: 0, bottom: 0, child: IgnorePointer(child: Container(width: 1.5, color: Colors.white))),
          // Only the handle moves the divider, so the rest is free for zooming.
          Positioned(
            left: split * w - 22,
            top: c.maxHeight / 2 - 22,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => setState(() => x = ((x * w + d.delta.dx) / w).clamp(0.0, 1.0)),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.black12)),
                child: const Icon(Icons.code, size: 20, color: Colors.black),
              ),
            ),
          ),
          const Positioned(left: 12, top: 12, child: IgnorePointer(child: _Tag('Before'))),
          const Positioned(right: 12, top: 12, child: IgnorePointer(child: _Tag('After'))),
          Positioned(left: 0, right: 0, bottom: 12, child: IgnorePointer(child: Center(child: _Tag(zoomed ? 'Double tap to fit' : 'Pinch or double tap to zoom')))),
        ]),
      );
    });
  }
}

class _Left extends CustomClipper<Rect> {
  final double x;
  _Left(this.x);
  @override
  Rect getClip(Size s) => Rect.fromLTWH(0, 0, s.width * x, s.height);
  @override
  bool shouldReclip(_Left o) => o.x != x;
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(6)),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
      );
}
