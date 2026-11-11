import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../animation/cinematic_camera.dart';
import '../animation/cinematic_quality.dart';
import '../animation/country_borders.dart';
import '../animation/daylight.dart';
import '../animation/tour_path.dart';
import '../animation/tour_motion.dart';
import '../animation/tour_outro.dart';
import '../animation/tour_playback.dart';
import '../animation/tour_story.dart';
import '../logic/eta_calculator.dart';
import '../export/export_hook.dart';
import 'device_hint.dart';
import 'screen_wake_lock.dart';
import 'tour_outro_overlay.dart' show buildOutroData;
import 'tour_story_overlay.dart';
import 'tour_animation_scene_maplibre.dart';
import 'truck_sprites.dart';

final NumberFormat _km = NumberFormat.decimalPattern('de');

/// Kilometerangabe wie „742 / 1.026 km“.
String tourKmLabel(double roadMeters, double totalRoadMeters) =>
    '${_km.format((roadMeters / 1000).round())} / '
    '${_km.format((totalRoadMeters / 1000).round())} km';

/// Eigene Ansicht „Tour animieren“: Szene plus schlichte Bedienung.
///
/// Zeigt nur, was die Berechnung schon geliefert hat ([TourPath]); es gibt
/// keinen Aufruf bei Google oder einem anderen Routing-Dienst.
class TourAnimationView extends StatefulWidget {
  const TourAnimationView({
    super.key,
    required this.path,
    required this.title,
    this.stops = const [],
    this.autoplay = true,
    this.showTiles = true,
    this.mapController,
    this.eta,
    this.countries,
    this.storyMode = TourStoryMode.cinematic,
    this.fromName,
    this.toName,
    this.startIn25D = false,
    this.truckView = TruckView.top,
    this.truckModel = const TruckModel(),
    this.truckBias = 22,
    this.truckPitch = 42,
    this.truckScale = 1,
    this.cameraMode = CameraMode.follow,
    this.cinematicDemo = false,
    this.cameraDebug = false,
    this.dayNight = DayNightMode.off,
    this.videoExport = false,
    this.heroPhoto,
    this.heroCutout,
    this.quality,
    this.cleanRecording = false,
    this.onPlaybackStarted,
    this.onPlaybackFinished,
    this.closeRequest,
  });

  /// Sauberer Aufnahmemodus für die Live-Aufnahme im Browser: dieselbe
  /// Filmregie in Echtzeit (1×), aber ohne jedes Bedienelement – keine
  /// App-Leiste, kein Schließen, kein 2D/2.5D-Umschalter, keine Steuer- oder
  /// Zoomleiste. Karte, HUD, Story, Outro und Kartenquellenangabe bleiben.
  /// Verlassen nur über die Browsernavigation oder [closeRequest].
  final bool cleanRecording;

  /// Einmalig: Die Fahrt läuft tatsächlich los (nach dem Laden der Karte).
  final VoidCallback? onPlaybackStarted;

  /// Einmalig: Der Film ist vollständig zu Ende (einschließlich Outro).
  final VoidCallback? onPlaybackFinished;

  /// Wird es true, schließt sich die Ansicht selbst.
  final ValueListenable<bool>? closeRequest;

  /// Vorschauqualität der 2.5D-Tour; null: automatisch (Touch-Gerät →
  /// Performance, sonst hoch). Der Videoexport nutzt immer
  /// [CinematicQuality.exportFullHD] – unabhängig von diesem Wert.
  final CinematicQuality? quality;

  /// Test/Export: freigestellter Hero-Lkw (URL), sonst null.
  final String? heroCutout;

  /// Test/Export: echtes Foto des Lkw fürs Outro (URL), sonst null.
  final String? heroPhoto;

  /// Renderzustand für den Videoexport: nur filmische Bestandteile (Karte,
  /// Route, Fahrzeug, Licht, Fahrleiste, Outro) – keine Bedienelemente,
  /// kein Debug. Die Zeit läuft nicht von selbst, sondern Bild für Bild im
  /// festen Takt ([exportFrameRate]) über `window.drivetimeExport.step()`.
  final bool videoExport;

  static const int exportFrameRate = 30;

