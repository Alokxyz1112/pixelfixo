import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'jpeg_restore.dart';
import 'upscale_post.dart';
export 'upscale_post.dart' show PostOptions;

/// Image upscaling (super resolution), fully on the phone.
///
/// Every model is a 4x model. 2x and 3x run the 4x model and shrink the result with a good filter, which looks
/// sharper and cleaner than a separate small 2x net did in our tests.
///
/// Fast and High: Real-ESRGAN realesr-general-x4v3 by Xintao Wang et al., BSD-3-Clause,
/// https://github.com/xinntao/Real-ESRGAN. Fast mixes in more of the official denoise weights (cleaner), High less
/// (keeps more real texture). The mix is the method the Real-ESRGAN authors ship for its denoise strength setting.
/// Ultra: model by Philip Hofmann (Phhofm), CC BY 4.0, https://github.com/Phhofm/models
/// Art: Real-ESRGAN anime 6B by Xintao Wang et al., BSD-3-Clause, https://github.com/xinntao/Real-ESRGAN
/// The ONNX files are conversions of the official .pth weights (see assets/models/README.md).
enum UpModel {
  fast('Fast', 'realesr-general-x4v3-d50', 'Clean and sharp with real detail. Good on most photos.', null, 0, '', 8.0, 256),
  high('High', 'realesr-general-x4v3-d30', 'Keeps more grain, skin and hair texture. Same speed as Fast.', null, 0, '', 8.0, 256),
  ultra('Ultra', '4xNomosWebPhoto_RealPLKSR', 'Slowest. Most detail, with natural faces.',
      '4xNomosWebPhoto_RealPLKSR.onnx', 29902622, '550ec2c879439e707717f6c8250b82908d19fa3ab4f75f26c1713f685c8ef371', 70.0, 192),
  art('Art', 'RealESRGAN_x4plus_anime_6B', 'Drawings, anime and memes. Clean lines.', 'RealESRGAN_x4plus_anime_6B.onnx',
      17939941, 'd0c0ba25911cdc60151a1bdb33b4cc3d7beb86317b6d1540a290d78e0a0d8255', 15.0, 192);

  final String label, name, hint;
  final String? file; // null = bundled in the APK
  final int approxBytes;
  final String sha;

  /// Rough seconds per input megapixel on a mid range phone CPU (estimate, refined after each real run).
  final double secPerMp;

  /// Largest tile edge in input pixels. Bigger tiles mean fewer seams and less overhead, but more memory.
  final int tile;
  const UpModel(this.label, this.name, this.hint, this.file, this.approxBytes, this.sha, this.secPerMp, this.tile);
  bool get bundled => file == null;
}

const modelBase = 'https://github.com/Alokxyz1112/pixelfixo/releases/download/models-v1/';

/// Measured speed from earlier runs this session (seconds per input megapixel), by model.
final Map<UpModel, double> measuredSecPerMp = {};

/// Expected seconds for upscaling a w*h image with [m]. Scale does not matter: 2x and 3x run the 4x model too.
double estimateSeconds(UpModel m, int w, int h) => 1.5 + (measuredSecPerMp[m] ?? m.secPerMp) * w * h / 1e6;

/// "About 20 s" style text.
String estimateText(double s) => s < 60 ? 'About ${math.max(5, (s / 5).round() * 5)} s' : 'About ${(s / 60).toStringAsFixed(s < 600 ? 1 : 0)} min';

/// On-device execution order. NNAPI is left out on purpose: on many phones its driver kills the process
/// instead of returning an error, so an upscale used to close the app instantly. XNNPACK is the fast CPU path.
List<String> backendsFor(UpModel m) {
  assert(m.name.isNotEmpty);
  return const ['xnnpack', 'cpu'];
}

/// Starts of tiles of [tile] px along an image edge of [length], overlapping by [overlap] px.
/// The last tile is pulled back so the far edge is always covered. NativeUpscaler.origins uses the same rule.
List<int> tileOrigins(int length, int tile, int overlap) {
  if (tile < 1) throw ArgumentError.value(tile, 'tile');
  if (length <= tile) return [0];
  final step = math.max(1, tile - overlap);
  final out = <int>[];
  var p = 0;
  while (p + tile < length) {
    out.add(p);
    p += step;
  }
  final last = length - tile;
  if (out.isEmpty || out.last != last) out.add(last);
  return out;
}

