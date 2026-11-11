import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<bool> copyPngToClipboard(Uint8List bytes) async {
  try {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'image/png'),
    );
    final item = web.ClipboardItem(
      <String, JSAny?>{'image/png': blob}.jsify()! as JSObject,
    );
    await web.window.navigator.clipboard.write([item].toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