  /// EXPERIMENT: Kamera-Regie und Tag/Nacht in 2.5D.
  final CameraMode cameraMode;
  final bool cinematicDemo;
  final bool cameraDebug;
  final DayNightMode dayNight;

  /// EXPERIMENT: Fahrzeug (Typ + Branding) und 3/4-Darstellung.
  final TruckModel truckModel;
  final double truckBias;
  final double truckPitch;
  final double truckScale;

  /// EXPERIMENT: Fahrzeugansicht in 2.5D (Vergleich auf der Demo-Seite).
  final TruckView truckView;

  /// EXPERIMENT: direkt in der MapLibre-2.5D-Ansicht starten (Demo-Seite).
  final bool startIn25D;

  final TourPath path;

  /// Darstellung der Story; Standard: fließend, Details am Ziel.
  final TourStoryMode storyMode;

  /// Start und Ziel für die Abschlusskarte, etwa „Lambach“ und „Hamburg“.
  final String? fromName;
  final String? toName;

  /// Planung der Berechnung: Lenkpausen, Ruhezeiten, Ziel, Kilometer.
  final EtaResult? eta;

  /// Ländergrenzen für Grenzübertritte; erst beim Öffnen geladen.
  final Future<CountryIndex>? countries;

  /// Etwa „Lambach → Hamburg“.
  final String title;
  final List<LatLng> stops;
  final bool autoplay;

  /// Nur für Tests abschaltbar: Kartenkacheln laden.
  final bool showTiles;

  /// Nur für Tests: die Kamera beobachten.
  @visibleForTesting
  final MapController? mapController;

  @override
  State<TourAnimationView> createState() => _TourAnimationViewState();
}