/// PNG bytes stay as they are. "jpeg" re-encodes at [a.$3] quality (70 to 100) for a much smaller file.
Uint8List encodeSaved((Uint8List, String, int) a) {
  if (a.$2 != 'jpeg') return a.$1;
  final im = img.decodePng(a.$1);
  if (im == null) throw Exception('Could not prepare this photo for saving');
  return img.encodeJpg(im, quality: a.$3.clamp(70, 100));
}

/// Core rectangle of the input that one tile is responsible for.
class Tile {
  final int x, y, w, h;
  const Tile(this.x, this.y, this.w, this.h);
  @override
  String toString() => 'Tile($x,$y,$w,$h)';
}

/// Splits a w*h image into tiles of at most [size] px so a big image never has to fit through the model at once.
List<Tile> planTiles(int w, int h, int size) => [
      for (var y = 0; y < h; y += size)
        for (var x = 0; x < w; x += size) Tile(x, y, math.min(size, w - x), math.min(size, h - y))
    ];

/// Cuts tile [t] plus [pad] px of context on every side out of an RGB buffer as a 1x3xSxS float tensor
/// (S = size + 2*pad, always the same so the model sees one fixed shape). Pixels outside the image repeat the edge.
Float32List extractTile(Uint8List rgb, int w, int h, Tile t, int size, int pad) {
  final s = size + 2 * pad, plane = s * s;
  final out = Float32List(3 * plane);
  for (var yy = 0; yy < s; yy++) {
    final sy = (t.y - pad + yy).clamp(0, h - 1);
    for (var xx = 0; xx < s; xx++) {
      final sx = (t.x - pad + xx).clamp(0, w - 1);
      final i = (sy * w + sx) * 3, o = yy * s + xx;
      out[o] = rgb[i] / 255;
      out[plane + o] = rgb[i + 1] / 255;
      out[2 * plane + o] = rgb[i + 2] / 255;
    }
  }
  return out;
}

/// Copies the model output for tile [t] (a 1x3x(S*scale)x(S*scale) tensor) into the big RGB output, dropping the
/// padded context so neighbouring tiles meet without seams.
void pasteTile(Uint8List out, int outW, List<num> y, Tile t, int size, int pad, int scale) {
  final s = (size + 2 * pad) * scale, plane = s * s;
  final px = pad * scale;
  for (var yy = 0; yy < t.h * scale; yy++) {
    final row = ((t.y * scale + yy) * outW + t.x * scale) * 3;
    final src = (yy + px) * s + px;
    for (var xx = 0; xx < t.w * scale; xx++) {
      final o = row + xx * 3, i = src + xx;
      out[o] = (y[i] * 255 + .5).clamp(0, 255).toInt();
      out[o + 1] = (y[plane + i] * 255 + .5).clamp(0, 255).toInt();
      out[o + 2] = (y[2 * plane + i] * 255 + .5).clamp(0, 255).toInt();
    }
  }
}

/// Runs [model] (any function from a 1x3xSxS tensor to a 1x3x(4S)x(4S) tensor) over the whole image tile by tile.
Future<Uint8List> upscaleRgb(Uint8List rgb, int w, int h, Future<List<num>> Function(Float32List, int s) model,
    {int size = 128, int pad = 10, int scale = 4, void Function(int done, int total)? progress, bool Function()? cancelled}) async {
  final out = Uint8List(w * scale * h * scale * 3);
  final tiles = planTiles(w, h, size);
  for (var i = 0; i < tiles.length; i++) {
    if (cancelled?.call() ?? false) throw const UpscaleCancelled();
    final t = tiles[i];
    final y = await model(extractTile(rgb, w, h, t, size, pad), size + 2 * pad);
    pasteTile(out, w * scale, y, t, size, pad, scale);
    progress?.call(i + 1, tiles.length);
  }
  return out;
}

class UpscaleCancelled implements Exception {
  const UpscaleCancelled();
  @override
  String toString() => 'Cancelled';
}

class UpscaleResult {
  final Uint8List png;
  final int w, h, srcW, srcH;
  final bool shrunk; // input had to be made smaller first to keep memory sane
  UpscaleResult(this.png, this.w, this.h, this.srcW, this.srcH, this.shrunk);
}

/// Largest output we build, in pixels (about 72 MB of RGB). Bigger requests come out at the largest scale that fits,
/// but the model still sees every pixel of the original.
const maxOutPixels = 24000000;

/// Largest input we read, in pixels. Only giant photos get shrunk before the model.
const maxInPixels = 24000000;

