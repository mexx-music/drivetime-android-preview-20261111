// „Tour live aufnehmen“ – kleine Karte nach einer berechneten Tour.
//
// Getrennt vom Studio-Export ([VideoExportPanel]): kein Exportdienst, keine
// Filmspezifikation nach außen. Der Browser nimmt den freigegebenen Tab in
// Echtzeit auf, während die normale Touranimation läuft.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'live_recording_controller.dart';
import 'tab_capture.dart';

/// Was die Touranimation für eine Live-Aufnahme braucht: Start-/Ende-Signal
/// und den Schließwunsch. Die Animation läuft dabei im sauberen
/// Aufnahmemodus – ohne jedes Bedienelement, auch ohne Aufnahmeanzeige.
class LiveRecordingHooks {
  const LiveRecordingHooks({
    required this.onPlaybackStarted,
    required this.onPlaybackFinished,
    required this.closeRequest,
  });
  final VoidCallback onPlaybackStarted;
  final VoidCallback onPlaybackFinished;

  /// true: Aufnahme ist vorbei – die Animation schließt sich selbst.
  final ValueListenable<bool> closeRequest;
}

/// So heißt der Tab im Freigabedialog des Browsers (`<title>` in
/// web/index.html bzw. `MaterialApp.title`).
const String kAppTabTitle = 'DriverRoute ETA';

/// Browser speichert nur WebM (vor dem Start angezeigt).
const String kWebmOnlyHintText =
    'Dieser Browser kann die Aufnahme nur als WebM speichern. Für ein direkt auf iPhone, Android und TikTok '
    'verwendbares MP4 bitte Chrome, Edge oder Safari in einer unterstützten Version verwenden.';

/// Hochformat-Hinweis (vor dem Start angezeigt).
const String kPortraitHintText =
    'Für TikTok und Reels das Browserfenster möglichst im Hochformat verwenden. Empfohlen ist 9:16.';

/// Text für Geräte ohne Live-Aufnahme.
const String kLiveRecordingUnsupportedText =
    'Live-Aufnahme ist auf diesem Gerät nicht verfügbar. Bitte einen Desktop-Browser wie Chrome, Edge oder Firefox verwenden.';

class LiveRecordingPanel extends StatefulWidget {
  const LiveRecordingPanel({
    super.key,
    required this.available,
    required this.openAnimation,
    this.fromName,
    this.toName,
    this.api,
    this.postRoll = const Duration(seconds: 1),
  });

  /// Die Berechnung enthält eine Streckenführung (sonst nichts aufzunehmen).
  final bool available;

  /// Öffnet die bestehende Touranimation mit [LiveRecordingHooks] und endet,
  /// wenn sie wieder geschlossen ist.
  final Future<void> Function(LiveRecordingHooks hooks) openAnimation;

  /// Kurzname von Start und Ziel für den Dateinamen.
  final String? fromName;
  final String? toName;

  /// Browseranbindung (Tests); Standard: aktuelle Plattform.
  final TabCaptureApi? api;
  final Duration postRoll;

  @override
  State<LiveRecordingPanel> createState() => _LiveRecordingPanelState();
}

class _LiveRecordingPanelState extends State<LiveRecordingPanel> {
  late final LiveRecordingController _c =
      LiveRecordingController(api: widget.api, postRoll: widget.postRoll)..addListener(_changed);

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  String _fileName() => recordingFileName(
        from: widget.fromName,
        to: widget.toName,
        at: _c.startedAt ?? DateTime.now(),
        extension: _c.videoExtension ?? 'webm',
      );