class _TourAnimationViewState extends State<TourAnimationView>
    with SingleTickerProviderStateMixin {
  /// Renderprofil: Film immer volle Qualität, Vorschau nach Gerät oder Wahl.
  late final CinematicQuality _quality = widget.videoExport
      ? CinematicQuality.exportFullHD
      : widget.quality ?? CinematicQuality.choose(videoExport: false, touchDevice: isTouchDevice());

  late TourTimeline _timeline;
  late TourPlayback _playback;
  CountryIndex? _countries;
  TourSummary? _summary;

  /// Kilometer laut Planung (für Anzeige); null ohne Planung.
  late final double? _planKm = () {
    final eta = widget.eta;
    if (eta == null) return null;
    final km = etaDriveKm(eta);
    return km > 0 ? km : null;
  }();

  /// Ländergrenzen werden noch geladen.
  bool _preparing = false;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// Vom Nutzer gewählte Zoomstufe; null = automatische Kameraführung.
  double? _manualZoom;

  /// EXPERIMENT: 2.5D mit MapLibre statt 2D mit flutter_map.
  late bool _maplibre = widget.startIn25D;

  /// 2.5D: Fahrt wartet, bis die MapLibre-Karte geladen ist.
  bool _waitForMap = false;

  // ------------------------------------------------ Cinematic-Outro (2.5D)

  /// Das Finale gibt es nur in der 2.5D-Cinematic-Ansicht; 2D behält die
  /// bisherige Abschlusskarte.
  bool get _outroEnabled =>
      _maplibre &&
      widget.cameraMode == CameraMode.cinematic &&
      widget.truckView == TruckView.articulated &&
      widget.storyMode == TourStoryMode.cinematic;

  OutroData? _outroData;

  /// Sichtbare Fahrzeuggröße; per CINEMATIC_TRUCK_SCALE nur zum Vergleich
  /// veränderbar (Standard 100 %).
  double get _truckScale =>
      widget.truckScale * cinematicTruckScaleDefine / 100 * (_cinematicEnabled ? cinematicDriveScale : 1);

  bool get _cinematicEnabled =>
      widget.cameraMode == CameraMode.cinematic &&
      widget.truckView == TruckView.articulated &&
      widget.storyMode == TourStoryMode.cinematic;

  /// Dunkelheit an einer Stelle der Tour (für den Kamera-Rhythmus), wie die
  /// Szene sie berechnet; ohne Tag/Nacht null.
  double Function(double meters)? get _nightAt {
    final path = widget.path;
    switch (widget.dayNight) {
      case DayNightMode.off:
        return null;
      case DayNightMode.plan:
        final eta = widget.eta;
        final clock = eta == null ? null : TourClock.fromEta(eta, path);
        if (clock == null) return null;
        return (m) {
          final p = path.at(m).point;
          return nightLevel(sunElevation(p.latitude, p.longitude, clock.at(m).toUtc()));
        };
      case DayNightMode.simulated:
        return (m) {
          final p = path.at(m).point;
          final f = path.totalMeters <= 0 ? 0.0 : m / path.totalMeters;
          return nightLevel(sunElevation(
              p.latitude, p.longitude, DateTime.utc(2026, 10, 5, 13).add(Duration(minutes: (24 * 60 * f).round()))));
        };
    }
  }

  /// Cinematic mit gekoppeltem Sattelzug: ruhiges Filmtempo (Trägheit,
  /// langsamer in Kurven) und die darauf umgesetzte Kameraregie. Sonst null –
  /// Fahrt wie bisher.
  late final ({TourMotion motion, CinematicPlan plan, CinematicHeading? heading})? _cinematic =
      widget.cameraMode == CameraMode.cinematic &&
              widget.truckView == TruckView.articulated &&
              widget.storyMode == TourStoryMode.cinematic &&
              widget.path.totalMeters > 0
          ? cinematicMotionFor(widget.path,
              demo: widget.cinematicDemo,
              truckScale: _truckScale,
              motionTruckScale: widget.truckScale,
              nightAt: _nightAt)
          : null;
  OutroTimeline? _outroTimeline;

  /// Wiedergabedauer: Fahrt plus – in 2.5D – das Outro ab Ankunft.
  Duration get _playbackLength {
    final tl = _outroTimeline;
    if (!_outroEnabled || tl == null) return _timeline.total;
    final withOutro = _timeline.arrivalAt + tl.duration;
    return withOutro > _timeline.total ? withOutro : _timeline.total;
  }

  /// Outro-Zeit in Sekunden ab Ankunft; null vor der Ankunft oder ohne Outro.
  double? get _outroTime {
    if (!_outroEnabled || _outroTimeline == null) return null;
    final d = _playback.elapsed - _timeline.arrivalAt;
    return d.isNegative ? null : d.inMicroseconds / 1e6;
  }

  void _setRenderer(bool maplibre) {
    setState(() {
      _maplibre = maplibre;
      _playback = _playback.withDuration(_playbackLength);
      _manualZoom = null;
      if (maplibre && _playback.playing) {
        _waitForMap = true;
        _playback.pause();
        _ticker.stop();
      }
    });
  }

  /// 2.5D nicht verfügbar (Vektorkarte lädt nicht): zurück auf 2D und die
  /// Fahrt dort starten bzw. fortsetzen.
  void _onMapUnavailable() {
    if (!mounted || !_maplibre) return;
    final resume = _waitForMap;
    setState(() {
      _maplibre = false;
      _waitForMap = false;
      _playback = _playback.withDuration(_playbackLength);
    });
    if (resume) _play();
  }

  void _onMapReady() {
    if (!_waitForMap || !mounted) return;
    _waitForMap = false;
    _play();
  }
  late final double _autoZoom = tourFollowZoom(widget.path.totalMeters);

  bool _startReported = false;
  bool _finishReported = false;

  // ---------------------------------------------- Bildschirm wach halten
  // Ab dem tatsächlichen Fahrtbeginn bis Filmende/Schließen; bei Pause
  // bleibt er wach. Nicht im Bild-für-Bild-Studio-Export. Fehler oder
  // fehlende Unterstützung bleiben folgenlos.
  late final ScreenWakeLock? _wakeLock = widget.videoExport ? null : screenWakeLock();
  bool _keepAwake = false;
  AppLifecycleListener? _lifecycle;

  void _wake(bool on) {
    final lock = _wakeLock;
    if (lock == null || _keepAwake == on) return;
    _keepAwake = on;
    final Future<void> Function() call = on ? lock.acquire : lock.release;
    unawaited(Future<void>.sync(call).catchError((Object _) {}));
  }

  /// Rückkehr in den Tab/die App: der Browser hat die Sperre beim Verdecken
  /// selbst freigegeben – erneut anfordern, solange die Fahrt noch läuft.
  void _wakeAgain() {
    final lock = _wakeLock;
    if (lock == null || !_keepAwake) return;
    unawaited(Future<void>.sync(lock.acquire).catchError((Object _) {}));
  }

  /// Bedienelemente nur außerhalb von Videoexport und Live-Aufnahme.
  bool get _controlsVisible => !widget.videoExport && !widget.cleanRecording;

  /// Signal nach außen – als Microtask, nie mitten im Aufbau eines Bildes.
  void _report(VoidCallback? callback) {
    if (callback != null) scheduleMicrotask(callback);
  }

  void _reportStarted() {
    if (_startReported) return;
    _startReported = true;
    _report(widget.onPlaybackStarted);
  }

  void _reportFinished() {
    if (_finishReported || !_startReported || !_playback.finished) return;
    _finishReported = true;
    _report(widget.onPlaybackFinished);
  }

  void _onCloseRequest() {
    if (widget.closeRequest?.value != true || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      Navigator.of(context).maybePop();
    } else if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.closeRequest?.addListener(_onCloseRequest);
    if (_wakeLock != null) {
      _lifecycle = AppLifecycleListener(onShow: _wakeAgain, onResume: _wakeAgain);
    }
    // Schon vor dem Öffnen beendet (z. B. Freigabe gestoppt): nicht ohne
    // Bedienelemente stehen bleiben.
    if (widget.closeRequest?.value == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onCloseRequest());
    }
    // Sofort anlegen: erst beim Schließen angelegt, wäre es zu spät.
    _ticker = createTicker(_onTick);
    _buildStory(null);
    final countries = widget.countries;
    if (countries == null) {
      if (widget.autoplay) _autostart();
      return;
    }
    _preparing = true;
    countries.then<CountryIndex?>((c) => c, onError: (Object _) => null).then((c) {
      if (!mounted) return;
      setState(() {
        _buildStory(c);
        _preparing = false;
      });
      if (widget.autoplay) _autostart();
    });
  }

  void _autostart() {
    if (widget.videoExport) {
      // Export: die Zeit kommt Bild für Bild von außen.
      _playback.play();
      _playback.pause();
      registerExportHook(
        step: () {
          _exportFrameNo++;
          _playback.play();
          _playback.tick(_exportDt);
          _playback.pause();
          if (mounted) setState(() {});
          return _playback.elapsed.inMicroseconds / 1e6;
        },
        total: () => _playback.duration.inMicroseconds / 1e6,
        // Erst fertig, wenn die Szene genau dieses Bild übernommen hat und
        // ihr Fahrzeugbild gezeichnet ist.
        pending: () => (_exportApplied == _exportFrameNo ? 0 : 1) + (_exportPending?.call() ?? 0),
        state: () => _exportState?.call() ?? '{}',
      );
      return;
    }
    if (_maplibre) {
      _waitForMap = true; // startet in _onMapReady
    } else {
      _play();
    }
  }

  /// Ereignisse aus Planung und Grenzen; ohne beides: reine Fahrt wie bisher.
  void _buildStory(CountryIndex? countries) {
    _countries = countries;
    final path = widget.path;
    final eta = widget.eta;
    final events = <TourStoryEvent>[
      if (eta != null) ...storyFromEta(eta, path),
      if (countries != null)
        ...storyFromBorders(detectBorderCrossings(path, countries), countries, path,
            _planKm ?? path.roadMeters / 1000),
    ];
    _timeline = TourTimeline(
      path: path,
      drive: _cinematic?.motion.duration ?? tourAnimationDuration(path.totalMeters),
      events: events,
      mode: widget.storyMode,
      motion: _cinematic?.motion,
    );
    _summary = eta == null
        ? null
        : TourSummary.from(eta, _timeline.events,
            startIso: countries?.countryAt(path.start),
            endIso: countries?.countryAt(path.end));
    final outro = _outroData = buildOutroData(
      path: path,
      events: _timeline.events,
      countries: countries,
      summary: _summary,
      planKm: _planKm,
      fromName: widget.fromName,
      toName: widget.toName,
    );
    // Cinematic: erst die ganze Reise im Überblick, dann der Hero-Truck.
    _outroTimeline = OutroTimeline(countryCount: outro.countries.length, overview: _cinematic != null ? 4.4 : 0);
    _playback = TourPlayback(duration: _playbackLength);
  }

  static const _exportDt = Duration(microseconds: 1000000 ~/ TourAnimationView.exportFrameRate);

  /// Vom Szenenbild gemeldet: noch entstehende Fahrzeugbilder.
  int Function()? _exportPending;
  int _exportFrameNo = 0;
  int _exportApplied = -1;
  String Function()? _exportState;

  @override
  void dispose() {
    widget.closeRequest?.removeListener(_onCloseRequest);
    _wake(false); // Schließen, Zurück, Abbruch, Fehler
    _lifecycle?.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration now) {
    final dt = now - _last;
    _last = now;
    if (_playback.tick(dt)) setState(() {});
    if (_playback.finished) _wake(false); // Filmende
    _reportFinished();
    if (!_playback.playing) _ticker.stop();
  }

  void _startTicker() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _play() {
    if (_preparing) return;
    _playback.play();
    _startTicker();
    setState(() {});
    _reportStarted();
    _wake(true);
  }

  void _pause() {
    _playback.pause();
    _ticker.stop();
    setState(() {});
  }

  void _restart() {
    if (_preparing) return;
    _playback.restart();
    _startTicker();
    setState(() {});
    _wake(true);
  }

  void _setSpeed(double s) {
    if (widget.cleanRecording) return; // Live-Aufnahme: fest 1×
    setState(() => _playback.speed = s);
  }

  void _zoomBy(double delta) =>
      setState(() => _manualZoom = tourZoomStep(_manualZoom ?? _autoZoom, delta));

  void _setManualZoom(double zoom) =>
      setState(() => _manualZoom = zoom.clamp(tourMinZoom, tourMaxZoom));

  void _autoZoomOn() => setState(() => _manualZoom = null);

  @override
  Widget build(BuildContext context) {
    final frame = _timeline.frameAt(_playback.elapsed);
    final position = widget.path.at(frame.meters);
    return Scaffold(
      appBar: !_controlsVisible ? null : AppBar(
        // Auf dem Smartphone kürzer, damit der Umschalter Platz hat.
        title: Text(MediaQuery.sizeOf(context).width < 520 ? 'Tour' : 'Tour animieren'),
        actions: [
          if (widget.storyMode == TourStoryMode.cinematic)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<bool>(
                key: const Key('renderer-switch'),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: false, label: Text('2D')),
                  ButtonSegment(
                      value: true,
                      label: Text(MediaQuery.sizeOf(context).width < 520 ? '2.5D' : '2.5D (Test)')),
                ],
                selected: {_maplibre},
                onSelectionChanged: (s) => _setRenderer(s.first),
              ),
            ),
        ],
        leading: IconButton(
          tooltip: 'Schließen',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Stack(
        children: [
          if (_maplibre)
            Positioned.fill(
              child: TourAnimationSceneMapLibre(
                path: widget.path,
                position: position,
                title: widget.title,
                frame: frame,
                stops: widget.stops,
                finished: _playback.finished,
                manualZoom: _manualZoom,
                countries: _countries,
                planKm: _planKm,
                summary: _summary,
                fromName: widget.fromName,
                toName: widget.toName,
                storyEvents: _timeline.events,
                onReady: _onMapReady,
                onUnavailable: _onMapUnavailable,
                truckView: widget.truckView,
                truckModel: widget.truckModel,
                truckBias: widget.truckBias,
                truckPitch: widget.truckPitch,
                truckScale: _truckScale,
                cameraMode: widget.cameraMode,
                cinematicDemo: widget.cinematicDemo,
                cameraDebug: widget.cameraDebug && !widget.videoExport,
                frameDt: widget.videoExport ? _exportDt : null,
                onPendingProbe: (pending, state) {
                  _exportPending = pending;
                  _exportState = state;
                },
                heroPhoto: widget.videoExport ? widget.heroPhoto : null,
                heroCutout: widget.videoExport ? widget.heroCutout : null,
                quality: _quality,
                exportFrame: widget.videoExport ? _exportFrameNo : null,
                onExportFrameApplied: (n) => _exportApplied = n,
                dayNight: widget.dayNight,
                eta: widget.eta,
                outro: _outroEnabled ? _outroData : null,
                outroTimeline: _outroTimeline,
                outroTime: _outroTime,
                cinematicPlan: _cinematic?.plan,
                cinematicHeading: _cinematic?.heading,
              ),
            )
          else
          Positioned.fill(
            child: TourAnimationScene(
              path: widget.path,
              position: position,
              title: widget.title,
              stops: widget.stops,
              finished: _playback.finished,
              showTiles: widget.showTiles,
              manualZoom: _manualZoom,
              onManualZoom: _setManualZoom,
              mapController: widget.mapController,
              frame: frame,
              countries: _countries,
              planKm: _planKm,
              storyMode: widget.storyMode,
              summary: _summary,
              fromName: widget.fromName,
              toName: widget.toName,
              storyEvents: _timeline.events,
              vehicleColor: widget.truckModel.branding.cab,
            ),
          ),
          if (_preparing)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66FFFFFF),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('Tour wird vorbereitet …'),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          // Rechts mittig: frei von Anzeige oben und Kartenhinweis unten.
          // Im Outro ausgeblendet – das Finale gehört dem Truck.
          if (_outroTime == null && _controlsVisible)
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ZoomControls(
              auto: _manualZoom == null,
              canZoomIn: (_manualZoom ?? _autoZoom) < tourMaxZoom,
              canZoomOut: (_manualZoom ?? _autoZoom) > tourMinZoom,
              onZoomIn: () => _zoomBy(1),
              onZoomOut: () => _zoomBy(-1),
              onAuto: _autoZoomOn,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: !_controlsVisible ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_playback.playing)
                FilledButton.icon(
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                  onPressed: _pause,
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_playback.progress > 0 && !_playback.finished
                      ? 'Weiter'
                      : 'Start'),
                  onPressed: _play,
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.replay),
                label: const Text('Neustart'),
                onPressed: _restart,
              ),
              SegmentedButton<double>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('1×')),
                  ButtonSegment(value: 2, label: Text('2×')),
                  ButtonSegment(value: 4, label: Text('4×')),
                ],
                selected: {_playback.speed},
                onSelectionChanged: (s) => _setSpeed(s.first),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ein Bild der Animation: Karte, Route, gefahrene Strecke, Fahrzeug und