/// Decoded RGB pixels. Only plain data, so it can cross isolates.
class DecodedImage {
  final Uint8List rgb;
  final int w, h, ow, oh;
  DecodedImage(this.rgb, this.w, this.h, this.ow, this.oh);
}

/// Isolate entry (top level, plain data in and out): encoded bytes -> RGB, shrunk if huge.
DecodedImage decodeForUpscale((Uint8List, bool) a) {
  // JPEG with cleanup on: constrained decode straight from the file's own DCT data (fewer blocks, colour that
  // follows edges). Anything else, or a JPEG it can't handle: the normal decoder, then the EXIF rotation.
  final r = a.$2 ? restoreJpeg(a.$1) : null;
  var im = r != null ? restoredImage(r) : img.decodeImage(a.$1);
  if (im == null) throw Exception('Could not read this image');
  final o = im.exif.imageIfd.orientation;
  if (r == null && o != null && o != 1) im = img.bakeOrientation(im);
  final ow = im.width, oh = im.height;
  const maxIn = maxInPixels;
  if (ow * oh > maxIn) {
    final f = math.sqrt(maxIn / (ow * oh));
    im = img.copyResize(im, width: (ow * f).floor(), height: (oh * f).floor(), interpolation: img.Interpolation.average);
  }
  im = im.convert(numChannels: 3, format: img.Format.uint8);
  return DecodedImage(Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb)), im.width, im.height, ow, oh);
}

/// Isolate entry (top level, plain data in and out): 4x RGB -> resized to the target -> PNG.
Uint8List finishUpscale((Uint8List, int, int, int, int) a) {
  var im = img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
  if (im.width != a.$4) im = img.copyResize(im, width: a.$4, height: a.$5, interpolation: img.Interpolation.cubic);
  return img.encodePng(im, level: 6);
}

class Upscaler {
  static final _ort = OnnxRuntime();
  static final Map<UpModel, OrtSession> _sessions = {};

  static Future<File> _file(UpModel m) async => File('${(await getApplicationSupportDirectory()).path}/models/${m.file}');

  static Future<bool> ready(UpModel m) async => m.bundled || await (await _file(m)).exists();

