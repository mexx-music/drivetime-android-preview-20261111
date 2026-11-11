// DriveTime Studio – Filmspezifikation einer Tour.
//
// Hält genau die Daten, aus denen die App den Tourfilm erzeugt: den Kartenplan
// der letzten Berechnung (Linien, Fährabschnitte, Stopps), die ETA-Zeitleiste,
// Namen, Format und Lkw-Lackierung. Der Export rendert ausschließlich daraus –
// es gibt keine Routen-, Geocoding- oder Autocomplete-Anfrage mehr.
//
// [filmId] ist die stabile Kennung dieser Filmversion: Sie ändert sich, sobald
// sich ein filmrelevanter Inhalt ändert (Route, Start/Ziel, Stopps, Fähre,
// Zeitleiste/Länderfolge, Format, Lkw, Filmgestaltung), und bleibt sonst gleich.
// Das Exportprofil gehört bewusst NICHT dazu: Kontrollvideo und Full HD sind
// derselbe Film.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:latlong2/latlong.dart';

import '../logic/eta_calculator.dart';
import '../services/map_launcher.dart';
import '../ui/map_osm_view.dart' show MapSegment;
import 'video_export_preset.dart';

/// Version der Filmgestaltung (Kamera-Regie, Intro/Outro, HUD). Bei einer
/// sichtbaren Änderung der Gestaltung erhöhen – dann gilt jeder Film als neu.
const String kFilmDesignVersion = 'cinematic-2.5d-2026-10';

class TourFilmSpec {
  const TourFilmSpec({
    required this.plan,
    required this.eta,
    required this.title,
    this.fromName,
    this.toName,
    this.format = FilmFormat.landscape16x9,
    this.truckBranding = 'neutral',
    this.timeZone,
    this.designVersion = kFilmDesignVersion,
    this.personalTitle,
  });

  static const int schemaVersion = 1;

  /// Kartenplan der Berechnung (Start, Ziel, Linien, Fährabschnitte, Stopps).
  final RouteMapPlan plan;

  /// ETA-Zeitleiste der Berechnung (Fahrt, Pausen, Fähre, Ankunft).
  final EtaResult eta;

  final String title;
  final String? fromName;
  final String? toName;
  final FilmFormat format;

  /// Kennung der Lkw-Lackierung ([TruckBranding.id]).
  final String truckBranding;

  /// IANA-Zeitzone des Browsers, in der die Zeiten erstellt wurden (z. B.
  /// `Europe/Vienna`). Der Exportdienst rendert in derselben Zone – sonst
  /// zeigten Uhr und Tag/Nacht andere Werte als die Vorschau.
  final String? timeZone;

  final String designVersion;

  /// Persönlicher Titel des Fahrers (optional, bereinigt, nur lokal
  /// gespeichert). Dezent im Intro und Outro; ohne Titel bleibt der Film –
  /// samt Kennung und JSON – wie bisher.
  final String? personalTitle;

  TourFilmSpec copyWith({FilmFormat? format}) => TourFilmSpec(
        plan: plan,
        eta: eta,
        title: title,
        fromName: fromName,
        toName: toName,
        format: format ?? this.format,
        truckBranding: truckBranding,
        timeZone: timeZone,
        designVersion: designVersion,
        personalTitle: personalTitle,
      );

  // ------------------------------------------------------------ Kennung

  /// Stabile Kennung der Filmversion (SHA-256 über den filmrelevanten Inhalt,
  /// Koordinaten auf 1e-6° gerundet, Zeiten als UTC-Millisekunden).
  String get filmId {
    final canonical = jsonEncode(_identityContent());
    return sha256.convert(utf8.encode(canonical)).toString().substring(0, 24);
  }

  Map<String, Object?> _identityContent() {
    List<List<int>> pts(List<LatLng> p) => [for (final q in p) [(q.latitude * 1e6).round(), (q.longitude * 1e6).round()]];
    return {
      'design': designVersion,
      'format': format.name,
      'truck': truckBranding,
      'start': pts([plan.start!]),
      'dest': pts([plan.dest!]),
      'route': pts(plan.route),
      'segments': [
        for (final s in plan.segments) {'p': pts(s.points), 'l': s.label, 'f': s.isFerry, 'g': s.isGap}
      ],
      'stops': pts(plan.stops),
      'title': title,
      'from': fromName,
      'to': toName,
      'eta': _etaJson(eta),
      'tz': timeZone,
      // Nur mit Titel: bestehende Kennungen ohne Titel bleiben unverändert.
      if (personalTitle != null) 'personalTitle': personalTitle,
    };
  }

  // ------------------------------------------------------------ JSON

  Map<String, Object?> toJson() => {
        'schema': schemaVersion,
        'filmId': filmId,
        'design': designVersion,
        'title': title,
        'fromName': fromName,
        'toName': toName,
        'format': format.name,
        'truckBranding': truckBranding,
        'timeZone': timeZone,
        if (personalTitle != null) 'personalTitle': personalTitle,
        'plan': {
          'start': _pt(plan.start!),
          'dest': _pt(plan.dest!),
          'route': [for (final p in plan.route) _pt(p)],
          'segments': [
            for (final s in plan.segments)
              {'points': [for (final p in s.points) _pt(p)], 'label': s.label, 'isFerry': s.isFerry, 'isGap': s.isGap}
          ],
          'stops': [for (final p in plan.stops) _pt(p)],
          'subtitle': plan.subtitle,
        },
        'eta': _etaJson(eta),
      };

