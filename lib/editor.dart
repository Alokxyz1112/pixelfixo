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

  PostOptions get _post => PostOptions(natural: natural ? .25 : 0, grain: grain, vibrance: color ? .12 : 0);

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
              IconButton(tooltip: 'Change settings', icon: const Icon(Icons.tune_rounded), onPressed: () => setState(() => phase = Phase.setup)),
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
          child: CompareSlider(before: widget.source, after: resultPng!),
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
          Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.photo_library_outlined), label: const Text('New photo'))),
          const SizedBox(width: 12),
          Expanded(child: GradientButton(label: saved ? 'Saved' : 'Save', icon: saved ? Icons.check_rounded : Icons.download_rounded, onPressed: saved ? null : _save)),
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
            borderRadius: BorderRadius.circular(20),
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
          const SizedBox(height: 16),
          _section(context, 'Size', SegmentedButton<int>(
            segments: const [ButtonSegment(value: 2, label: Text('2x')), ButtonSegment(value: 3, label: Text('3x')), ButtonSegment(value: 4, label: Text('4x'))],
            selected: {scale},
            showSelectedIcon: false,
            onSelectionChanged: busy ? null : (v) => setState(() => scale = v.first),
          )),
          const SizedBox(height: 12),
          _section(context, 'Mode', Column(children: [for (final m in UpModel.values) _modeTile(context, m, busy)])),
          const SizedBox(height: 12),
          _section(context, 'Look', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Natural')), ButtonSegment(value: false, label: Text('Sharp'))],
              selected: {natural},
              showSelectedIcon: false,
              onSelectionChanged: busy ? null : (v) => setState(() => natural = v.first),
            ),
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
              Icon(Icons.auto_fix_high_rounded, size: 16, color: c.onSurfaceVariant),
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
            GradientButton(label: phase == Phase.error ? 'Retry' : 'Upscale ${scale}x', icon: phase == Phase.error ? Icons.refresh_rounded : Icons.auto_awesome_rounded, onPressed: _go),
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
            Container(height: 10, color: c.surfaceContainerHighest),
            FractionallySizedBox(widthFactor: v, child: Container(height: 10, decoration: const BoxDecoration(gradient: brandGradient))),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => _cancel = true, icon: const Icon(Icons.close_rounded), label: const Text('Cancel'))),
    ]);
  }

  Widget _section(BuildContext context, String title, Widget child) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            child,
          ]),
        ),
      );

  Widget _modeTile(BuildContext context, UpModel m, bool busy) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final sel = m == model;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sel ? c.primary : c.outlineVariant.withValues(alpha: .5), width: sel ? 2 : 1),
          color: sel ? c.primary.withValues(alpha: .08) : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : () => setState(() => model = m),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(switch (m) { UpModel.fast => Icons.bolt_rounded, UpModel.ultra => Icons.diamond_outlined, UpModel.art => Icons.brush_outlined }, color: sel ? c.primary : c.onSurfaceVariant),
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

/// Drag the handle to wipe between the original (left) and the upscaled result (right).
class CompareSlider extends StatefulWidget {
  final Uint8List before, after;
  final double initial;
  const CompareSlider({super.key, required this.before, required this.after, this.initial = .5});
  @override
  State<CompareSlider> createState() => _CompareSliderState();
}

class _CompareSliderState extends State<CompareSlider> {
  late double x = widget.initial;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      return GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() => x = (x + d.delta.dx / box.maxWidth).clamp(0.0, 1.0)),
        onTapDown: (d) => setState(() => x = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
            InteractiveViewer(
              maxScale: 8,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(widget.after, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                ClipRect(
                  clipper: _Left(x),
                  child: Image.memory(widget.before, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.none),
                ),
              ]),
            ),
            Positioned(
              left: x * box.maxWidth - 1,
              top: 0,
              bottom: 0,
              child: IgnorePointer(child: Container(width: 2, color: Colors.white)),
            ),
            Positioned(
              left: x * box.maxWidth - 20,
              top: box.maxHeight / 2 - 20,
              child: IgnorePointer(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .3), blurRadius: 10)]),
                  child: const Icon(Icons.compare_arrows_rounded, color: brandA),
                ),
              ),
            ),
            const Positioned(left: 12, top: 12, child: _Tag('Before')),
            const Positioned(right: 12, top: 12, child: _Tag('After')),
          ]),
        ),
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
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
      );
}