  /// Downloads an optional model from this app's own GitHub release (converted from the official weights).
  static Future<void> download(UpModel m, {void Function(double)? progress, bool Function()? cancelled}) async {
    final f = await _file(m);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.part');
    final c = http.Client();
    try {
      final r = await c.send(http.Request('GET', Uri.parse('$modelBase${m.file}')));
      if (r.statusCode != 200) throw Exception('Download failed (HTTP ${r.statusCode})');
      final total = r.contentLength ?? m.approxBytes;
      final sink = tmp.openWrite();
      var got = 0;
      try {
        await for (final chunk in r.stream) {
          if (cancelled?.call() ?? false) throw const UpscaleCancelled();
          sink.add(chunk);
          got += chunk.length;
          progress?.call(got / total);
        }
      } finally {
        await sink.close();
      }
      if (m.sha.isNotEmpty && sha256.convert(await tmp.readAsBytes()).toString() != m.sha) {
        throw Exception('Downloaded model looks broken, try again');
      }
      await tmp.rename(f.path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } finally {
      c.close();
    }
  }

  static Future<OrtSession> _session(UpModel m) async {
    final s = _sessions[m];
    if (s != null) return s;
    // CPU only. XNNPACK lives in the native :upscale process. Loading it here would put a SIGSEGV in the UI process.
    final opts = OrtSessionOptions(providers: [OrtProvider.CPU], intraOpNumThreads: math.min(4, Platform.numberOfProcessors));
    final ses = m.bundled
        ? await _ort.createSessionFromAsset('assets/models/${m.name}.onnx', options: opts)
        : await _ort.createSession((await _file(m)).path, options: opts);
    return _sessions[m] = ses;
  }

  static const _ch = MethodChannel('pixelfixo/upscale');
  static void Function(int, int, String)? _onProgress;
  static bool _hooked = false;

  /// Backend used by the last native run ("xnnpack" or "cpu"), for the result screen.
  static String? lastBackend;

  /// Path of the model on disk. The bundled one is copied out of the APK once, since native code needs a file.
  static Future<String> _modelPath(UpModel m) async {
    if (!m.bundled) return (await _file(m)).path;
    final f = File('${(await getApplicationSupportDirectory()).path}/models/${m.name}.onnx');
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      final data = await rootBundle.load('assets/models/${m.name}.onnx');
      await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    return f.path;
  }

  /// Runs the model over the whole RGB image in native code (XNNPACK, then CPU) in a separate process.
  static Future<Uint8List> _native(DecodedImage d, UpModel m, void Function(double)? progress, bool Function()? cancelled,
      {int? outW, int? outH, PostOptions? post, bool faces = false}) async {
    outW ??= d.w * 4;
    outH ??= d.h * 4;
    if (!_hooked) {
      _hooked = true;
      _ch.setMethodCallHandler((c) async {
        if (c.method == 'progress') {
          final a = c.arguments as Map;
          _onProgress?.call(a['done'] as int, a['total'] as int, a['backend'] as String);
        }
      });
    }
    final dir = (await getTemporaryDirectory()).path;
    final id = DateTime.now().microsecondsSinceEpoch;
    final inF = File('$dir/up_in_$id.rgb'), outF = File('$dir/up_out_$id.rgb');
    await inF.writeAsBytes(d.rgb);
    _onProgress = (a, b, be) => progress?.call(a / b);
    final watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (cancelled?.call() ?? false) _ch.invokeMethod('cancel');
    });
    final sw = Stopwatch()..start();
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('run', {
        'model': await _modelPath(m),
        'input': inF.path,
        'output': outF.path,
        'w': d.w,
        'h': d.h,
        'scale': 4,
        'tile': m.tile,
        'pad': 16,
        'backends': backendsFor(m),
        'outW': outW,
        'outH': outH,
        'post': post != null,
        'lowQuality': post?.lowQuality ?? false,
        // Ultra, and Recover faces on a photo model, soften inked skin edges. Drawings never take that pass.
        'texture': post?.texture ?? 0.0,
        'skin': m == UpModel.art ? 0 : (m == UpModel.ultra || faces ? 2 : 0),
      });
      lastBackend = r?['backend'] as String?;
      measuredSecPerMp[m] = sw.elapsedMilliseconds / 1000 / (d.w * d.h / 1e6);
      return await outF.readAsBytes();
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw const UpscaleCancelled();
      rethrow;
    } finally {
      watch.cancel();
      _onProgress = null;
      for (final f in [inF, outF]) {
        if (await f.exists()) await f.delete();
      }
    }
  }

  /// Upscales encoded image bytes by [scale] (2, 3 or 4) and returns a PNG.
  static Future<UpscaleResult> run(Uint8List bytes, int scale, UpModel m,
      {PostOptions post = const PostOptions(), bool faces = false, void Function(double)? progress, bool Function()? cancelled}) async {
    if (scale < 2 || scale > 4) throw ArgumentError.value(scale, 'scale');
    lastBackend = null;
    final opt = post.forSource(jpegQuality(bytes));
    final d = await compute(decodeForUpscale, (bytes, opt.cleanup));
    // The model always runs on the full resolution input. Only the output size is capped.
    final (outW, outH) = outputSize(d.w, d.h, scale);
    try {
      final out = await _native(d, m, progress, cancelled, outW: outW, outH: outH, post: opt, faces: faces);
      final png = await compute(finishNative, (out, outW, outH, sourceNoise(d.rgb, d.w, d.h), opt));
      return UpscaleResult(png, outW, outH, d.ow, d.oh, d.w != d.ow || outW < d.w * scale);
    } catch (e) {
      if (e is UpscaleCancelled) rethrow;
      // Not on Android (tests, desktop), or the native engine failed on this phone: the plugin path, slower, and
      // big photos get shrunk first since the whole 4x result is kept in memory here.
      if (e is! MissingPluginException && e is! PlatformException) rethrow;
      // Out of memory in native code: the plugin path would need even more, so stop here with a clear message.
      if (e is PlatformException && '${e.message}'.contains('OutOfMemory')) {
        throw Exception('Not enough memory for this photo at this size. Try 2x or a smaller photo.');
      }
    }
    try {
      final small = await compute(shrinkForFallback, d);
      final ses = await _session(m);
      final rgb4 = await upscaleRgb(small.rgb, small.w, small.h, (x, s) => _runPlugin(ses, x, s),
          size: 128, pad: 16, progress: (a, b) => progress?.call(a / b), cancelled: cancelled);
      return await finishPipeline(small, rgb4, scale, opt, m.name);
    } on UpscaleCancelled {
      rethrow;
    } catch (e) {
      throw Exception('Upscale failed on this phone ($e)');
    }
  }

  static Future<List<num>> _runPlugin(OrtSession ses, Float32List x, int s) async {
    final input = await OrtValue.fromList(x, [1, 3, s, s]);
    try {
      final out = await ses.run({'input': input});
      final v = out['output']!;
      final list = (await v.asFlattenedList()).cast<num>();
      await v.dispose();
      return list;
    } finally {
      await input.dispose();
    }
  }
}

