// Live-Aufnahme der Touranimation im Browser – Schnittstelle zum Browser.
//
// Getrennt vom DriveTime-Studio-Export (lokaler Exportdienst, Bild für Bild):
// Hier nimmt der Browser selbst den freigegebenen Tab in Echtzeit auf
// (`getDisplayMedia` + `MediaRecorder`). Alle Browseraufrufe stecken hinter
// [TabCaptureApi], damit Ablauf und Oberfläche ohne echte Freigabe testbar
// sind. Web: tab_capture_web.dart, sonst: tab_capture_stub.dart.

import 'package:flutter/foundation.dart';

import 'tab_capture_platform.dart';

/// Was der Nutzer im Browserdialog freigegeben hat (laut Browser).
enum DisplaySurfaceKind {
  /// Ein Browser-Tab – der empfohlene Fall.
  browser,

  /// Ein ganzes Fenster.
  window,

  /// Der ganze Bildschirm.
  monitor,

  /// Browser meldet es nicht.
  unknown;

  static DisplaySurfaceKind parse(String? value) => switch (value) {
        'browser' => browser,
        'window' => window,
        'monitor' => monitor,
        _ => unknown,
      };
}

/// Der Nutzer hat die Freigabe abgelehnt oder den Dialog geschlossen.
class TabCaptureDeniedException implements Exception {
  const TabCaptureDeniedException([this.detail]);
  final String? detail;
  @override
  String toString() => 'TabCaptureDeniedException${detail == null ? '' : ': $detail'}';
}

/// Sonstiger Fehler der Freigabe oder Aufnahme. [name] ist der Fehlername
/// des Browsers (z. B. `InvalidStateError`), nur für die Diagnose.
class TabCaptureException implements Exception {
  const TabCaptureException(this.name, [this.detail]);
  final String name;
  final String? detail;
  @override
  String toString() => 'TabCaptureException($name)${detail == null ? '' : ': $detail'}';
}

/// Zugang zu Bildschirmfreigabe und Aufnahme des Browsers.
abstract class TabCaptureApi {
  /// `navigator.mediaDevices.getDisplayMedia` und `MediaRecorder` vorhanden.
  bool get apisAvailable;

  /// `MediaRecorder.isTypeSupported(mimeType)`.
  bool isTypeSupported(String mimeType);

  /// Fragt die Freigabe an – ohne Ton, ohne Kamera, ohne Mikrofon. Muss
  /// unmittelbar aus einer Nutzeraktion heraus aufgerufen werden (kein
  /// `await` davor). Wirft [TabCaptureDeniedException] bei Ablehnung,
  /// sonst [TabCaptureException].
  Future<TabCaptureStream> requestDisplay();

  /// Meldet, wenn die Seite verdeckt wird (Tab-Wechsel, minimiert).
  /// Liefert die Funktion zum Abmelden.
  VoidCallback watchPageHidden(VoidCallback onHidden);
}

/// Eine erteilte Freigabe (MediaStream).
abstract class TabCaptureStream {
  DisplaySurfaceKind get surface;

  /// Freigabe noch aktiv (Videospur „live“).
  bool get active;

  /// Aktuelle Bildgröße der Aufnahme (`1350x1832`) oder null. Ändert sie sich
  /// während einer H.264-MP4-Aufnahme, erzeugt Chrome nachweislich ein
  /// beschädigtes MP4 (WebM verkraftet es).
  String? get frameSize;

  /// Der Browser hat die Freigabe beendet (z. B. „Freigabe beenden“).
  set onEnded(VoidCallback? callback);

  /// Recorder auf dieser Freigabe; [mimeType] muss unterstützt sein.
  TabRecorder createRecorder(String mimeType);

  /// Alle Spuren stoppen, Listener entfernen. Mehrfach aufrufbar.
  void stop();
}

/// Ein MediaRecorder.
abstract class TabRecorder {
  /// Tatsächlich verwendeter Typ (nach [start] laut Browser).
  String get mimeType;

  set onError(void Function(Object error)? callback);

  void start();

  /// Beendet die Aufnahme und setzt die Datei zusammen. null, wenn keine
  /// verwertbaren Videodaten entstanden sind (leer oder unvollständig).
  Future<RecordedVideo?> stop();

  /// Verwerfen: anhalten, gesammelte Daten freigeben, keine Datei.
  void abort();
}

/// Videocodec, wie er tatsächlich in der Datei steht.
enum VideoCodec {
  h264('H.264'),
  vp9('VP9'),
  vp8('VP8'),
  av1('AV1'),
  unknown('unbekannt');

  const VideoCodec(this.label);
  final String label;
}

/// Fertige Aufnahme im Arbeitsspeicher des Browsers (Blob).
abstract class RecordedVideo {
  String get mimeType;
  int get sizeBytes;

  /// Aus dem Dateianfang gelesener Codec (nicht nur die Browserangabe).
  VideoCodec get codec;

  /// Bietet die Datei zum Download an (Object-URL wird danach freigegeben).
  bool download(String fileName);

  /// Blob und noch offene Object-URLs freigeben.
  void release();
}

/// Nur für Tests: ersetzt die Browseranbindung.
@visibleForTesting
TabCaptureApi? debugTabCaptureApiOverride;

/// Browseranbindung der aktuellen Plattform (ohne Web: nicht unterstützt).
TabCaptureApi tabCaptureApi() => debugTabCaptureApiOverride ?? createPlatformTabCaptureApi();

