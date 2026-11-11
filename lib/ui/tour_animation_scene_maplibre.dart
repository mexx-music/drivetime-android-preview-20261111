import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../animation/articulation.dart';
import '../animation/cinematic_camera.dart';
import '../animation/cinematic_quality.dart';
import '../animation/country_borders.dart';
import '../animation/daylight.dart';
import '../animation/ferry_cinematic.dart';
import '../animation/ship_model.dart';
import '../animation/tour_camera.dart';
import '../logic/eta_calculator.dart';
import '../animation/tour_path.dart';
import '../animation/tour_motion.dart';
import '../animation/tour_outro.dart';
import '../animation/tour_story.dart';
import '../services/cinematic_session.dart';
import 'map_images.dart';
import 'map_label_style.dart';
import 'tour_animation_view.dart' show tourKmLabel;
import 'ship_sprites.dart';
import 'tour_outro_overlay.dart';
import 'tour_story_overlay.dart';
import 'truck_sprites.dart';
import '../animation/truck_projection.dart';

/// EXPERIMENT: dieselbe Cinematic-Szene in 2.5D mit MapLibre + Vektorkacheln
/// (OpenFreeMap). Nutzt [TourPath], Story, Fahrleiste und Abschlusskarte
/// unverändert; nur die Karte darunter ist eine andere.
class TourAnimationSceneMapLibre extends StatefulWidget {
  const TourAnimationSceneMapLibre({
    super.key,
    required this.path,
    required this.position,
    required this.title,
    required this.frame,
    this.stops = const [],
    this.finished = false,
    this.manualZoom,
    this.countries,
    this.planKm,
    this.summary,
    this.fromName,
    this.toName,
    this.storyEvents = const [],
    this.onReady,
    this.truckView = TruckView.top,
    this.truckModel = const TruckModel(),
    this.truckBias = 22,
    this.truckPitch = 42,
    this.truckScale = 1,
    this.cameraMode = CameraMode.follow,
    this.cinematicDemo = false,
    this.cameraDebug = false,
    this.dayNight = DayNightMode.off,
    this.eta,
    this.onUnavailable,
    this.outro,
    this.outroTimeline,
    this.outroTime,
    this.cinematicPlan,
    this.cinematicHeading,
    this.frameDt,
    this.onPendingProbe,
    this.heroPhoto,
    this.heroCutout,
    this.quality = CinematicQuality.previewHigh,
    this.exportFrame,
    this.onExportFrameApplied,
  });

  /// Videoexport: Nummer des Bildes, das diese Szene zeigen soll, und
  /// Rückmeldung, sobald sie es übernommen hat. step() löst das Bild nur
  /// aus; Flutter baut es erst im nächsten Frame – bis zur Rückmeldung ist
  /// das Bild nicht fertig.
  final int? exportFrame;
  final void Function(int frame)? onExportFrameApplied;

  /// Renderqualität (Vorschau/Film) – nur Darstellung, nie Regie.
  final CinematicQuality quality;

  /// Test/Export: freigestellter Hero-Lkw im Outro.
  final String? heroCutout;

  /// Test/Export: echtes Foto des Lkw im Outro.
  final String? heroPhoto;

  /// Videoexport: fester Bildtakt statt Uhrzeit (deterministisch).
  final Duration? frameDt;

  /// Videoexport: meldet eine Abfrage „wie viele Bilder entstehen noch“ –
  /// 0 erst, wenn dieses Bild exakt das berechnete Fahrzeugbild zeigt – und
  /// den Bildzustand (gewünschtes und gezeigtes Fahrzeugbild) als JSON.
  final void Function(int Function() pending, String Function() state)? onPendingProbe;

  /// Filmische Richtungsstabilisierung des Sattelzugs (null = Fahrspur ohne).
  final CinematicHeading? cinematicHeading;

  /// Kameraregie passend zum Filmtempo (siehe [cinematicMotionFor]); null =
  /// Regie wie bisher aus der Fahrdauer.
  final CinematicPlan? cinematicPlan;

  /// Cinematic-Outro: Daten der fertigen Tour; null = bisherige Abschlusskarte.
  final OutroData? outro;
  final OutroTimeline? outroTimeline;

  /// Outro-Zeit in Sekunden ab Ankunft; null vor der Ankunft.
  final double? outroTime;

  /// Vektorkarte (Stil) nicht erreichbar – die Ansicht fällt auf 2D zurück.
  final VoidCallback? onUnavailable;

  /// Kamera: ruhige Folgekamera oder mit wenigen Drohnenfahrten.
  final CameraMode cameraMode;

  /// Demo: Kamerafahrten gedrängt, um sie schnell nacheinander zu sehen.
  final bool cinematicDemo;

  /// Entwicklung: Kamerawerte einblenden.
  final bool cameraDebug;

  /// Tag/Nacht: aus, aus der Planung oder simuliert (Demo).
  final DayNightMode dayNight;

  /// Planung für Tag/Nacht (Uhrzeit entlang der Strecke).
  final EtaResult? eta;

  /// Fahrzeugtyp und Branding (getrennt wählbar).
  final TruckModel truckModel;

  /// 3/4: Schrägstellung in Grad, die die Aufliegerseite zeigt.
  final double truckBias;

  /// 3/4: Neigung, mit der das Fahrzeug gezeichnet wird (Karte: 42°).
  final double truckPitch;

  /// 3/4: Größenfaktor des Fahrzeugs.
  final double truckScale;

  /// Ansicht des Fahrzeugs in der geneigten Karte.
  final TruckView truckView;

  /// Karte, Stil und Ebenen sind bereit – erst dann soll die Fahrt laufen.
  final VoidCallback? onReady;

  final TourPath path;
  final TourPosition position;
  final String title;
  final TourFrame frame;
  final List<LatLng> stops;
  final bool finished;
  final double? manualZoom;
  final CountryIndex? countries;
  final double? planKm;
  final TourSummary? summary;
  final String? fromName;
  final String? toName;
  final List<TourStoryEvent> storyEvents;

  /// Stil: OpenFreeMap „Liberty“ (OpenMapTiles-Schema), Beschriftung lesbar.
  static const styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static Future<String>? _style;

  /// Stil einmal laden und umschreiben – derselbe Abruf, den MapLibre sonst
  /// selbst machen würde.
  static Future<String> loadStyle() => _style ??= () async {
        try {
          final res = await http.get(Uri.parse(styleUrl));
          if (res.statusCode != 200) throw StateError('Stil HTTP ${res.statusCode}');
          final style = jsonDecode(res.body) as Map<String, dynamic>;
          return jsonEncode(latinizeStyle(style));
        } catch (_) {
          _style = null;
          rethrow;
        }
      }();

  @override
  State<TourAnimationSceneMapLibre> createState() => _TourAnimationSceneMapLibreState();
}

class _TourAnimationSceneMapLibreState extends State<TourAnimationSceneMapLibre> {
  late final Future<String> _style = TourAnimationSceneMapLibre.loadStyle();
  late final TourCameraRig _rig = TourCameraRig(widget.path);

  /// Kamera (Regie) – erst im ersten build angelegt, wenn das Bildformat
  /// bekannt ist.
  CinematicCamera? _cam;
  CameraState? _camState;
  double _cameraZoom = 0;
  double _cameraPitch = 42;

  /// Tag/Nacht.
  late final TourClock? _clock =
      widget.eta == null ? null : TourClock.fromEta(widget.eta!, widget.path);
  final DaylightEaser _daylight = DaylightEaser();
  double _night = 0;
  double _shownVeil = -1;
  ArticulatedPose? _pose;

  CinematicCamera _cameraFor(Size size) => _cam ??= CinematicCamera(
        widget.path,
        plan: widget.cameraMode == CameraMode.follow
            ? CinematicPlan.followOnly
            : widget.cinematicPlan != null
            ? widget.cinematicPlan!
            // Mit Fähre: Straßen-Regie plus Fährablauf; ohne Fähre unverändert.
            : ferryAwarePlan(
                widget.cinematicDemo
                    ? CinematicPlan.demo()
                    : CinematicPlan.standard(tourAnimationDuration(widget.path.totalMeters)),
                widget.path,
                tourAnimationDuration(widget.path.totalMeters)),
        aspect: size.height <= 0 ? 1.6 : size.width / size.height,
        zoomOffset: widget.cinematicPlan != null ? cinematicCameraZoomOffset : 0,
      );
  /// Fährabschnitte der Tour (leer: Tour ohne Fähre – alles wie bisher).
  late final List<FerryCrossing> _crossings = ferryCrossings(widget.path);
  VehicleMix? _mix;
  int _shipYawFrame = 0;
  String? _shownShip;
  bool _shipVisible = false;