/// Output size for a [scale]x upscale of w*h: the full scale when it fits under [maxOutPixels], else the largest
/// scale that does (the model still runs at 4x on the full input, each tile is then averaged down).
(int, int) outputSize(int w, int h, int scale) {
  final f = math.min(scale.toDouble(), math.sqrt(maxOutPixels / (w * h)));
  return (math.max(1, (w * f).floor()), math.max(1, (h * f).floor()));
}

/// Isolate entry: the Dart fallback keeps the whole 4x image in memory, so it shrinks big inputs like before.
DecodedImage shrinkForFallback(DecodedImage d) {
  final maxIn = maxOutPixels / 16;
  if (d.w * d.h <= maxIn) return d;
  final f = math.sqrt(maxIn / (d.w * d.h));
  final im = img.copyResize(img.Image.fromBytes(width: d.w, height: d.h, bytes: d.rgb.buffer, numChannels: 3, order: img.ChannelOrder.rgb),
      width: (d.w * f).floor(), height: (d.h * f).floor(), interpolation: img.Interpolation.average);
  return DecodedImage(Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb)), im.width, im.height, d.ow, d.oh);
}

/// Isolate entry: native output (already color anchored, textured and at final size) -> optional grain and color
/// boost -> PNG.
Uint8List finishNative((Uint8List, int, int, double, PostOptions) a) {
  final (rgb, w, h, noise, opt) = a;
  final o = touchUp(rgb, w, h, noise, opt);
  return img.encodePng(img.Image.fromBytes(width: w, height: h, bytes: o.buffer, numChannels: 3, order: img.ChannelOrder.rgb), level: 6);
}

/// Isolate entry (top level, plain data only): raw 4x RGB -> color, natural and grain fixes -> target size -> PNG.
Uint8List finishWithPost((Uint8List, int, int, Uint8List, int, int, PostOptions) a) {
  final (rgb4, w, h, src, tw, th, opt) = a;
  final fixed = postProcessBands(rgb4, w * 4, h * 4, src, w, h, 4, opt);
  if (opt.sharpen <= 0) return finishUpscale((fixed, w * 4, h * 4, tw, th));
  var im = img.Image.fromBytes(width: w * 4, height: h * 4, bytes: fixed.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
  if (im.width != tw) im = img.copyResize(im, width: tw, height: th, interpolation: img.Interpolation.cubic);
  final rgb = Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb));
  final sharp = touchUp(rgb, im.width, im.height, 0, PostOptions(sharpen: opt.sharpen));
  return img.encodePng(img.Image.fromBytes(width: im.width, height: im.height, bytes: sharp.buffer, numChannels: 3, order: img.ChannelOrder.rgb), level: 6);
}

Future<UpscaleResult> finishPipeline(DecodedImage d, Uint8List rgb4, int scale, PostOptions opt, String label) async {
  final tw = d.w * scale, th = d.h * scale;
  final png = await compute(finishWithPost, (rgb4, d.w, d.h, d.rgb, tw, th, opt));
  if (kDebugMode) debugPrint('upscale ${d.w}x${d.h} -> ${tw}x$th with $label');
  return UpscaleResult(png, tw, th, d.ow, d.oh, d.w != d.ow);
}

/// The whole upscale with a Dart side [model] (used by tests and the non Android fallback): decode in a background
/// isolate, run [model] tile by tile here, then fix up, resize and encode in a background isolate.
///
/// The background work goes through [compute] with top level functions and plain records only. An earlier version
/// used `Isolate.run(() => ...)` closures, which dragged the caller's progress callback (and with it the widget
/// tree) along and crashed with "object is unsendable".
Future<UpscaleResult> upscalePipeline(Uint8List bytes, int scale, Future<List<num>> Function(Float32List, int s) model,
    {int tile = 128, PostOptions post = const PostOptions(), void Function(double)? progress, bool Function()? cancelled, String label = ''}) async {
  if (scale < 2 || scale > 4) throw ArgumentError.value(scale, 'scale');
  final d = await compute(decodeForUpscale, (bytes, post.cleanup));
  final rgb4 = await upscaleRgb(d.rgb, d.w, d.h, model,
      size: tile, pad: 16, progress: (a, b) => progress?.call(a / b), cancelled: cancelled);
  return finishPipeline(d, rgb4, scale, post.forSource(jpegQuality(bytes)), label);
}