/// Kandidaten in Reihenfolge der Vorliebe. Es wird nur verwendet, was der
/// Browser per `isTypeSupported` bestätigt.
///
/// Zuerst MP4 mit H.264 – das spielen iPhone, Android, QuickTime und
/// TikTok ohne Umwandlung. WebM nur als Rückfall. Allgemeines `video/mp4`
/// ohne Codecangabe zuletzt: Der Codec ist dann nicht festgelegt.
const List<String> kRecordingMimeCandidates = [
  'video/mp4;codecs=avc1',
  'video/mp4;codecs=avc1.640028', // H.264 High
  'video/mp4;codecs=avc1.4d401f', // H.264 Main
  'video/mp4;codecs=avc1.42e01e', // H.264 Baseline
  'video/mp4;codecs=avc3',
  'video/webm;codecs=vp9',
  'video/webm;codecs=vp8',
  'video/webm',
  'video/mp4',
];

/// MIME-Typ verlangt ausdrücklich H.264 in MP4.
bool isH264Mp4Mime(String mimeType) {
  final m = mimeType.toLowerCase();
  return extensionForMimeType(m) == 'mp4' && RegExp(r'codecs\s*=\s*"?(avc1|avc3|h264)').hasMatch(m);
}

/// WebM-Ausgabe (auf iPhone/QuickTime und für TikTok nicht direkt nutzbar).
bool isWebmMime(String mimeType) => extensionForMimeType(mimeType) == 'webm';

/// Erster vom Browser unterstützter Typ oder null.
String? pickRecordingMimeType(bool Function(String mimeType) isSupported) {
  for (final m in kRecordingMimeCandidates) {
    try {
      if (isSupported(m)) return m;
    } catch (_) {
      // Browser wirft bei unbekannten Typen gelegentlich – dann nicht nutzen.
    }
  }
  return null;
}

/// Dateiendung zum tatsächlich erzeugten Typ; null bei unbekanntem Format.
String? extensionForMimeType(String mimeType) {
  final base = mimeType.split(';').first.trim().toLowerCase();
  return switch (base) {
    'video/webm' => 'webm',
    'video/mp4' => 'mp4',
    'video/x-matroska' => 'mkv',
    _ => null,
  };
}

/// Prüft den Dateianfang: WebM/Matroska (EBML-Kopf) oder MP4 (erste Box
/// `ftyp`). So wird keine leere, beschädigte oder falsch benannte Datei
/// angeboten – ein WebM mit MP4-Typ fällt hier durch.
bool looksLikeRecordedVideo(Uint8List head, String mimeType) {
  switch (extensionForMimeType(mimeType)) {
    case 'webm':
    case 'mkv':
      return head.length >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3;
    case 'mp4':
      if (head.length < 12) return false;
      final size = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
      return String.fromCharCodes(head.sublist(4, 8)) == 'ftyp' && size >= 12;
    default:
      return false;
  }
}

/// Videocodec aus dem Dateianfang: MP4 – Probenbeschreibung in `moov`
/// (`avcC`/`avc1`, `vpcC`, `av1C`); WebM – CodecID der Spur (`V_VP9` …).
/// [head] sollte die ersten ~64 KB enthalten.
VideoCodec detectVideoCodec(Uint8List head, String mimeType) {
  final text = String.fromCharCodes(head);
  switch (extensionForMimeType(mimeType)) {
    case 'mp4':
      if (text.contains('avcC') || text.contains('avc1') || text.contains('avc3')) return VideoCodec.h264;
      if (text.contains('vpcC') || text.contains('vp09')) return VideoCodec.vp9;
      if (text.contains('av1C') || text.contains('av01')) return VideoCodec.av1;
      return VideoCodec.unknown;
    case 'webm':
    case 'mkv':
      if (text.contains('V_VP9')) return VideoCodec.vp9;
      if (text.contains('V_VP8')) return VideoCodec.vp8;
      if (text.contains('V_AV1')) return VideoCodec.av1;
      if (text.contains('V_MPEG4/ISO/AVC')) return VideoCodec.h264;
      return VideoCodec.unknown;
    default:
      return VideoCodec.unknown;
  }
}

/// Teil eines Dateinamens: klein, ohne Umlaute und Sonderzeichen.
String sanitizeFileNamePart(String? text, {int maxLength = 40}) {
  var s = (text ?? '').trim().toLowerCase();
  const map = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss', 'é': 'e', 'è': 'e', 'á': 'a', 'à': 'a', 'ó': 'o', 'ø': 'oe', 'å': 'aa', 'æ': 'ae', 'ç': 'c', 'ş': 's', 'ı': 'i', 'ğ': 'g', 'č': 'c', 'š': 's', 'ž': 'z', 'ł': 'l'};
  map.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > maxLength) s = s.substring(0, maxLength).replaceAll(RegExp(r'-+$'), '');
  return s;
}

/// `drivetime_start-ziel_YYYY-MM-DD_HH-mm.<ext>` (Ortszeit).
String recordingFileName({String? from, String? to, required DateTime at, required String extension}) {
  final a = sanitizeFileNamePart(from), b = sanitizeFileNamePart(to);
  final route = a.isEmpty || b.isEmpty ? (a.isEmpty ? (b.isEmpty ? 'tour' : b) : a) : '$a-$b';
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${at.year}-${two(at.month)}-${two(at.day)}_${two(at.hour)}-${two(at.minute)}';
  return 'drivetime_${route}_$stamp.$extension';
}