/// Kilometerzähler – vollständig bestimmt durch [path] und [position].
///
/// Kennt weder Uhr noch Bedienknöpfe und füllt den Platz, den es bekommt.
/// So lässt es sich später in ein 9:16- oder 16:9-Format setzen oder Bild für
/// Bild für einen Videoexport zeichnen.
class TourAnimationScene extends StatefulWidget {
  const TourAnimationScene({
    super.key,
    required this.path,
    required this.position,
    required this.title,
    this.stops = const [],
    this.finished = false,
    this.showTiles = true,
    this.manualZoom,
    this.onManualZoom,
    this.mapController,
    this.frame,
    this.countries,
    this.planKm,
    this.storyMode = TourStoryMode.cinematic,
    this.summary,
    this.fromName,
    this.toName,
    this.storyEvents = const [],
    this.vehicleColor = const Color(0xFF0D47A1),
  });

  /// Farbe des Fahrzeugsymbols (Kabinenfarbe des gewählten Brandings).
  final Color vehicleColor;

  /// Alle Story-Ereignisse (für Länderfortschritt und Fahrtag in der Leiste).
  final List<TourStoryEvent> storyEvents;
  final TourStoryMode storyMode;
  final TourSummary? summary;
  final String? fromName;
  final String? toName;

  final TourPath path;
  final TourPosition position;

