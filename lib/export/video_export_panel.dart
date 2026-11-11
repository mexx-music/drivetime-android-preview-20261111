// DriveTime Studio – Exportbereich nach einer berechneten Tour.
//
// Kostenlos: „Kontrollvideo erstellen“ (kleine Vorschauqualität).
// Full HD: sichtbar vorbereitet, aber standardmäßig gesperrt
// ([VideoExportEntitlements]); keine Zahlung, keine simulierte Kasse.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/open_in_tab.dart';
import 'film_spec.dart';
import 'video_export_entitlement.dart';
import 'video_export_job.dart';
import 'video_export_preset.dart';

class VideoExportPanel extends StatefulWidget {
  const VideoExportPanel({
    super.key,
    required this.spec,
    required this.backend,
    this.appEntitlements = const DefaultVideoExportEntitlements(),
    this.pollInterval = const Duration(seconds: 1),
    this.openFile,
  });

  /// Liefert die Filmspezifikation der aktuellen Berechnung (null = keine Streckenführung).
  final TourFilmSpec? Function() spec;
  final VideoExportBackend backend;
  final VideoExportEntitlements appEntitlements;
  final Duration pollInterval;

  /// Öffnet bzw. lädt die fertige Datei (Standard: neuer Browser-Tab).
  final void Function(Uri url)? openFile;

  @override
  State<VideoExportPanel> createState() => _VideoExportPanelState();
}

class _VideoExportPanelState extends State<VideoExportPanel> {
  late VideoExportController _controller;
  FilmFormat _format = FilmFormat.landscape16x9;
  Map<VideoExportPreset, bool> _service = const {};
  bool? _available;
  String? _serviceFilmId;

  @override
  void initState() {
    super.initState();
    _controller = VideoExportController(
      backend: widget.backend,
      entitlements: const DefaultVideoExportEntitlements(),
      pollInterval: widget.pollInterval,
    )..addListener(_changed);
    _checkService();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  TourFilmSpec? _spec() => widget.spec()?.copyWith(format: _format);

  Future<void> _checkService() async {
    final ok = await widget.backend.available();
    final spec = _spec();
    final ent = ok && spec != null ? await widget.backend.entitlements(spec.filmId) : const <VideoExportPreset, bool>{};
    if (!mounted) return;
    setState(() {
      _available = ok;
      _service = ent;
      _serviceFilmId = spec?.filmId;
    });
  }

  VideoExportEntitlements get _entitlements => CombinedVideoExportEntitlements(widget.appEntitlements, _service);

  Future<void> _run(VideoExportPreset preset) async {
    final spec = _spec();
    if (spec == null || _controller.state.status.running) return;
    if (spec.filmId != _serviceFilmId) await _checkService();
    // Berechtigung je Start aus App-Regel UND Dienst.
    _controller.removeListener(_changed);
    _controller.dispose();
    _controller = VideoExportController(
      backend: widget.backend,
      entitlements: _entitlements,
      pollInterval: widget.pollInterval,
    )..addListener(_changed);
    setState(() {});
    await _controller.start(spec, preset);
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  String _statusText(VideoExportJobState s) => switch (s.status) {
        VideoExportStatus.preparing => 'Film wird vorbereitet …',
        VideoExportStatus.rendering => s.framesTotal > 0 ? 'Film wird aufgenommen … ${s.framesDone} / ${s.framesTotal} Bilder' : 'Film wird aufgenommen …',
        VideoExportStatus.encoding => 'Video wird kodiert …',
        VideoExportStatus.ready =>
          'Fertig${s.bytes == null ? '' : ' · ${(s.bytes! / 1e6).toStringAsFixed(1)} MB'}',
        VideoExportStatus.failed => s.userMessage ?? 'Der Export ist fehlgeschlagen.',
        VideoExportStatus.cancelled => s.userMessage ?? 'Export abgebrochen.',
        VideoExportStatus.idle => '',
      };

  @override
  Widget build(BuildContext context) {
    final s = _controller.state;
    final spec = widget.spec();
    final running = s.status.running;
    final theme = Theme.of(context);
    final fullHdAllowed = spec != null && _entitlements.allows(VideoExportPreset.fullHD, spec.filmId);
    final open = widget.openFile ?? (Uri u) => openInNewTab(u.toString());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.movie_creation_outlined),
              const SizedBox(width: 8),
              Text('Tourfilm exportieren', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            if (spec == null)
              const Text('Für diese Berechnung liegt keine Streckenführung vor – es gibt keinen Film zu exportieren.')
            else if (_available == false)
              const Text('Der Videoexport ist derzeit nur mit dem lokalen DriveTime-Studio-Exportdienst verfügbar.')
            else ...[
              SegmentedButton<FilmFormat>(
                segments: [for (final f in FilmFormat.values) ButtonSegment(value: f, label: Text(f.label))],
                selected: {_format},
                onSelectionChanged: running ? null : (v) => setState(() => _format = v.first),
              ),
              const SizedBox(height: 10),
              // Kostenlos
              FilledButton.icon(
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Kontrollvideo erstellen'),
                onPressed: running || _available != true ? null : () => _run(VideoExportPreset.controlPreview),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 10),
                child: Text('Kleine Vorschauqualität zur Kontrolle von Route, Szenen und Übergängen.'),
              ),
              // Full HD (vorbereitet, standardmäßig gesperrt)
              OutlinedButton.icon(
                icon: Icon(fullHdAllowed ? Icons.hd_outlined : Icons.lock_outline),
                label: const Text('Full HD erstellen'),
                onPressed: running || !fullHdAllowed ? null : () => _run(VideoExportPreset.fullHD),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(fullHdAllowed
                    ? '1080p · 30 fps · volle Qualität'
                    : '1080p · 30 fps · volle Qualität – noch nicht freigeschaltet'),
              ),
            ],
            if (s.status != VideoExportStatus.idle) ...[
              const SizedBox(height: 12),
              if (running) LinearProgressIndicator(value: s.progress),
              const SizedBox(height: 6),
              Text(_statusText(s),
                  style: s.status == VideoExportStatus.failed ? TextStyle(color: theme.colorScheme.error) : null),
              if (kDebugMode && s.debugDetail != null)
                Text(s.debugDetail!, style: theme.textTheme.bodySmall),
              Wrap(spacing: 8, children: [
                if (_controller.canCancel)
                  TextButton(onPressed: _controller.cancel, child: const Text('Abbrechen')),
                if (s.status == VideoExportStatus.ready && s.downloadUrl != null)
                  TextButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Video öffnen / herunterladen'),
                    onPressed: () => open(s.downloadUrl!),
                  ),
                if (s.status == VideoExportStatus.failed || s.status == VideoExportStatus.cancelled)
                  TextButton(
                    onPressed: s.preset == null ? null : () => _run(s.preset!),
                    child: const Text('Erneut versuchen'),
                  ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
