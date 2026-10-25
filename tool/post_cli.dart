// Runs the same color anchoring and Natural look as the app on a raw 4x model output. Used to make README images.
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:pixelfixo/engine/upscale_post.dart';

void main(List<String> a) {
  final s = img.decodeImage(File(a[0]).readAsBytesSync())!.convert(numChannels: 3);
  final o = img.decodePng(File(a[1]).readAsBytesSync())!.convert(numChannels: 3);
  final r = postProcessBands(o.getBytes(order: img.ChannelOrder.rgb), o.width, o.height, s.getBytes(order: img.ChannelOrder.rgb), s.width, s.height, 4,
      const PostOptions());
  File(a[2]).writeAsBytesSync(img.encodePng(img.Image.fromBytes(width: o.width, height: o.height, bytes: r.buffer, numChannels: 3)));
}