  // ------------------------------------------------------------- Outro

  /// Outro läuft (Ziel erreicht, Cinematic-Ansicht).
  bool get _inOutro => widget.outro != null && widget.outroTimeline != null && widget.outroTime != null;

  /// Bisheriges Ende (Übersicht von oben) nur ohne Outro.
  bool get _endOverview => widget.finished && widget.outro == null;

  OutroCamera? _outroCam;
  OutroLights? _outroLights;
  bool _outroPrewarmed = false;
  double _shownCone = -1;
  double _shownOutroVeil = -1;

  /// Auflösung der Fahrzeugbilder im Outro (näher dran → schärfer).
  double get _outroSpritePx => widget.quality.outroSpritePx;

  ml.MapLibreMapController? _map;
  bool _ready = false;
  DateTime? _lastFrame;
  DateTime _lastTrail = DateTime.fromMillisecondsSinceEpoch(0);
  String? _highlightIso;
  bool _overviewShown = false;
  double _cameraBearing = 0;

  static ml.LatLng _ml(LatLng p) => ml.LatLng(p.latitude, p.longitude);

  Map<String, dynamic> _line(List<LatLng> pts, [Map<String, dynamic> props = const {}]) => {
        'type': 'Feature',
        'properties': props,
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in pts) [p.longitude, p.latitude]],
        },
      };

  Map<String, dynamic> _collection(List<Map<String, dynamic>> features) =>
      {'type': 'FeatureCollection', 'features': features};

  Future<void> _onStyleLoaded() async {
    final map = _map;
    if (map == null) return;
    final path = widget.path;
    trackMapImages();
    await map.addImage('truck-top', await truckTopPng(branding: widget.truckModel.branding));
    // Profil: Kartenfläche mit begrenzter Pixeldichte (HUD bleibt scharf).
    final maxRatio = widget.quality.maxMapPixelRatio;
    if (maxRatio != null) capMapPixelRatio(maxRatio, sameMapAs: 'truck-top');
    await map.addImage('truck-rear', await truckRearPng(branding: widget.truckModel.branding));
    await map.addImage('truck', await truckSidePng(mirrored: false, branding: widget.truckModel.branding));
    await map.addImage('truck-mirrored', await truckSidePng(mirrored: true, branding: widget.truckModel.branding));

    // Nacht: dunkler Schleier über der Grundkarte, unter Route und LKW.
    await map.addGeoJsonSource('veil', _collection([
      {
        'type': 'Feature',
        'properties': const <String, dynamic>{},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [[-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]]
          ],
        },
      },
    ]));
    await map.addFillLayer('veil', 'night-veil', _veilProps(0));
    await map.addImage('headlights', await headlightConePng());
    // Outro: Umgebung ruhiger und dunkler (nie schwarz), Ziel bleibt erkennbar.
    await map.addFillLayer('veil', 'outro-veil', _outroVeilProps(0));

    await map.addGeoJsonSource('country', _collection(const []));
    await map.addFillLayer('country', 'country-fill', _countryFillProps(0));
    await map.addLineLayer('country', 'country-line', _countryLineProps(0));

    // Die ganze Route mit ALLEN Punkten der Berechnung (Etappen-Geometrie),
    // nicht ausgedünnt – MapLibre vereinfacht je Zoomstufe selbst passend.
    // Cinematic: die Linie ist unsichtbar (Deckkraft 0, siehe unten) – dann
    // bekommt die Karte sie gar nicht erst. Sonst kachelt MapLibre alle
    // Punkte (Tuzla–Odense: 98 778) auf jeder Zoomstufe, in der Übersicht
    // über ganz Europa; gemessen 50–75 MB weniger lebender JS-Speicher.
    // Bewegung, Kamera und Berechnung nutzen weiter widget.path.
    await map.addGeoJsonSource('route', _collection([
      if (widget.cinematicHeading == null)
        for (final leg in path.legs) _line(leg.points, {'ferry': leg.kind != TourLegKind.road}),
    ]));
    // Cinematic: keine Vorschau der Strecke – nur die Spur, die der Lkw
    // hinter sich herzieht (wie ein Roadmovie, die Reise entsteht).
    await map.addLineLayer('route', 'route-line', ml.LineLayerProperties(
      lineColor: const ['case', ['get', 'ferry'], '#26A69A', '#3F51B5'],
      lineOpacity: widget.cinematicHeading != null ? 0.0 : 0.45,
      lineWidth: 5,
      lineCap: 'round',
      lineJoin: 'round',
    ));
    await map.addGeoJsonSource('driven', _collection(const []));
    await map.addLineLayer('driven', 'driven-glow', _drivenGlowProps(0));
    await map.addLineLayer('driven', 'driven-line', const ml.LineLayerProperties(
      lineColor: ['case', ['get', 'ferry'], '#00897B', '#1B5E20'],
      lineWidth: 7,
      lineCap: 'round',
      lineJoin: 'round',
    ));
    await map.addGeoJsonSource('points', _collection([
      _point(path.start, {'kind': 'start'}),
      for (final s in widget.stops) _point(s, {'kind': 'stop'}),
      _point(path.end, {'kind': 'dest'}),
    ]));
    await map.addCircleLayer('points', 'points-circle', const ml.CircleLayerProperties(
      circleRadius: ['match', ['get', 'kind'], 'stop', 5, 8],
      circleColor: ['match', ['get', 'kind'], 'start', '#2E7D32', 'dest', '#C62828', '#3949AB'],
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 2,
      circlePitchAlignment: 'map',
    ));
    await map.addGeoJsonSource(
        'truck', _collection([_point(widget.position.point, _truckProps(_localHeading(widget.position.meters)))]));
    // Zwei Ebenen, je Feature gewählt: flach auf der Karte (von oben; dreht
    // und neigt sich mit ihr) oder aufrecht zum Betrachter (Heck, seitlich,
    // 3/4 – das Bild bringt die Perspektive selbst mit).
    for (final flat in [true, false]) {
      await map.addSymbolLayer('truck', flat ? 'truck-flat' : 'truck-upright', ml.SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: ['get', 'size'],
        iconRotate: ['get', 'rot'],
        iconRotationAlignment: flat ? 'map' : 'viewport',
        iconPitchAlignment: flat ? 'map' : 'viewport',
        // Deckkraft je Feature (Überblendung LKW ↔ Fähre), sonst voll.
        iconOpacity: ['coalesce', ['get', 'op'], 1],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ), filter: ['==', ['get', 'flat'], flat]);
    }
    // Fähre: aufrecht zum Betrachter wie der Sattelzug, über ihm.
    await map.addGeoJsonSource('ship', _collection(const []));
    await map.addSymbolLayer('ship', 'ship-upright', const ml.SymbolLayerProperties(
      iconImage: ['get', 'icon'],
      iconSize: ['get', 'size'],
      iconRotationAlignment: 'viewport',
      iconPitchAlignment: 'viewport',
      iconOpacity: ['get', 'op'],
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
    ));
    // Lichtkegel: flach auf der Straße, gedreht mit der ZUGMASCHINE (nicht mit
    // der Kamera) – unter dem Fahrzeug.
    await map.addGeoJsonSource('lights', _collection(const []));
    await map.addSymbolLayer('lights', 'headlight-cone', _coneProps(0), belowLayerId: 'truck-flat');
    _overlayOn = kIsWeb && widget.frameDt == null && vehicleOverlayAttach(sameMapAs: 'truck-top');
    _ready = true;
    widget.onPendingProbe?.call(
      () => _framesPending.length + (_exportFrameExact ? 0 : 1),
      () => jsonEncode({
        'wanted': _wantedFrame, 'shown': _shownFrame, 'wantedShip': _wantedShip, 'shownShip': _shownShip,
        'refreshes': _exportRefreshes,
        'drawn': _drawTruck == null ? null : renderedIcon('truck-upright', sameMapAs: 'truck-top'),
        'onScreen': _drawTruckAt == null
            ? null
            : isOnScreen(_drawTruckAt!.latitude, _drawTruckAt!.longitude, sameMapAs: 'truck-top'),
      }),
    );
    _update(force: true);
    widget.onReady?.call();
  }

  // ------------------------------------------------ Geometrie, unvereinfacht

  /// Alle Punkte der Linie und ihre Strecke ab Start – einmal berechnet.
  late final List<LatLng> _pts = widget.path.points;
  late final List<double> _cum = () {
    const d = Distance(calculator: Haversine());
    final out = <double>[0];
    for (var i = 1; i < _pts.length; i++) {
      out.add(out.last + d(_pts[i - 1], _pts[i]));
    }
    return out;
  }();

  int _indexAt(double meters) {
    var lo = 0, hi = _cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= meters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Gefahrene Spur: die letzten [window] Meter punktgenau aus der vollen
  /// Geometrie (Kreuze, Umfahrungen, enge Kurven), weiter hinten leicht
  /// ausgedünnt – die Spur wird etwa 12-mal pro Sekunde neu übergeben.
  List<Map<String, dynamic>> _drivenFeatures(TourPosition pos, {double window = 60000}) {
    final m = pos.meters;
    final split = math.max(0.0, m - window);
    final older = split > 0
        ? widget.path.trailUpTo(split, maxPointsPerLeg: 1500)
        : const <TourTrail>[];
    final from = _indexAt(split);
    final to = _indexAt(m);
    final recent = <LatLng>[
      if (split > 0) widget.path.at(split).point,
      for (var i = from + 1; i <= to; i++) _pts[i],
      pos.point,
    ];
    return [
      for (final t in older) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
      if (recent.length >= 2) _line(recent, {'ferry': pos.kind != TourLegKind.road}),
    ];
  }

  /// Fahrtrichtung des Fahrzeugs: lokal über ±150 m der vollen Geometrie,
  /// damit es auch in Kreuzen und engen Kurven der Straße folgt. (Die
  /// Kamera nutzt ihre eigene, bewusst weiche Richtung.)
  double _localHeading(double meters) {
    const span = 150.0;
    final a = widget.path.at(math.max(0, meters - span)).point;
    final b = widget.path.at(math.min(widget.path.totalMeters, meters + span)).point;
    if (a == b) return widget.position.bearing;
    return (const Distance(calculator: Haversine()).bearing(a, b) + 360) % 360;
  }

  /// Bild und Drehung des Fahrzeugs für die gewählte Ansicht.
  // ------------------------------------------------------ 3/4-Fahrzeug

  /// Aktuell gezeigte Seite (Auto mit Hysterese) und weicher Seitenwinkel.
  final SideChooser _sideChooser = SideChooser();
  double? _bias;
  int _frame = 0;
  String? _shownFrame;
  final Set<String> _framesReady = {};
  final Set<String> _framesPending = {};
  Duration _dt = Duration.zero;

  String _frameName(int frame) =>
      '34-${widget.truckModel.id}-p${widget.truckPitch.round()}-$frame';

  /// Bild für einen Gierwinkel bei Bedarf erzeugen und der Karte geben.
  void _ensureFrame(int frame) {
    final name = _frameName(frame);
    if (_framesReady.contains(name) || _framesPending.contains(name)) return;
    _framesPending.add(name);
    truckThreeQuarterPng(widget.truckModel,
            yawDeg: frame * _frameStep, pitchDeg: widget.truckPitch, pxPerMeter: 10)
        .then((png) async {
      await _map?.addImage(name, png);
      _framesPending.remove(name);
      _framesReady.add(name);
      _keepSprite(name);
    });
  }

  static const _frameStep = 4.0;

  // --------------------------------------------- Bildspeicher begrenzen

  /// Fahrzeugbilder der Fahrt (Lkw, Fähre), zuletzt benutzte zuletzt. Jede
  /// neue Winkel-/Knick-/Lichtstufe ist ein eigenes Bild; ohne Grenze
  /// wuchsen sie in einer Tour auf Hunderte (157 MB nach 50 s) und Safari
  /// auf dem iPad beendete die Seite. Ältere Bilder werden deshalb wieder
  /// entfernt und bei Bedarf neu erzeugt. Outro-Bilder mit Lichtzustand
  /// zählen nicht mit (wenige, und sie müssen bereitliegen).
  final Set<String> _spriteUse = <String>{}; // LinkedHashSet: Reihenfolge = Nutzung

  /// Höchstzahl je Profil (CinematicQuality): in der Fahrt; ab dem
  /// Zielanflug mehr, weil die Bilder des Outro-Schwenks vorab entstehen und
  /// nicht vor ihrem Einsatz verschwinden dürfen.

  /// [name] als gerade benutzt vermerken und den Speicher begrenzen.
  void _keepSprite(String name) {
    _spriteUse
      ..remove(name)
      ..add(name);
    _trimSprites(keep: name);
  }

  /// Speicher auf die Höchstzahl begrenzen (älteste zuerst). Profil mit
  /// [CinematicQuality.approachDriveSprites]: ab dem Zielanflug zählen die
  /// vorab geplanten Outro-Bilder nicht mit und bleiben.
  void _trimSprites({String? keep}) {
    final q = widget.quality;
    final approach = _outroPrewarmed && q.approachDriveSprites != null;
    final cap = approach ? q.approachDriveSprites! : (_outroPrewarmed ? q.maxDriveSpritesOutro : q.maxDriveSprites);
    bool pinned(String n) => approach && _outroPlanned.contains(n);
    var count = approach ? _spriteUse.where((n) => !pinned(n)).length : _spriteUse.length;
    if (count <= cap) return;
    for (final old in _spriteUse.toList()) {
      if (count <= cap) break;
      if (old == _shownFrame || old == _shownShip || old == keep || pinned(old)) continue;
      _dropSprite(old);
      count--;
    }
  }

  void _dropSprite(String old) {
    _spriteUse.remove(old);
    _framesReady.remove(old);
    for (final m in _readyYaws.values) {
      m.removeWhere((_, v) => v == old);
    }
    _readyDrive.remove(old);
    removeMapImage(old);
  }

  /// Fahrzeugbild der Karte geben. Im Browser als rohe Pixel direkt an
  /// MapLibre: das Plugin dekodiert PNGs in reinem Dart Pixel für Pixel –
  /// gemessen über die Hälfte der Rechenzeit während der Tour. Gleiche
  /// Pixel, nur ohne den Umweg; sonst wie bisher als PNG.
  Future<void> _addSprite(String name, Future<Uint8List> Function() draw) async {
    if (kIsWeb) {
      // Live-Vorschau: Browser-Canvas statt Flutter-toImage (das je Bild eine
      // WebGL-Textur zurücklässt). Export (frameDt) bleibt beim Flutter-Weg.
      final bmp = await asSpriteBitmap(draw, browser: widget.frameDt == null);
      if (addRawMapImage(name, bmp.width, bmp.height, bmp.rgba, sameMapAs: 'truck-top')) return;
    }
    await _map?.addImage(name, await draw());
  }

  /// Bilder, die das Outro laut Vorplanung braucht (stehender Lkw in der
  /// Endpose, Kameraschwenk, Licht).
  final Set<String> _outroPlanned = {};
  bool _driveReleased = false;

  /// Diagnose: Outro-Bilder, in denen das gewünschte Fahrzeugbild noch nicht
  /// fertig war; verschiedene solche Bilder; davon nicht vorab geplante.
  int _outroMissFrames = 0, _outroUnplanned = 0;
  final Set<String> _outroLate = {};

  /// Profil: beim Übergang ins Outro alle Fahrbilder freigeben, die das
  /// Outro nicht braucht – einmal je Durchlauf.
  void _releaseDriveSprites() {
    if (_driveReleased || !widget.quality.releaseDriveSpritesAtOutro || _outroPlanned.isEmpty) return;
    _driveReleased = true;
    for (final old in _spriteUse.toList()) {
      if (_outroPlanned.contains(old) || old == _shownFrame) continue;
      _dropSprite(old);
    }
  }

  /// Gezeigtes Bild als benutzt vermerken (ohne erneut zu begrenzen).
  void _touchSprite(String? name) {
    if (name == null || !_spriteUse.remove(name)) return;
    _spriteUse.add(name);
  }

  // --------------------------------------------- gekoppelter Sattelzug

  /// Sprite: Bildpunkte je Fahrzeugmeter; Anzeige: Punkte je Meter bei
  /// Folge-Zoom (mit [truckScale]).
  double get _spritePx => widget.quality.spritePx;

  /// In der Normalfahrt kleiner (62 % des bisherigen Symbols): der LKW fügt
  /// sich in die Karte, Route und Landschaft bekommen Raum. Nah wird er nur,
  /// wenn die Kamera in einem Shot heranfährt (Zoom), nie durch Vergrößern.
  static const followSize = 0.62;
  double get _pointsPerMeter => 5 * widget.truckScale * followSize;

  /// Kartenmeter je Fahrzeugmeter – aus dem FOLGE-Zoom, nicht aus dem Zoom
  /// der aktuellen Kamerafahrt: die Kamera verändert die Fahrzeuggeometrie nie.
  /// Fahrzeugpose: im Cinematic-Filmtempo mit Trägheit ([ArticulatedTrack],
  /// einmal je Tour berechnet), sonst wie bisher. Hängt nur von der
  /// Streckenposition ab – nie von der Kamera.
  ArticulatedPose _poseAt(double meters) {
    final unit = _unitAt(widget.path.at(meters).point);
    if (widget.cinematicPlan == null) return articulate(widget.path, meters, metersPerUnit: unit);
    final heading = widget.cinematicHeading;
    if (heading != null) return heading.pose(meters, metersPerUnit: unit);
    final track = _track ??= ArticulatedTrack(widget.path, unitAt: _unitAt, inertia: cinematicTruckInertia);
    return track.pose(meters, metersPerUnit: unit);
  }

  ArticulatedTrack? _track;

  double _unitAt(LatLng p) =>
      _pointsPerMeter * metersPerScreenPoint(_cam?.followZoom ?? _rig.zoom, p.latitude);

  int _yawFrame = 0, _knickFrame = 0;
  late double _shownFramePx = _spritePx;

  String _articulatedName(int yaw, int knick, int pitch, double night) =>
      'art-${widget.truckModel.id}-p$pitch-y$yaw-k$knick-n${(night * 8).round()}';

  /// Fahrzeugbild anfordern (einmal erzeugen und behalten); liefert den Namen.
  String _requestArticulated(int yaw, int knick, int pitch, double night, OutroLights? lights) {
    final name = _articulatedName(yaw, knick, pitch, night) + (lights == null ? '' : '-o${lights.key}');
    // Im Outro höchstens zwei Bilder gleichzeitig erzeugen – viele parallel
    // blockierten die Seite (gemessen mehrere Sekunden); bis dahin zeigt die
    // Szene das nächstliegende fertige Bild.
    // Normale Fahrbilder nie bremsen – sonst springt der Lkw beim Zielanflug.
    final busy = widget.outro != null && _framesPending.length >= 2 && (lights != null || _inOutro);
    if (!_framesReady.contains(name) && !_framesPending.contains(name) && !busy) {
      _framesPending.add(name);
      _addSprite(
              name,
              () => truckArticulatedPng(widget.truckModel,
                  tractorYaw: yaw * 4.0,
                  knick: knick * 3.0,
                  pitchDeg: pitch.toDouble(),
                  pxPerMeter: lights == null ? _spritePx : _outroSpritePx,
                  night: night,
                  tailLights: lights == null ? null : math.max(lights.tail, night),
                  headLights: lights == null ? null : math.max(lights.head, night),
                  sweep: lights?.sweep))
          .then((_) {
        _framesPending.remove(name);
        _framesReady.add(name);
        (_readyYaws[_poseKey(knick, pitch, night, lights)] ??= {})[yaw] = name;
        if (lights == null) {
          _readyDrive[name] = (yaw: yaw, knick: knick, pitch: pitch, night: (night * 8).round());
          _keepSprite(name);
        }
        _afterSpriteReady();
      });
    }
    return name;
  }

  /// Fertige Bilder je Pose ohne Gierwinkel – für den nächstliegenden Ersatz.
  final Map<String, Map<int, String>> _readyYaws = {};
  String _poseKey(int knick, int pitch, double night, OutroLights? lights) =>
      'k$knick-p$pitch-n${(night * 8).round()}-${lights?.key}';

  /// Nächstliegendes fertiges Bild derselben Pose (Gierwinkel), sonst null.
  String? _nearestReady(int yaw, int knick, int pitch, double night, OutroLights? lights) {
    final m = _readyYaws[_poseKey(knick, pitch, night, lights)];
    if (m == null || m.isEmpty) return null;
    var best = m.keys.first;
    int dist(int a) => ((a - yaw) % 90 + 90) % 90 > 45 ? 90 - ((a - yaw) % 90 + 90) % 90 : ((a - yaw) % 90 + 90) % 90;
    for (final k in m.keys) {
      if (dist(k) < dist(best)) best = k;
    }
    return m[best];
  }

  /// Fertige Fahrbilder (ohne Outro-Licht) mit ihrer Pose.
  final Map<String, ({int yaw, int knick, int pitch, int night})> _readyDrive = {};

  /// Fahrt: das fertige Bild, das der gewünschten Pose am nächsten kommt –
  /// statt des zuletzt gezeigten. Auf langsamen Geräten entsteht das Bild
  /// für die aktuelle Pose erst einige Bilder später; das alte Bild zeigte
  /// den Auflieger so lange im falschen Knickwinkel (gemessen bis über 90°
  /// daneben, bei 6-fach gedrosselter CPU in einem Viertel der Bilder ≥ 6°):
  /// der Auflieger schien zu schleudern. Der Knick zählt am meisten (er
  /// lässt sich nicht ausgleichen), die Richtung gleicht die Bilddrehung
  /// aus, die Neigung fällt am wenigsten auf. Nur gleiche Nachtstufe.
  String? _closestDrive(int yaw, int knick, int pitch, double night) {
    final n = (night * 8).round();
    String? best;
    var bestCost = double.infinity;
    for (final e in _readyDrive.entries) {
      final r = e.value;
      if (r.night != n) continue;
      final dy = ((r.yaw - yaw) % 90 + 90) % 90;
      final yawErr = math.min(dy, 90 - dy) * 4.0;
      final cost = 2.0 * (r.knick - knick).abs() * 3 + 0.5 * yawErr + 0.5 * (r.pitch - pitch).abs();
      if (cost < bestCost) {
        bestCost = cost;
        best = e.key;
      }
    }
    return best;
  }

  /// Zu Beginn des Outros die Bilder des Licht-Reveals (Endperspektive)
  /// vorbereiten, damit sie bereitliegen, wenn das Licht angeht.
  void _prewarmOutro(OutroCamera oc, OutroTimeline tl, ArticulatedPose pose) {
    final night = nightStep(_night);
    final seen = <String>{};
    // Zuerst die Endperspektive (Ende des Schwenks und erstes Licht), dann
    // alles in zeitlicher Reihenfolge.
    for (final t in [tl.lightsOn - 0.25, tl.lightsOn, ...[for (var t = 0.0; t <= tl.end; t += 1 / 30) t]]) {
      final st = oc.at(t);
      final (yaw, pitch) = _outroFrame(angleDiff(st.bearing, pose.tractorHeading), st.pitch, t);
      final lights =
          t >= tl.lightsOn - 0.2 ? OutroLights.at(tl, t, sweepSteps: widget.quality.outroSweepSteps) : null;
      final key = '$yaw-$pitch-${lights?.key}';
      if (seen.add(key)) {
        final knick = (pose.knick / 3).round();
        _prewarmQueue.add((yaw, knick, pitch, night, lights));
        _outroPlanned.add(_articulatedName(yaw, knick, pitch, night) + (lights == null ? '' : '-o${lights.key}'));
      }
    }
  }

  /// Bildstufen im Outro nach Qualitätsprofil: in der Performance-Vorschau
  /// Gier gröber (8° – der Rest zur echten Richtung wird gedreht), sonst und
  /// im Film wie in der Fahrt (4°); Neigung in 5°-Stufen.
  (int, int) _outroFrame(double yawDeg, double pitchDeg, double t) {
    // Stufen aus dem Profil; der Gier-Index bleibt in 4°-Einheiten (Bildname).
    final q = widget.quality;
    final yawUnits = q.outroYawStep ~/ 4;
    final yaw = (yawDeg / q.outroYawStep).round() * yawUnits;
    final pitch = ((pitchDeg / q.outroPitchStep).round() * q.outroPitchStep).clamp(30, 60);
    return (yaw, pitch);
  }

  OutroCamera _makeOutroCamera(OutroTimeline tl) {
    final cam = _cam ?? _cameraFor(const Size(1000, 700));
    final end = widget.path.totalMeters;
    final pose = _poseAt(end);
    final size = (context.findRenderObject() as RenderBox?)?.size ?? MediaQuery.sizeOf(context);
    return OutroCamera(
      // Exakt der letzte Zustand der Fahrt – kein Sprung.
      from: _camState ?? cam.step(end, Duration.zero),
      truck: pose.kingpin,
      heading: pose.tractorHeading,
      followZoom: cam.followZoom,
      truckPointsPerMeter: _pointsPerMeter,
      width: size.width,
      height: size.height,
      timeline: tl,
      routeSouthWest: _routeBounds.$1,
      routeNorthEast: _routeBounds.$2,
    );
  }

  /// Ausdehnung der ganzen Route (für die Übersicht am Ziel).
  late final (LatLng, LatLng) _routeBounds = () {
    final pts = widget.path.points;
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    return (LatLng(s, w), LatLng(n, e));
  }();

  double _shownGlowRoute = -1;

  /// Dezentes Aufleuchten der gefahrenen Strecke (Übersicht am Ziel).
  static ml.LineLayerProperties _drivenGlowProps(double opacity) => ml.LineLayerProperties(
        lineColor: '#DCEB4B',
        lineWidth: 14,
        lineBlur: 8,
        lineOpacity: opacity,
        lineCap: 'round',
        lineJoin: 'round',
      );

  /// Vorbereitete Outro-Bilder: höchstens eines je Bild anstoßen – alle auf
  /// einmal blockierten die Seite gemessen mehrere Sekunden.
  final List<(int, int, int, double, OutroLights?)> _prewarmQueue = [];
  DateTime _lastPrewarm = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, dynamic>? _articulatedProps(TourPosition pos) {
    final pose = _pose = _poseAt(pos.meters);
    // Bild nach Winkel der Zugmaschine zur Blickrichtung und Knick (mit
    // Hysterese gegen Flackern), Neigung wie die Kamera.
    _yawFrame = frameFor(angleDiff(_cameraBearing, pose.tractorHeading), _yawFrame, step: 4);
    _knickFrame = frameFor(pose.knick, _knickFrame, step: 3);
    final pitch = ((_cameraPitch / 5).round() * 5).clamp(30, 60);
    // Nacht in Achtelstufen: Scheibe, Karosserie, Lichter gleitend.
    final night = nightStep(_night);
    // Outro: während des Kameraschwenks normale Bilder (sie müssen schnell
    // folgen), ab dem Licht-Reveal scharfe Bilder mit Lichtzustand.
    final lights = _inOutro && widget.outroTime! >= widget.outroTimeline!.lightsOn - 0.2 ? _outroLights : null;
    final spritePx = lights == null ? _spritePx : _outroSpritePx;
    var yaw = _yawFrame, pitchFrame = pitch;
    if (_inOutro) {
      (yaw, pitchFrame) = _outroFrame(angleDiff(_cameraBearing, pose.tractorHeading), _cameraPitch, widget.outroTime!);
    }
    final name = _requestArticulated(yaw, _knickFrame, pitchFrame, night, lights);
    _wantedFrame = name;
    if (_inOutro && !_framesReady.contains(name)) {
      // Diagnose: Outro-Bild nicht rechtzeitig fertig (Ersatzbild gezeigt).
      _outroMissFrames++;
      if (_outroLate.add(name) && !_outroPlanned.contains(name)) _outroUnplanned++;
    }
    if (_framesReady.contains(name)) {
      _shownFrame = name;
      _shownFramePx = spritePx;
    } else if (_inOutro) {
      // Im Outro lieber das nächstliegende fertige Bild als ein veraltetes.
      final near = _nearestReady(yaw, _knickFrame, pitchFrame, night, lights);
      if (near != null) {
        _shownFrame = near;
        _shownFramePx = spritePx;
      }
    } else if (lights == null) {
      final near = _closestDrive(yaw, _knickFrame, pitchFrame, night);
      if (near != null) {
        _shownFrame = near;
        _shownFramePx = spritePx;
      }
    }
    final shown = _shownFrame;
    if (shown == null) return null;
    _touchSprite(shown);
    // Größe skaliert mit dem Kamerazoom – der LKW gehört zur Karte.
    final size = _pointsPerMeter / _shownFramePx * math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
    // Zwischen zwei Bildstufen (4°) dreht die Karte weich weiter, das Bild
    // nicht – bei großem Lkw wirkte das wie Zittern. Den Rest zur echten
    // Richtung als Bilddrehung ausgleichen; auch, wenn ein Ersatzbild mit
    // anderer Richtung einspringt (daher bis 15°).
    final m = RegExp(r'-y(-?\d+)-').firstMatch(shown);
    final shownYaw = m == null ? 0.0 : int.parse(m.group(1)!) * 4.0;
    final residual = angleDiff(shownYaw, angleDiff(_cameraBearing, pose.tractorHeading)).clamp(-15.0, 15.0);
    return {'icon': shown, 'rot': residual, 'flat': false, 'size': size};
  }

  // --------------------------------------------- Diagnose-Ringpuffer

  DateTime _lastDiag = DateTime.fromMillisecondsSinceEpoch(0);
  int _diagFrames = 0;

  /// Alle 2 s technische Werte in den Ringpuffer (letzte ≈ 60 s), damit
  /// nach einem Abbruch der Seite sichtbar ist, was zuletzt geschah. Nur in
  /// der Vorschau, nie im Export; keine Orte oder Adressen.
  void _diagnose(TourPosition pos, DateTime now) {
    if (widget.frameDt != null) return;
    _diagFrames++;
    final dt = now.difference(_lastDiag).inMilliseconds;
    if (dt < 2000) return;
    final fps = _lastDiag.millisecondsSinceEpoch == 0 ? null : _diagFrames * 1000 / dt;
    _lastDiag = now;
    _diagFrames = 0;
    final total = widget.path.totalMeters;
    CinematicSession.sample({
      'progress': total > 0 ? double.parse((pos.meters / total).toStringAsFixed(4)) : null,
      if (widget.outroTime != null) 'outroS': double.parse(widget.outroTime!.toStringAsFixed(1)),
      'shot': _camState?.shot,
      'zoom': double.parse(_cameraZoom.toStringAsFixed(2)),
      'pitch': _cameraPitch.round(),
      'bearing': _cameraBearing.round(),
      if (fps != null) 'fps': double.parse(fps.toStringAsFixed(1)),
      'quality': widget.quality.id,
      'sprites': _spriteUse.length,
      'spritesReady': _framesReady.length,
      'spritesPending': _framesPending.length,
      if (_outroPrewarmed) 'prewarmLeft': _prewarmQueue.length,
      if (_outroPrewarmed) 'outroMiss': _outroMissFrames,
      if (_outroPrewarmed) 'outroLate': _outroLate.length,
      if (_outroPrewarmed) 'outroUnplanned': _outroUnplanned,
      ...mapRuntimeStats(sameMapAs: 'truck-top'),
    });
  }

  /// Fahrzeug-Overlay aktiv (Vorschau im Browser; der Export zeichnet weiter
  /// über die Karte).
  bool _overlayOn = false;
  bool _truckInMap = true;

  /// Videoexport: das für dieses Bild berechnete Fahrzeugbild (Lkw/Fähre).
  String? _wantedFrame;
  String? _wantedShip;
  int _exportRefreshes = 0;

  /// Fahrzeugbilder, die gerade als Kartendaten gesetzt sind (null: keins
  /// sichtbar, z. B. ausgeblendet).
  String? _drawTruck;
  String? _drawShip;
  LatLng? _drawTruckAt;
  LatLng? _drawShipAt;

  /// Ist [icon] auf [layer] gezeichnet – oder liegt das Fahrzeug außerhalb
  /// des Bildes (Übersicht: die Kamera schwenkt vom Lkw weg), sodass es
  /// nichts zu zeichnen gibt?
  bool _drawnOrOffScreen(String layer, String icon, LatLng? at) {
    final drawn = renderedIcon(layer, sameMapAs: 'truck-top');
    if (drawn == icon) return true;
    return drawn == null && at != null && !isOnScreen(at.latitude, at.longitude, sameMapAs: 'truck-top');
  }

  /// Zeigt dieses Bild genau die berechneten Fahrzeugbilder – gesetzt UND
  /// von MapLibre gezeichnet? Das Setzen der Kartendaten läuft über das
  /// Plugin asynchron; gemessen zeigte sonst fast jedes dritte Exportbild
  /// noch das Fahrzeugbild des Vorbilds. Deshalb wird das gezeichnete
  /// Symbol selbst abgefragt.
  bool get _exportFrameExact =>
      (_wantedFrame == null || _shownFrame == _wantedFrame) &&
      (_wantedShip == null || _shownShip == _wantedShip) &&
      (!kIsWeb || _drawTruck == null || _drawnOrOffScreen('truck-upright', _drawTruck!, _drawTruckAt)) &&
      (!kIsWeb || _drawShip == null || _drawnOrOffScreen('ship-upright', _drawShip!, _drawShipAt));

  /// Videoexport: Ist ein Fahrzeugbild fertig und zeigt das aktuelle Bild
  /// noch einen Ersatz, das Fahrzeug für DASSELBE Bild neu setzen – Kamera
  /// und Zeit bleiben stehen. Erst dann meldet pending() 0; das Setzen der
  /// Kartendaten lässt MapLibre sofort „nicht geladen“ melden, bis es
  /// gezeichnet ist (darauf wartet die Aufnahme ebenfalls).
  void _afterSpriteReady() {
    if (widget.frameDt == null || !_ready || !mounted || _exportFrameExact) return;
    final map = _map;
    if (map == null) return;
    _exportRefreshes++;
    _updateVehicle(map, widget.position);
  }

  /// Fahrzeug (Lkw/Licht/Fähre) für die aktuelle Stelle setzen. Hängt nur
  /// von Position und Kamera ab – ein erneuter Aufruf für dasselbe Bild
  /// bewegt nichts weiter (Videoexport, siehe [_exportFrameExact]).
  void _updateVehicle(ml.MapLibreMapController map, TourPosition pos) {
    _wantedFrame = null;
    _wantedShip = null;
    _drawTruck = null;
    _drawShip = null;
    if (widget.truckView == TruckView.articulated && !_endOverview) {
      // Fähre: LKW hält am Hafen und blendet aus, die Fähre übernimmt – und
      // am Zielhafen umgekehrt. Ohne Fähre ist mix null und alles wie bisher.
      final mix = _mix = _crossings.isEmpty ? null : vehicleAt(widget.path, _crossings, pos.meters);
      final truckPos = mix == null || mix.truckMeters == pos.meters ? pos : widget.path.at(mix.truckMeters);
      // Mit freigestelltem Hero-Bild: Modell gleichzeitig ausblenden.
      final cutFade = widget.heroCutout != null && _inOutro ? widget.outroTimeline!.photo(widget.outroTime!) : 0.0;
      final truckOp = (mix?.truck ?? 1.0) * (1 - cutFade);
      final props = _articulatedProps(truckPos);
      final pose = _pose!;
      // Vorschau im Browser: aufrechter Lkw im Fahrzeug-Overlay statt als
      // Kartensymbol (jede Positionsänderung baute sonst die Kacheln samt
      // Bildatlas neu – gemessen > 99 % der neu angelegten WebGL-Texturen).
      final overlayTruck = _overlayOn && props != null;
      if (!overlayTruck) {
        map.setGeoJsonSource('truck', _collection([
          if (truckOp > 0.001)
            props == null
                ? _point(truckPos.point, {
                    'icon': 'truck-top', 'rot': pose.tractorHeading, 'flat': true, 'size': 0.3,
                    if (mix != null) 'op': truckOp,
                  })
                : _point(pose.kingpin, {...props, if (mix != null || cutFade > 0) 'op': truckOp}),
        ]));
        _truckInMap = true;
      } else if (_truckInMap) {
        map.setGeoJsonSource('truck', _collection(const []));
        _truckInMap = false;
      }
      ({String img, double lat, double lng, double size, double rot, double op})? overlayTruckState;
      ({String img, double lat, double lng, double heading, double size, double op})? overlayCone;
      if (overlayTruck && truckOp > 0.001) {
        overlayTruckState = (
          img: props['icon'] as String,
          lat: pose.kingpin.latitude,
          lng: pose.kingpin.longitude,
          size: (props['size'] as num).toDouble(),
          rot: (props['rot'] as num).toDouble(),
          op: truckOp,
        );
      }
      if (truckOp > 0.001 && props != null) {
        _drawTruck = props['icon'] as String;
        _drawTruckAt = pose.kingpin;
      }
      if (_shownCone > 0.01) {
        // Abblendlicht ab der Kabinenfront, headlightConeMeters Fahrzeugmeter
        // lang, gedreht mit der Zugmaschine; wächst wie der LKW mit dem
        // Kamerazoom.
        final unit = _unitAt(truckPos.point);
        final light = headlightPlacement(pose, metersPerUnit: unit);
        final scale = math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
        final coneSize = headlightConeMeters * _pointsPerMeter * scale / headlightConeSize.height;
        if (_overlayOn) {
          // Deckkraft wie die Kartenebene: Nachtstufe × Überblendung.
          if (truckOp > 0.001) {
            overlayCone = (
              img: 'headlights',
              lat: light.apex.latitude,
              lng: light.apex.longitude,
              heading: light.heading,
              size: coneSize.toDouble(),
              op: _shownCone * (mix != null ? truckOp : 1.0),
            );
          }
        } else {
          map.setGeoJsonSource('lights', _collection([
            if (truckOp > 0.001)
              _point(light.apex, {'rot': light.heading, 'size': coneSize, if (mix != null) 'op': truckOp}),
          ]));
        }
      }
      if (_overlayOn) vehicleOverlaySet(truck: overlayTruckState, cone: overlayCone);
      _updateShip(map, mix);
    } else {
      map.setGeoJsonSource('truck', _collection([_point(pos.point, _truckProps(_localHeading(pos.meters)))]));
      if (_overlayOn) vehicleOverlaySet();
    }
  }

  /// Fähre an ihrer Stelle: Bild nach Kurs zur Blickrichtung, Neigung und
  /// Nachtstufe (bei Bedarf erzeugt und behalten), Größe wie der LKW über
  /// den Kamerazoom.
  void _updateShip(ml.MapLibreMapController map, VehicleMix? mix) {
    if (mix == null || mix.ship <= 0.001) {
      if (_shipVisible) {
        _shipVisible = false;
        map.setGeoJsonSource('ship', _collection(const []));
      }
      return;
    }
    final heading = shipHeading(widget.path, mix.crossing!, mix.shipMeters);
    _shipYawFrame = frameFor(angleDiff(_cameraBearing, heading), _shipYawFrame, step: 4);
    final pitch = ((_cameraPitch / 5).round() * 5).clamp(20, 60);
    final night = nightStep(_night);
    final name = 'ship-p$pitch-y$_shipYawFrame-n${(night * 8).round()}';
    if (!_framesReady.contains(name) && !_framesPending.contains(name)) {
      _framesPending.add(name);
      final yaw = _shipYawFrame * 4.0;
      _addSprite(name, () => ferryShipPng(yawDeg: yaw, pitchDeg: pitch.toDouble(), night: night)).then((_) {
        _framesPending.remove(name);
        _framesReady.add(name);
        _keepSprite(name);
        _afterSpriteReady();
      });
    }
    _wantedShip = name;
    if (_framesReady.contains(name)) _shownShip = name;
    final shown = _shownShip;
    if (shown == null) return;
    _touchSprite(shown);
    final size = shipPointsPerMeter(_pointsPerMeter, FerryShipModel.length) /
        shipSpritePx *
        math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
    _shipVisible = true;
    _drawShip = shown;
    _drawShipAt = widget.path.at(mix.shipMeters).point;
    map.setGeoJsonSource('ship', _collection([
      _point(widget.path.at(mix.shipMeters).point, {'icon': shown, 'size': size, 'op': mix.ship}),
    ]));
  }

  Map<String, dynamic> _truckProps(double heading) {
    final relative = angleDiff(_cameraBearing, heading); // zur Blickrichtung
    if (_endOverview) {
      // Übersicht von oben am Ziel: flach.
      return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3};
    }
    switch (widget.truckView) {
      case TruckView.articulated:
        // Wird über [_articulatedProps] gesetzt (eigener Ankerpunkt).
        return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3};
      case TruckView.top:
        return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3}; // Kartenrichtung
      case TruckView.threeQuarterLeft:
      case TruckView.threeQuarterRight:
      case TruckView.threeQuarterAuto:
        final TruckSide side;
        if (widget.truckView == TruckView.threeQuarterAuto) {
          side = _sideChooser.update(relative, _dt);
        } else {
          side = widget.truckView == TruckView.threeQuarterLeft ? TruckSide.left : TruckSide.right;
        }
        final target = biasFor(side, widget.truckBias);
        _bias = _bias == null ? target : easeBias(_bias!, target, _dt);
        _frame = frameFor(relative + _bias!, _frame, step: _frameStep);
        _ensureFrame(_frame);
        final name = _frameName(_frame);
        if (_framesReady.contains(name)) _shownFrame = name;
        // Solange das neue Bild entsteht, bleibt das vorige stehen.
        final icon = _shownFrame ?? 'truck-top';
        return {
          'icon': icon,
          'rot': _shownFrame == null ? heading : 0.0,
          'flat': _shownFrame == null,
          'size': _shownFrame == null ? 0.3 : 0.5 * widget.truckScale,
        };
      case TruckView.rear:
        // Fährt die Kamera hinterher (Regelfall), zeigt sie das Heck; leichte
        // Neigung in Kurven. Bei starker Abweichung seitlich.
        if (relative.abs() <= 50) {
          return {'icon': 'truck-rear', 'rot': relative * 0.35, 'flat': false, 'size': 0.32};
        }
        continue side;
      side:
      case TruckView.side:
        final pose = truckPose(relative);
        return {
          'icon': pose.mirrored ? 'truck-mirrored' : 'truck',
          'rot': pose.radians * 180 / math.pi,
          'flat': false,
          'size': 0.55,
        };
    }
  }

  // ------------------------------------------------------ Ebenen-Eigenschaften
  //
  // Immer VOLLSTÄNDIG übergeben: maplibre_gl schickt bei setLayerProperties
  // alle nicht gesetzten Eigenschaften als null mit und setzt sie damit auf
  // den Standard zurück (Bild, Größe, Farbe …). Nur die Deckkraft zu setzen,
  // hatte Lichtkegel, Länderfarbe und Nachtblau gelöscht.

  double _shownGlow = -1;

  static ml.FillLayerProperties _outroVeilProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#06120C', fillOpacity: opacity);

  static ml.FillLayerProperties _veilProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#0B1730', fillOpacity: opacity);

  static ml.FillLayerProperties _countryFillProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#1565C0', fillOpacity: opacity);

  static ml.LineLayerProperties _countryLineProps(double opacity) =>
      ml.LineLayerProperties(lineColor: '#1565C0', lineWidth: 2, lineOpacity: opacity);

  /// Lichtkegel: flach auf der Straße, gedreht mit der Zugmaschine.
  static ml.SymbolLayerProperties _coneProps(double opacity) => ml.SymbolLayerProperties(
        iconImage: 'headlights',
        iconSize: ['get', 'size'],
        iconRotate: ['get', 'rot'],
        iconRotationAlignment: 'map',
        iconPitchAlignment: 'map',
        iconAnchor: 'bottom',
        // Mit dem LKW ausgeblendet, wenn er am Hafen der Fähre Platz macht.
        iconOpacity: ['*', opacity, ['coalesce', ['get', 'op'], 1]],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      );

  Map<String, dynamic> _point(LatLng p, Map<String, dynamic> props) => {
        'type': 'Feature',
        'properties': props,
        'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
      };

  @override
  void didUpdateWidget(TourAnimationSceneMapLibre old) {
    super.didUpdateWidget(old);
    if (widget.position.meters < old.position.meters - 1) {
      _rig.reset(); // Neustart
      _cam?.reset();
      _daylight.reset();
      _overviewShown = false;
      _outroCam = null;
      _outroPrewarmed = false;
      _prewarmQueue.clear();
      _outroPlanned.clear();
      _driveReleased = false;
      _outroMissFrames = 0;
      _outroUnplanned = 0;
      _outroLate.clear();
    }
    _update();
  }

  void _update({bool force = false}) {
    final map = _map;
    if (!_ready || map == null) return;
    final now = DateTime.now();
    final fixed = widget.frameDt;
    final dt = fixed != null
        ? (_lastFrame == null ? Duration.zero : fixed)
        : (_lastFrame == null ? Duration.zero : now.difference(_lastFrame!));
    _lastFrame = now;
    _dt = dt;
    final pos = widget.position;

    // Kamera: ruhig in Fahrtrichtung, am Ziel Übersicht von oben – oder
    // das Cinematic-Outro.
    if (!_inOutro) _outroCam = null;
    // Outro-Bilder vorbereiten: schon beim Heranfahren ans Ziel (letzte
    // ≈ 5 % der Strecke), je Bild höchstens eines.
    // Profil: höchstens so viele je Sekunde (über den Zielanflug verteilt).
    final prewarmRate = widget.quality.outroPrewarmPerSecond;
    if (_prewarmQueue.isNotEmpty &&
        _framesPending.isEmpty &&
        (prewarmRate == null || now.difference(_lastPrewarm).inMicroseconds >= 1e6 / prewarmRate)) {
      _lastPrewarm = now;
      final (y, k, p, n, l) = _prewarmQueue.removeAt(0);
      _requestArticulated(y, k, p, n, l);
    }
    final outroTl = widget.outroTimeline;
    if (widget.outro != null && outroTl != null && !_outroPrewarmed &&
        (_inOutro || pos.meters >= widget.path.totalMeters * 0.95)) {
      _outroPrewarmed = true;
      final end = widget.path.totalMeters;
      _prewarmOutro(_makeOutroCamera(outroTl), outroTl,
          _poseAt(end));
      // Profil: nicht mehr benötigte Fahrbilder schon jetzt freigeben.
      _trimSprites();
    }
    if (_inOutro) {
      final tl = widget.outroTimeline!;
      final t = widget.outroTime!;
      _outroLights = OutroLights.at(tl, t, sweepSteps: widget.quality.outroSweepSteps);
      _releaseDriveSprites();
      final oc = _outroCam ??= _makeOutroCamera(tl);
      final glow = 0.7 * tl.routeGlow(t);
      if ((glow - _shownGlowRoute).abs() > 0.01 || (glow == 0 && _shownGlowRoute != 0)) {
        _shownGlowRoute = glow;
        map.setLayerProperties('driven-glow', _drivenGlowProps(glow));
      }
      final st = _camState = oc.at(t);
      _cameraBearing = st.bearing;
      _cameraZoom = st.zoom;
      _cameraPitch = st.pitch;
      map.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(
        target: _ml(st.target),
        zoom: st.zoom,
        bearing: st.bearing,
        tilt: st.pitch,
      )));
      // Nachts ist es schon dunkel – dann weniger zusätzlich abdunkeln.
      final veil = 0.42 * tl.dim(t) * (1 - 0.6 * _night);
      if ((veil - _shownOutroVeil).abs() > 0.004) {
        _shownOutroVeil = veil;
        map.setLayerProperties('outro-veil', _outroVeilProps(veil));
      }
    } else if (_endOverview) {
      if (!_overviewShown) {
        _overviewShown = true;
        final pts = widget.path.points;
        var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
        for (final p in pts) {
          s = math.min(s, p.latitude);
          n = math.max(n, p.latitude);
          w = math.min(w, p.longitude);
          e = math.max(e, p.longitude);
        }
        map.moveCamera(ml.CameraUpdate.tiltTo(0));
        map.moveCamera(ml.CameraUpdate.bearingTo(0));
        _cameraBearing = 0;
        map.animateCamera(
          ml.CameraUpdate.newLatLngBounds(
            ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e)),
            left: 60, top: 140, right: 60, bottom: 260,
          ),
          duration: const Duration(milliseconds: 1600),
        );
      }
    } else {
      // Regie: Folgekamera plus festgelegte Fahrten um den LKW – alles relativ
      // zur aktuellen Fahrzeugposition; manueller Zoom schaltet sie ab.
      final cam = _cam ?? _cameraFor(const Size(1000, 700));
      final st = _camState = cam.step(pos.meters, dt, manualZoom: widget.manualZoom);
      _cameraBearing = st.bearing;
      _cameraZoom = st.zoom;
      _cameraPitch = st.pitch;
      map.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(
        target: _ml(st.target),
        zoom: st.zoom,
        bearing: st.bearing,
        tilt: st.pitch,
      )));
    }

    // Tag/Nacht: Sonnenstand an der Fahrzeugposition zur Planzeit (lokal).
    if (widget.dayNight != DayNightMode.off) {
      final p = widget.path.totalMeters <= 0 ? 0.0 : pos.meters / widget.path.totalMeters;
      final DateTime? when = switch (widget.dayNight) {
        DayNightMode.plan => _clock?.at(pos.meters).toUtc(),
        DayNightMode.simulated =>
          DateTime.utc(2026, 10, 5, 13).add(Duration(minutes: (24 * 60 * p).round())),
        DayNightMode.off => null,
      };
      final target = when == null ? 0.0 : nightLevel(sunElevation(pos.point.latitude, pos.point.longitude, when));
      _night = _endOverview ? 0 : _daylight.update(target, dt);
      if ((_night - _shownVeil).abs() > 0.004) {
        _shownVeil = _night;
        map.setLayerProperties('night-veil', _veilProps(0.55 * _night));
      }
    }
    // Lichtkegel: nachts nach Dunkelheit, im Outro zusätzlich mit dem
    // Einschalten der Scheinwerfer.
    final cone = math.max(widget.dayNight == DayNightMode.off ? 0.0 : headlightOpacity(_night),
        _inOutro ? 0.85 * widget.outroTimeline!.headLights(widget.outroTime!) : 0.0);
    if ((cone - _shownCone).abs() > 0.004) {
      _shownCone = cone;
      map.setLayerProperties('headlight-cone', _coneProps(cone));
    }

    _updateVehicle(map, pos);

    // Gefahrene Spur: höchstens etwa 12-mal pro Sekunde neu.
    if (force || widget.finished || fixed != null || now.difference(_lastTrail).inMilliseconds > 80) {
      _lastTrail = now;
      // Cinematic: die Spur endet an der Achsgruppe des Aufliegers – der
      // Sattelzug zieht die Linie hinter sich her.
      final pose = _pose;
      final heading = widget.cinematicHeading;
      if (heading != null && heading.rearOnRoute && pose != null && _mix?.crossing == null) {
        // Heck klebt auf der (geglätteten) Darstellungslinie: die Spur ist
        // genau diese Linie bis zum Heck – im Outro die ganze Strecke.
        final u = _unitAt(pos.point);
        final dp = heading.displayPath;
        final upTo = _inOutro ? dp.totalMeters : heading.rearMetersAt(pos.meters, pose.kingpin, u);
        map.setGeoJsonSource('driven', _collection([
          for (final t in dp.trailUpTo(upTo)) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
        ]));
      } else if (widget.cinematicHeading != null && cinematicTrailRearDefine && pose != null && _mix?.crossing == null) {
        final u = _unitAt(pos.point);
        final back = (pos.meters - 14.0 * u).clamp(0.0, widget.path.totalMeters);
        final features = _drivenFeatures(widget.path.at(back));
        if (features.isNotEmpty) {
          final last = features.last;
          final coords = (last['geometry'] as Map)['coordinates'] as List;
          coords.add([pose.trailerAxle.longitude, pose.trailerAxle.latitude]);
        }
        map.setGeoJsonSource('driven', _collection(features));
      } else {
        map.setGeoJsonSource('driven', _collection(_drivenFeatures(pos)));
      }
    }

    // Länder-Hervorhebung beim Grenzübertritt.
    final e = widget.frame.event;
    final iso = e?.kind == TourStoryKind.borderCrossing ? e!.toIso : null;
    if (iso != _highlightIso) {
      _highlightIso = iso;
      final shape = iso == null ? null : widget.countries?.byIso(iso);
      map.setGeoJsonSource('country', _collection([
        if (shape != null)
          {
            'type': 'Feature',
            'properties': const <String, dynamic>{},
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                for (final rings in shape.polygons)
                  [
                    for (final ring in rings)
                      [for (final p in [...ring, ring.first]) [p.longitude, p.latitude]],
                  ],
              ],
            },
          },
      ]));
    }
    final glow = iso == null ? 0.0 : storyFade(widget.frame.eventProgress);
    if ((glow - _shownGlow).abs() > 0.004 || (glow == 0 && _shownGlow != 0)) {
      _shownGlow = glow;
      map.setLayerProperties('country-fill', _countryFillProps(0.16 * glow));
      map.setLayerProperties('country-line', _countryLineProps(0.75 * glow));
    }
    _diagnose(pos, now);
    // Videoexport: dieses Bild ist übernommen (Kamera, Fahrzeug, Spur).
    final frameNo = widget.exportFrame;
    if (frameNo != null) widget.onExportFrameApplied?.call(frameNo);
  }

  @override
  void dispose() {
    if (_overlayOn) vehicleOverlayDetach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _cameraFor(MediaQuery.sizeOf(context));
    final path = widget.path;
    final pos = widget.position;
    final frame = widget.frame;
    final progress = path.totalMeters <= 0 ? 0.0 : pos.meters / path.totalMeters;
    final planKm = widget.planKm;
    final km = planKm == null
        ? tourKmLabel(pos.roadMeters, path.roadMeters)
        : tourKmLabel(planKmAt(path, pos.meters, planKm) * 1000, planKm * 1000);
    final startIso = widget.summary?.startIso ?? widget.countries?.countryAt(path.start);
    final arrivalFade = frame.event?.kind == TourStoryKind.arrival
        ? (frame.eventProgress / 0.2).clamp(0.0, 1.0)
        : 0.0;

    return Stack(children: [
      Positioned.fill(
        child: FutureBuilder<String>(
          future: _style,
          builder: (context, snap) {
            if (snap.hasError) {
              final fallback = widget.onUnavailable;
              if (fallback != null) WidgetsBinding.instance.addPostFrameCallback((_) => fallback());
              return const Center(child: Text('Kartenstil nicht erreichbar (OpenFreeMap).'));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ml.MapLibreMap(
              styleString: snap.data!,
              initialCameraPosition: ml.CameraPosition(
                target: _ml(_rig.targetAt(pos.meters)),
                zoom: _rig.zoom,
                bearing: _rig.headingAt(pos.meters),
                tilt: _rig.pitch,
              ),
              onMapCreated: (c) => _map = c,
              onStyleLoadedCallback: _onStyleLoaded,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              scrollGesturesEnabled: false,
              zoomGesturesEnabled: false,
              doubleClickZoomEnabled: false,
              compassEnabled: false,
              attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
            );
          },
        ),
      ),
      Positioned.fill(
        child: TourStoryOverlay(
          // Mit Outro ersetzt das Finale die bisherige Abschlusskarte.
          frame: widget.outro != null && frame.event?.kind == TourStoryKind.arrival
              ? TourFrame(meters: frame.meters)
              : frame,
          summary: widget.summary,
          fromName: widget.fromName,
          toName: widget.toName,
          countrySequence: storyCountrySequence(widget.storyEvents, startIso),
        ),
      ),
      if (_inOutro)
        Positioned.fill(
          child: TourOutroOverlay(
              data: widget.outro!,
              timeline: widget.outroTimeline!,
              t: widget.outroTime!,
              heroPhoto: widget.heroPhoto,
              heroCutout: widget.heroCutout),
        ),
      if (widget.cameraDebug && _camState != null)
        Positioned(
          left: 12,
          bottom: 40,
          child: IgnorePointer(
            child: Container(
              key: const Key('camera-debug'),
              padding: const EdgeInsets.all(8),
              color: const Color(0xCC000000),
              child: Text(
                'Shot ${_camState!.shot}\n'
                'Bahn ${_camState!.orbit.toStringAsFixed(0)}°  Richtung ${_camState!.bearing.toStringAsFixed(0)}°\n'
                'Neigung ${_camState!.pitch.toStringAsFixed(0)}°  Zoom ${_camState!.zoom.toStringAsFixed(2)}\n'
                'Knick ${(_pose?.knick ?? 0).toStringAsFixed(1)}°  Nacht ${(_night * 100).round()} %'
                '${_mix == null ? '' : '\nFähre ${(_mix!.ship * 100).round()} %'}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      Positioned(
        left: 12,
        right: 12,
        // Export: Sicherheitsabstand oben (Player-Leisten, Social-Media-UI).
        top: widget.frameDt != null ? MediaQuery.sizeOf(context).height * 0.065 : 12,
        child: Opacity(
          opacity: 1 - arrivalFade,
          child: TourStoryHud(
            title: widget.title,
            km: km,
            progress: progress,
            frame: frame,
            events: widget.storyEvents,
            startIso: startIso,
          ),
        ),
      ),
    ]);
  }
}
