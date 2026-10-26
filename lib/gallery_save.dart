import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'engine/upscale.dart';

const galleryChannel = MethodChannel('pixelfixo/media');

/// Timestamp file name like 20261026_004512.png. Nothing else about the photo goes into the name.
String saveName(DateTime t, {String ext = 'png'}) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}.$ext';
}

Future<Uint8List> _bytes(Uint8List png, bool jpeg, int quality) async =>
    jpeg ? compute(encodeSaved, (png, 'jpeg', quality)) : png;

/// Writes a clean file into Pictures/Pixelfixo. JPEG is smaller; PNG is lossless.
Future<void> saveToGallery(Uint8List png, {bool jpeg = false, int quality = 92}) async {
  final bytes = await _bytes(png, jpeg, quality);
  final ext = jpeg ? 'jpg' : 'png';
  final f = File('${(await getTemporaryDirectory()).path}/out_${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes);
  try {
    await galleryChannel.invokeMethod('save', {'path': f.path, 'name': saveName(DateTime.now(), ext: ext), 'mime': jpeg ? 'image/jpeg' : 'image/png'});
  } finally {
    if (await f.exists()) await f.delete();
  }
}

/// Writes a temp file and opens the system share sheet. The caller deletes [previous] first.
Future<File> sharePhoto(Uint8List png, {bool jpeg = false, int quality = 92, File? previous}) async {
  if (previous != null && await previous.exists()) await previous.delete();
  final bytes = await _bytes(png, jpeg, quality);
  final ext = jpeg ? 'jpg' : 'png';
  final f = File('${(await getTemporaryDirectory()).path}/share_${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes);
  try {
    await galleryChannel.invokeMethod('share', {'path': f.path, 'mime': jpeg ? 'image/jpeg' : 'image/png'});
  } catch (_) {
    if (await f.exists()) await f.delete();
    rethrow;
  }
  return f;
}
