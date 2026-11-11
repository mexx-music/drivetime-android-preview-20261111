import 'dart:typed_data';

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<bool> downloadBytes(
  Uint8List bytes, {
  required String filename,
  required String mimeType,
}) async {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = filename
      ..click();
    return true;
  } finally {
    await Future<void>.delayed(Duration.zero);
    html.Url.revokeObjectUrl(url);
  }
}
