/// Ablaufsteuerung der Tour-Animation – reine Rechnung, ohne Uhr.
///
/// Die Zeit kommt von außen über [tick]: in der App vom Bildschirmtakt, in
/// Tests oder einem späteren Videoexport Bild für Bild mit festem Abstand.
/// Dadurch ist jeder Stand reproduzierbar.
class TourPlayback {
  TourPlayback({required this.duration})
      : assert(duration > Duration.zero, 'Dauer muss positiv sein');

  /// Dauer bei Tempo 1×.
  final Duration duration;

  Duration _elapsed = Duration.zero;
  bool _playing = false;
  double _speed = 1;

  bool get playing => _playing;
  bool get finished => _elapsed >= duration;
  double get speed => _speed;
  Duration get elapsed => _elapsed;

  /// Zeitlicher Fortschritt 0..1.
  double get progress =>
      (_elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

  set speed(double value) {
    assert(value > 0, 'Tempo muss positiv sein');
    _speed = value;
  }

  /// Abspielen; am Ende beginnt es von vorn.
  void play() {
    if (finished) _elapsed = Duration.zero;
    _playing = true;
  }

  void pause() => _playing = false;

  /// Dieselbe Wiedergabe mit anderer Gesamtdauer (z. B. mit Outro) – Stand,
  /// Tempo und Abspielzustand bleiben.
  TourPlayback withDuration(Duration duration) {
    final p = TourPlayback(duration: duration)
      .._speed = _speed
      .._playing = _playing;
    p._elapsed = _elapsed > duration ? duration : _elapsed;
    if (p.finished) p._playing = false;
    return p;
  }

  void restart() {
    _elapsed = Duration.zero;
    _playing = true;
  }

  /// Zeit [dt] weiterlaufen lassen. true, wenn sich der Stand geändert hat.
  bool tick(Duration dt) {
    if (!_playing || dt <= Duration.zero) return false;
    _elapsed += Duration(microseconds: (dt.inMicroseconds * _speed).round());
    if (_elapsed >= duration) {
      _elapsed = duration;
      _playing = false;
    }
    return true;
  }
}