  /// Story-Stand: laufendes Ereignis, Fortschritt der Einblendung.
  final TourFrame? frame;

  /// Für die Hervorhebung des neuen Landes beim Grenzübertritt.
  final CountryIndex? countries;

  /// Kilometer laut Planung für den Zähler; ohne Planung die Linie.
  final double? planKm;
  final String title;
  final List<LatLng> stops;

  /// Am Ziel: Kamera zeigt die ganze Tour.
  final bool finished;
  final bool showTiles;

  /// Feste Zoomstufe statt der automatischen; die Kamera folgt trotzdem.
  final double? manualZoom;

  /// Der Nutzer hat per Geste (Pinch, Mausrad) gezoomt.
  final ValueChanged<double>? onManualZoom;

  @visibleForTesting
  final MapController? mapController;

  @override
  State<TourAnimationScene> createState() => _TourAnimationSceneState();
}

class _TourAnimationSceneState extends State<TourAnimationScene> {
  late final MapController _map = widget.mapController ?? MapController();
  bool _ready = false;
  late final double _autoZoom = tourFollowZoom(widget.path.totalMeters);

  /// Gewählte Zoomstufe, sonst automatisch – mit leichtem Herauszoomen bei
  /// Grenze und Tagesruhe. Eine Wahl des Nutzers bleibt unangetastet.
  double _zoomOf(TourAnimationScene w) =>
      w.manualZoom ??
      (_autoZoom + storyZoomOffset(w.frame, mode: w.storyMode)).clamp(tourMinZoom, tourMaxZoom);

