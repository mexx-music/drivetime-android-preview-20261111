// Web implementation using dart:html
// This file is only imported on web via conditional import.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void openInNewTab(String url) {
  try {
    html.window.open(url, '_blank');
  } catch (e) {
    // ignore
  }
}

void openInNewTabWithName(String url, String name) {
  try {
    final u = (url == null || url.isEmpty) ? 'about:blank' : url;
    html.window.open(u, name);
  } catch (e) {
    // ignore
  }
}
