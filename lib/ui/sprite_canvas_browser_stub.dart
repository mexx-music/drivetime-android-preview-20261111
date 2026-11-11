import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'sprite_canvas.dart';

/// Ohne Browser: nicht verfügbar – der Aufrufer zeichnet mit Flutter.
({int width, int height, Uint8List rgba})? renderSpriteBrowser(Size size, void Function(SpriteCanvas c) paint) => null;