  double get _zoom => _zoomOf(widget);

  /// Ganze Route zum Zeichnen, einmal ausgedünnt.
  late final List<TourTrail> _full =
      widget.path.trailUpTo(widget.path.totalMeters, maxPointsPerLeg: 1500);

  @override
  void didUpdateWidget(TourAnimationScene old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    final zoomChanged = widget.manualZoom != old.manualZoom;
    final targetChanged = (_zoomOf(widget) - _zoomOf(old)).abs() > 1e-6;
    if (widget.finished) {
      // Am Ziel: automatisch die ganze Tour; manuell nur zoomen.
      if (widget.manualZoom == null && (!old.finished || zoomChanged)) {
        _map.fitCamera(_overview);
      } else if (zoomChanged) {
        _map.move(_map.camera.center, _zoom);
      }
      return;
    }
    // Unterwegs: dem Fahrzeug folgen – mit automatischer oder gewählter Zoomstufe.
    if (targetChanged || old.finished || widget.position.point != old.position.point) {
      _map.move(widget.position.point, _zoom);
    }
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (!hasGesture || (camera.zoom - _zoom).abs() < 0.01) return;
    widget.onManualZoom?.call(camera.zoom);
  }

  CameraFit get _overview {
    final pts = widget.path.points;
    final bounds = LatLngBounds(pts.first, pts.first);
    for (final p in pts) {
      bounds.extend(p);
    }
    return CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48));
  }

  static Polyline _line(TourTrail t, {required bool driven}) {
    final ferry = t.kind != TourLegKind.road;
    return Polyline(
      points: t.points,
      strokeWidth: driven ? 6 : 4,
      color: ferry
          ? (driven ? Colors.teal : Colors.teal.withValues(alpha: 0.45))
          : (driven ? const Color(0xFF1B5E20) : Colors.indigo.withValues(alpha: 0.35)),
      pattern: ferry
          ? StrokePattern.dashed(segments: const [12, 10])
          : const StrokePattern.solid(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final pos = widget.position;
    final pose = truckPose(pos.bearing);
    final progress = path.totalMeters <= 0 ? 0.0 : pos.meters / path.totalMeters;
    final driven = path.trailUpTo(pos.meters, maxPointsPerLeg: 1500);
    final frame = widget.frame;
    final event = frame?.event;
    final highlight = event?.kind == TourStoryKind.borderCrossing
        ? widget.countries?.byIso(event!.toIso!)
        : null;
    final glow = highlight == null ? 0.0 : storyFade(frame!.eventProgress);
    final startIso = widget.summary?.startIso ?? widget.countries?.countryAt(path.start);
    final arrivalFade = event?.kind == TourStoryKind.arrival
        ? (frame!.eventProgress / 0.2).clamp(0.0, 1.0)
        : 0.0;
    final planKm = widget.planKm;
    final km = planKm == null
        ? tourKmLabel(pos.roadMeters, path.roadMeters)
        : tourKmLabel(planKmAt(path, pos.meters, planKm) * 1000, planKm * 1000);

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: pos.point,
            initialZoom: _zoom,
            minZoom: tourMinZoom,
            maxZoom: tourMaxZoom,
            onPositionChanged: _onPositionChanged,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () => _ready = true,
          ),
          children: [
            if (widget.showTiles)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.mexx.driverroute.eta',
              ),
            if (highlight != null && glow > 0)
              PolygonLayer(polygons: [
                for (final rings in highlight.polygons)
                  Polygon(
                    points: rings.first,
                    holePointsList: rings.length > 1 ? rings.sublist(1) : null,
                    color: const Color(0xFF1565C0).withValues(alpha: 0.16 * glow),
                    borderColor: const Color(0xFF1565C0).withValues(alpha: 0.75 * glow),
                    borderStrokeWidth: 2,
                  ),
              ]),
            PolylineLayer(polylines: [
              for (final t in _full) _line(t, driven: false),
              for (final t in driven) _line(t, driven: true),
            ]),
            MarkerLayer(markers: [
              Marker(
                point: path.start,
                width: 40,
                height: 40,
                child: const Icon(Icons.trip_origin, size: 26, color: Colors.green),
              ),
              for (final s in widget.stops)
                Marker(
                  point: s,
                  width: 30,
                  height: 30,
                  child: const Icon(Icons.circle, size: 14, color: Colors.indigo),
                ),
              Marker(
                point: path.end,
                width: 44,
                height: 44,
                child: const Icon(Icons.location_pin, size: 34, color: Colors.red),
              ),
              Marker(
                key: const Key('tour-vehicle'),
                point: pos.point,
                width: 48,
                height: 48,
                child: Transform.rotate(
                  angle: pose.radians,
                  child: Transform.flip(
                    flipX: pose.mirrored,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black26)],
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.local_shipping,
                          size: 28, color: widget.vehicleColor),
                    ),
                  ),
                ),
              ),
            ]),
            const RichAttributionWidget(
              attributions: [TextSourceAttribution('OpenStreetMap-Mitwirkende')],
            ),
          ],
        ),
        if (frame != null)
          Positioned.fill(
            child: TourStoryOverlay(
              frame: frame,
              mode: widget.storyMode,
              summary: widget.summary,
              fromName: widget.fromName,
              toName: widget.toName,
              countrySequence: storyCountrySequence(widget.storyEvents, startIso),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: widget.storyMode == TourStoryMode.cinematic && frame != null
              // Am Ziel weicht die kleine Fahrleiste der Abschlussdarstellung.
              ? Opacity(
                  opacity: 1 - arrivalFade,
                  child: TourStoryHud(
                    title: widget.title,
                    km: km,
                    progress: progress,
                    frame: frame,
                    events: widget.storyEvents,
                    startIso: startIso,
                  ),
                )
              : _Hud(
                  title: widget.title,
                  km: km,
                  progress: progress,
                ),
        ),
      ],
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({required this.title, required this.km, required this.progress});

  final String title;
  final String km;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('🚛 $km',
                    key: const Key('tour-km'), style: theme.textTheme.bodyLarge),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const Key('tour-progress'),
                  value: progress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// − / + und „Auto“ – groß genug zum Antippen auf Smartphone und Tablet.
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.auto,
    required this.canZoomIn,
    required this.canZoomOut,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onAuto,
  });

  final bool auto;
  final bool canZoomIn;
  final bool canZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onAuto;

  @override
  Widget build(BuildContext context) {
    const size = Size(48, 48);
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Näher heran',
              constraints: BoxConstraints.tight(size),
              icon: const Icon(Icons.add),
              onPressed: canZoomIn ? onZoomIn : null,
            ),
            IconButton(
              tooltip: 'Weiter weg',
              constraints: BoxConstraints.tight(size),
              icon: const Icon(Icons.remove),
              onPressed: canZoomOut ? onZoomOut : null,
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 56,
              height: 40,
              child: auto
                  ? FilledButton(
                      key: const Key('tour-zoom-auto'),
                      style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: onAuto,
                      child: const Text('Auto'),
                    )
                  : OutlinedButton(
                      key: const Key('tour-zoom-auto'),
                      style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: onAuto,
                      child: const Text('Auto'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