  factory TourFilmSpec.fromJson(Map<String, dynamic> j) {
    if (j['schema'] != schemaVersion) {
      throw FormatException('Unbekannte Filmspezifikation (Schema ${j['schema']}).');
    }
    final p = j['plan'] as Map<String, dynamic>;
    final spec = TourFilmSpec(
      plan: RouteMapPlan.restored(
        start: _ll(p['start']),
        dest: _ll(p['dest']),
        route: [for (final q in p['route'] as List) _ll(q)],
        segments: [
          for (final s in p['segments'] as List)
            MapSegment(
              points: [for (final q in (s as Map)['points'] as List) _ll(q)],
              label: s['label'] as String?,
              isFerry: s['isFerry'] == true,
              isGap: s['isGap'] == true,
            )
        ],
        stops: [for (final q in p['stops'] as List) _ll(q)],
        subtitle: p['subtitle'] as String?,
      ),
      eta: _etaFromJson(j['eta'] as Map<String, dynamic>),
      title: j['title'] as String,
      fromName: j['fromName'] as String?,
      toName: j['toName'] as String?,
      format: FilmFormat.values.byName(j['format'] as String),
      truckBranding: j['truckBranding'] as String? ?? 'neutral',
      timeZone: j['timeZone'] as String?,
      designVersion: j['design'] as String? ?? kFilmDesignVersion,
      // Ältere Spezifikationen ohne Feld: kein Titel.
      personalTitle: j['personalTitle'] as String?,
    );
    final expected = j['filmId'];
    if (expected != null && expected != spec.filmId) {
      throw const FormatException('Filmspezifikation beschädigt (Kennung passt nicht zum Inhalt).');
    }
    return spec;
  }

  static List<double> _pt(LatLng p) => [p.latitude, p.longitude];
  static LatLng _ll(Object? v) {
    final l = v as List;
    return LatLng((l[0] as num).toDouble(), (l[1] as num).toDouble());
  }

  static int? _ms(DateTime? t) => t?.toUtc().millisecondsSinceEpoch;
  static DateTime? _dt(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch((v as num).toInt(), isUtc: true).toLocal();

  static Map<String, Object?> _etaJson(EtaResult e) => {
        'arrival': _ms(e.arrival),
        'steps': [
          for (final s in e.steps)
            {
              'text': s.text,
              'type': s.type.name,
              'title': s.title,
              'detail': s.detail,
              'start': _ms(s.start),
              'end': _ms(s.end),
              'km': s.distanceKm,
              'rest': s.restSatisfied,
              'technical': s.technical,
            }
        ],
        'summary': e.summary == null
            ? null
            : {
                'distanceKm': e.summary!.distanceKm,
                'averageKmh': e.summary!.averageKmh,
                'drivingMinutes': e.summary!.drivingMinutes,
                'breakMinutes': e.summary!.breakMinutes,
                'restMinutes': e.summary!.restMinutes,
                'waitingMinutes': e.summary!.waitingMinutes,
                'ferryMinutes': e.summary!.ferryMinutes,
                'ferryRestMinutes': e.summary!.ferryRestMinutes,
                'tankMinutes': e.summary!.tankMinutes,
                'tenHourDaysUsed': e.summary!.tenHourDaysUsed,
                'reducedDailyRestsUsed': e.summary!.reducedDailyRestsUsed,
              },
      };

  static EtaResult _etaFromJson(Map<String, dynamic> j) {
    final s = j['summary'] as Map<String, dynamic>?;
    return EtaResult(
      [
        for (final x in j['steps'] as List)
          EtaStep(
            (x as Map)['text'] as String,
            type: EtaEventType.values.byName(x['type'] as String),
            title: x['title'] as String?,
            detail: x['detail'] as String?,
            start: _dt(x['start']),
            end: _dt(x['end']),
            distanceKm: (x['km'] as num?)?.toDouble(),
            restSatisfied: x['rest'] as bool?,
            technical: x['technical'] == true,
          )
      ],
      _dt(j['arrival']),
      summary: s == null
          ? null
          : EtaSummary(
              distanceKm: (s['distanceKm'] as num).toDouble(),
              averageKmh: (s['averageKmh'] as num).toDouble(),
              drivingMinutes: s['drivingMinutes'] as int,
              breakMinutes: s['breakMinutes'] as int,
              restMinutes: s['restMinutes'] as int,
              waitingMinutes: s['waitingMinutes'] as int,
              ferryMinutes: s['ferryMinutes'] as int,
              ferryRestMinutes: s['ferryRestMinutes'] as int? ?? 0,
              tankMinutes: s['tankMinutes'] as int,
              tenHourDaysUsed: s['tenHourDaysUsed'] as int,
              reducedDailyRestsUsed: s['reducedDailyRestsUsed'] as int,
            ),
    );
  }
}