  /// Hinweis vor dem Start. „Freigabe auswählen“ startet direkt aus dem
  /// Klick heraus – Voraussetzung für die Browserfreigabe.
  void _showHint() {
    if (_c.status.busy) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Tour live aufnehmen'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FormatHint(controller: _c),
              const SizedBox(height: 8),
              const _Bullet(kPortraitHintText, key: Key('live-recording-portrait-hint')),
              const _Bullet('Im folgenden Browserdialog den Tab dieser Seite („$kAppTabTitle“) auswählen.'),
              const _Bullet('Wenn angeboten, „Diesen Tab freigeben“ bzw. „Aktuellen Tab“ verwenden.'),
              const _Bullet('Während der Aufnahme den Tab geöffnet und sichtbar lassen und die Fenstergröße nicht verändern.'),
              const _Bullet('Die Aufnahme läuft in Echtzeit und endet automatisch mit dem Filmende.'),
              const _Bullet('Während der Aufnahme sind keine Bedienelemente zu sehen – das Video zeigt nur den Tourfilm.'),
              const _Bullet('Vorzeitig beenden: in der Freigabeleiste des Browsers „Freigabe beenden“ wählen. '
                  'Das bis dahin aufgenommene Video bleibt erhalten.'),
              const _Bullet('Abbrechen: im Browser „Zurück“. Die Aufnahme wird dann verworfen.'),
              const _Bullet('Für beste Qualität währenddessen keine anderen Bedienelemente öffnen.'),
              const _Bullet('Es wird kein Ton aufgenommen; Kamera und Mikrofon werden nicht verwendet.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Abbrechen')),
          FilledButton.icon(
            key: const Key('live-recording-confirm'),
            icon: const Icon(Icons.screen_share_outlined),
            label: const Text('Freigabe auswählen'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _begin(); // synchron im Klick – kein await davor
            },
          ),
        ],
      ),
    );
  }

  void _begin() {
    _c.start(
      openAnimation: (signals) => widget.openAnimation(LiveRecordingHooks(
        onPlaybackStarted: signals.started,
        onPlaybackFinished: signals.finished,
        closeRequest: signals.closeRequest,
      )),
      confirmSurface: _confirmSurface,
    );
  }

  Future<bool> _confirmSurface(DisplaySurfaceKind surface) async {
    if (!mounted) return false;
    final what = surface == DisplaySurfaceKind.monitor ? 'der ganze Bildschirm' : 'ein ganzes Fenster';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nicht der Tab dieser Seite?'),
        content: Text('Freigegeben ist $what. Aufgenommen wird dann alles, was dort sichtbar ist – '
            'auch andere Programme und der Mauszeiger.\n\n'
            'Für ein sauberes Video abbrechen und im Browserdialog den Tab „$kAppTabTitle“ wählen.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Trotzdem aufnehmen')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _download() {
    if (!_c.download(_fileName()) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Der Download konnte nicht gestartet werden. Bitte erneut versuchen.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _c.status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.fiber_manual_record_outlined),
              const SizedBox(width: 8),
              Text('Tour live aufnehmen', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (!_c.supported)
              const Text(kLiveRecordingUnsupportedText, key: Key('live-recording-unsupported'))
            else if (!widget.available)
              const Text('Für diese Berechnung liegt keine Streckenführung vor – es gibt nichts aufzunehmen.')
            else ...[
              const Text('Nimmt die Touranimation in Echtzeit im Browser auf und bietet sie danach als Videodatei an.'),
              if (_c.plannedWebmOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(kWebmOnlyHintText,
                      key: const Key('live-recording-webm-hint'), style: TextStyle(color: theme.colorScheme.tertiary)),
                ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const Key('live-recording-start'),
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Tour live aufnehmen'),
                onPressed: s.busy ? null : _showHint,
              ),
              if (s != LiveRecordingStatus.ready) ...[
                const SizedBox(height: 10),
                _StatusBlock(controller: _c, onDownload: _download, fileName: _fileName),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('•  '),
          Expanded(child: Text(text)),
        ]),
      );
}

/// Vor dem Start: in welchem Format dieser Browser speichert.
class _FormatHint extends StatelessWidget {
  const _FormatHint({required this.controller});
  final LiveRecordingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final String text;
    if (c.plannedH264Mp4) {
      text = 'Dieser Browser speichert die Aufnahme als MP4 (H.264).';
    } else if (c.plannedWebmOnly) {
      text = kWebmOnlyHintText;
    } else {
      text = 'Dieser Browser speichert die Aufnahme als MP4. Das genaue Videoformat steht erst nach der Aufnahme fest.';
    }
    return Text(text,
        key: const Key('live-recording-format-hint'),
        style: TextStyle(fontWeight: FontWeight.w600, color: c.plannedWebmOnly ? Theme.of(context).colorScheme.error : null));
  }
}

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1).replaceAll('.', ',')} MB';

String _formatLabel(LiveRecordingController c) {
  final container = switch (c.videoExtension) {
    'webm' => 'WebM',
    'mp4' => 'MP4',
    'mkv' => 'MKV',
    _ => 'Video',
  };
  final codec = c.videoCodec;
  return codec == null || codec == VideoCodec.unknown ? container : '$container (${codec.label})';
}

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

const String _hiddenWarning =
    'Hinweis: Der Tab war während der Aufnahme zeitweise verdeckt. Das Video kann an diesen Stellen ruckeln oder springen.';

/// Status in der Karte auf der Ergebnisseite.
class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.controller, required this.onDownload, required this.fileName});
  final LiveRecordingController controller;
  final VoidCallback onDownload;
  final String Function() fileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final error = c.status == LiveRecordingStatus.failed;
    final text = switch (c.status) {
      LiveRecordingStatus.requesting => 'Warte auf die Freigabe im Browser …',
      LiveRecordingStatus.recording => 'Aufnahme läuft …',
      LiveRecordingStatus.finalizing => 'Video wird fertiggestellt …',
      LiveRecordingStatus.fileReady =>
        '${c.userMessage ?? 'Video bereit.'} ${_formatLabel(c)} · ${_mb(c.videoBytes ?? 0)} · ${_clock(c.recordedDuration)}',
      _ => c.userMessage ?? '',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (c.status.busy) const LinearProgressIndicator(),
      Text(text,
          key: const Key('live-recording-status'),
          style: error ? TextStyle(color: theme.colorScheme.error) : null),
      if (c.status == LiveRecordingStatus.fileReady) ...[
        if (c.wasHidden) const Padding(padding: EdgeInsets.only(top: 4), child: Text(_hiddenWarning)),
        if (c.frameSizeChanged && c.videoExtension == 'mp4')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                'Die Größe des Browserfensters hat sich während der Aufnahme geändert. Das MP4 kann dadurch '
                'fehlerhaft sein – bitte die Datei prüfen und bei Bedarf ohne Größenänderung erneut aufnehmen.',
                key: const Key('live-recording-size-warning'),
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (!c.videoIsH264Mp4)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                c.videoExtension == 'mp4'
                    ? 'Die Datei ist ein MP4, enthält aber kein H.264. Ob iPhone, Android und TikTok sie direkt '
                        'verwenden können, ist nicht sicher.'
                    : 'Diese Datei ist kein MP4. iPhone, QuickTime und TikTok verwenden WebM in der Regel nicht direkt – '
                        'vorher umwandeln oder in Chrome, Edge oder Safari aufnehmen. Abspielbar z. B. in Chrome, Firefox oder VLC.',
                key: const Key('live-recording-compat-note'),
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('live-recording-download'),
            icon: const Icon(Icons.download),
            label: const Text('Video herunterladen'),
            onPressed: onDownload,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(fileName(), style: theme.textTheme.bodySmall),
        ),
      ],
      if (kDebugMode && c.debugDetail != null)
        Text('Diagnose: ${c.debugDetail}', style: theme.textTheme.bodySmall),
    ]);
  }
}
