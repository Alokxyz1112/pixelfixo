import 'dart:io';
import 'package:flutter/material.dart';
import 'engine/look.dart';
import 'engine/upscale.dart';
import 'gallery_save.dart';
import 'theme.dart';

enum _Job { waiting, running, saved, failed }

/// Upscales a queue of photos with one preset, one at a time, and saves each as it finishes.
class BatchScreen extends StatefulWidget {
  final List<String> paths;
  const BatchScreen({super.key, required this.paths});
  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  late final List<String> _paths = List.of(widget.paths);
  late final List<_Job> _jobs = List.filled(_paths.length, _Job.waiting);
  LookPreset preset = LookPreset.photo;
  int scale = 4;
  bool jpeg = false;
  bool ultraReady = false;
  bool running = false;
  bool cancel = false;
  double progress = 0;
  int index = 0;
  String? note;

  @override
  void initState() {
    super.initState();
    Upscaler.ready(UpModel.ultra).then((v) {
      if (mounted) setState(() => ultraReady = v);
    });
  }

  LookChoice get _choice {
    final c = lookFor(preset, ultraReady: ultraReady);
    return LookChoice(model: c.model, scale: scale, natural: c.natural, color: c.color, grain: c.grain, cleanup: c.cleanup, faces: c.faces, sharpen: c.sharpen);
  }

  String _name(int i) {
    final p = _paths[i];
    final slash = p.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? p : p.substring(slash + 1);
  }

  Future<void> _go() async {
    if (running || _paths.isEmpty) return;
    final choice = _choice;
    setState(() {
      running = true;
      cancel = false;
      note = null;
      progress = 0;
    });
    var failed = 0;
    try {
      if (!await Upscaler.ready(choice.model)) {
        setState(() => note = 'Downloading ${choice.model.label}');
        await Upscaler.download(choice.model, progress: (p) {
          if (mounted) setState(() => progress = p);
        }, cancelled: () => cancel);
      }
      for (var i = 0; i < _paths.length; i++) {
        if (cancel) break;
        if (_jobs[i] == _Job.saved) continue;
        setState(() {
          index = i;
          _jobs[i] = _Job.running;
          progress = 0;
          note = '${i + 1} of ${_paths.length}';
        });
        try {
          final bytes = await File(_paths[i]).readAsBytes();
          final r = await Upscaler.run(bytes, choice.scale, choice.model,
              post: choice.post, faces: choice.faces && choice.model != UpModel.art, progress: (p) {
            if (mounted) setState(() => progress = p);
          }, cancelled: () => cancel);
          await saveToGallery(r.png, jpeg: jpeg);
          if (mounted) setState(() => _jobs[i] = _Job.saved);
        } on UpscaleCancelled {
          if (mounted) setState(() => _jobs[i] = _Job.waiting);
          break;
        } catch (e) {
          failed++;
          if (mounted) setState(() => _jobs[i] = _Job.failed);
        }
      }
    } on UpscaleCancelled {
      // The model download was cancelled. Nothing was saved for this pass.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')), behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) {
        final saved = _jobs.where((j) => j == _Job.saved).length;
        setState(() {
          running = false;
          note = failed == 0 ? '$saved saved to Pictures/Pixelfixo' : '$saved saved, $failed failed';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final choice = _choice;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (did, _) {
        if (!did) cancel = true;
      },
      child: Scaffold(
        appBar: AppBar(title: Text('${_paths.length} photos')),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                Text(choice.model.hint, style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                const SizedBox(height: 16),
                const SectionLabel('Preset'),
                LookPresetBar(value: preset, onChanged: running ? null : (p) => setState(() {
                  preset = p;
                  scale = lookFor(p, ultraReady: ultraReady).scale;
                })),
                const SizedBox(height: 22),
                SectionLabel('Size'),
                Segmented<int>(items: const [(2, '2x'), (3, '3x'), (4, '4x')], value: scale, onChanged: running ? null : (v) => setState(() => scale = v)),
                const SizedBox(height: 22),
                SectionLabel('File'),
                Segmented<bool>(items: const [(false, 'PNG'), (true, 'JPEG')], value: jpeg, onChanged: running ? null : (v) => setState(() => jpeg = v)),
                const SizedBox(height: 22),
                const SectionLabel('Queue'),
                for (var i = 0; i < _paths.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_name(i), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(switch (_jobs[i]) { _Job.waiting => 'Waiting', _Job.running => 'Upscaling', _Job.saved => 'Saved', _Job.failed => 'Failed' }),
                    trailing: running || _jobs[i] == _Job.saved
                        ? Icon(
                            switch (_jobs[i]) {
                              _Job.saved => Icons.check,
                              _Job.running => Icons.autorenew,
                              _Job.failed => Icons.error_outline,
                              _ => Icons.schedule,
                            },
                            size: 18,
                          )
                        : IconButton(
                            tooltip: 'Remove',
                            onPressed: () => setState(() {
                              _paths.removeAt(i);
                              _jobs.removeAt(i);
                            }),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: running
                  ? Column(children: [
                      Row(children: [
                        Text(note ?? 'Upscaling', style: t.titleSmall),
                        const Spacer(),
                        Text('${(progress * 100).round()}%', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                      ]),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0).toDouble(), minHeight: 4),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => cancel = true, icon: const Icon(Icons.close_rounded), label: const Text('Cancel'))),
                    ])
                  : Column(children: [
                      if (note != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(note!, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant))),
                      SizedBox(width: double.infinity, child: FilledButton(onPressed: _paths.isEmpty ? null : _go, child: Text('Upscale ${_paths.length}'))),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }
}
