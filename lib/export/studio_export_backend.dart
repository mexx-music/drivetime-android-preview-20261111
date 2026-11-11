// DriveTime Studio – Anbindung an den lokalen Exportdienst
// (tool/studio_export/server.mjs). Derselbe HTTP-Vertrag kann später von einem
// serverseitigen Exportjob erfüllt werden; dann ändert sich nur [baseUrl].

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'film_spec.dart';
import 'video_export_job.dart';
import 'video_export_preset.dart';

/// Adresse des Exportdienstes. Standard: dieselbe Herkunft wie die App (der
/// lokale Dienst liefert den Studio-Build selbst aus).
const String kStudioExportUrl = String.fromEnvironment('DRIVETIME_STUDIO_URL');

class StudioExportBackend implements VideoExportBackend {
  StudioExportBackend({Uri? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? (kStudioExportUrl.isNotEmpty ? Uri.parse(kStudioExportUrl) : Uri.base.resolve('/')),
        _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  Uri _u(String path) => baseUrl.resolve(path);

  Map<String, dynamic> _json(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw VideoExportException('Unerwartete Antwort des Exportdienstes.', 'HTTP ${r.statusCode}: ${r.body}');
    }
  }

  @override
  Future<bool> available() async {
    try {
      final r = await _client.get(_u('/api/health')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200 && _json(r)['service'] == 'drivetime-studio-export';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<VideoExportPreset, bool>> entitlements(String filmId) async {
    final r = await _client.get(_u('/api/entitlements?film=$filmId'));
    if (r.statusCode != 200) return const {};
    final j = _json(r);
    return {for (final p in VideoExportPreset.values) p: j[p.name] == true};
  }

  @override
  Future<String> start(TourFilmSpec spec, VideoExportPreset preset) async {
    final r = await _client.post(_u('/api/export'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'preset': preset.name, 'spec': spec.toJson()}));
    final j = _json(r);
    if (r.statusCode == 202) return j['jobId'] as String;
    throw VideoExportException(
      switch (r.statusCode) {
        403 => 'Dieses Exportprofil ist für diesen Film nicht freigeschaltet.',
        409 => 'Es läuft bereits ein Export. Bitte warten, bis er fertig ist.',
        400 => 'Die Tourdaten konnten nicht übernommen werden.',
        _ => 'Der Export konnte nicht gestartet werden.',
      },
      '${r.statusCode}: ${j['error'] ?? r.body}',
    );
  }

  @override
  Future<VideoExportProgress> status(String jobId) async {
    final r = await _client.get(_u('/api/export/$jobId'));
    if (r.statusCode == 404) {
      return const VideoExportProgress(status: VideoExportStatus.failed, error: 'Der Exportauftrag ist nicht mehr vorhanden.');
    }
    final j = _json(r);
    return VideoExportProgress(
      status: VideoExportStatus.values.byName(j['status'] as String),
      framesDone: (j['framesDone'] as num?)?.toInt() ?? 0,
      framesTotal: (j['framesTotal'] as num?)?.toInt() ?? 0,
      bytes: (j['bytes'] as num?)?.toInt(),
      error: j['error'] as String?,
      detail: j['detail'] as String?,
    );
  }

  @override
  Future<void> cancel(String jobId) async {
    await _client.post(_u('/api/export/$jobId/cancel'));
  }

  @override
  Uri download(String jobId) => _u('/api/export/$jobId/video');
}
