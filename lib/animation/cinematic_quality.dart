/// Renderqualität der 2.5D-Tour.
///
/// Trennt Vorschau und Film: Alle Profile zeigen dieselbe Tour mit derselben
/// Zeitleiste – Positionen, Tempo, Kamerawege, Shot-Timing, Zooms, Fähre,
/// Tageszeit, Länder, Kilometer, Zielanflug und Outro kommen unverändert
/// aus Planung und Regie. Ein Profil ändert nur, wie fein gezeichnet wird.
///
/// - [previewPerformance]: iPad, Smartphone, schwächere Geräte – flüssig
///   und stabil zuerst.
/// - [previewHigh]: leistungsfähige Rechner – höhere Live-Qualität.
/// - [exportFullHD]: der Film (Bild für Bild, 1080 × 1920, 30 fps) – nie von
///   der Leistung des Geräts abhängig, auf dem die Vorschau lief.
class CinematicQuality {
  const CinematicQuality._(
    this.id, {
    required this.spritePx,
    required this.outroSpritePx,
    required this.maxDriveSprites,
    required this.maxDriveSpritesOutro,
    this.maxMapPixelRatio,
    this.outroYawStep = 4,
    this.outroPitchStep = 5,
    this.outroSweepSteps = 8,
    this.releaseDriveSpritesAtOutro = false,
    this.outroPrewarmPerSecond,
    this.approachDriveSprites,
  });

  final String id;

  /// Lkw-/Fährenbild in der Fahrt: Bildpunkte je Fahrzeugmeter. Die Größe
  /// auf dem Bildschirm bleibt gleich; nur die Auflösung des Bildes ändert
  /// sich.
  final double spritePx;

  /// Lkw-Bild im Outro (nah, mit Lichtzustand).
  final double outroSpritePx;

  /// Höchstzahl gehaltener Fahrzeugbilder in der Fahrt und ab dem
  /// Zielanflug (siehe Bildspeicher in der Szene).
  final int maxDriveSprites;
  final int maxDriveSpritesOutro;

  /// Höchste Pixeldichte der Kartenfläche (null: die des Geräts). HUD und
  /// Texte (Flutter) bleiben unberührt scharf.
  final double? maxMapPixelRatio;

  /// Bildstufen des Lkw im Outro-Schwenk (Grad; Gier ein Vielfaches von 4).
  /// Der Rest zur echten Richtung wird wie in der Fahrt über die Bilddrehung
  /// ausgeglichen. Gröbere Stufen = weniger vorab erzeugte Bilder.
  final int outroYawStep;
  final int outroPitchStep;

  /// Stufen des Lichtkegel-Schwenks (Licht-Reveal im Hero).
  final int outroSweepSteps;

  /// Beim Übergang ins Outro alle Fahrbilder freigeben, die das Outro nicht
  /// braucht (es zeigt den stehenden Lkw in seiner Endpose).
  final bool releaseDriveSpritesAtOutro;

  /// Höchstens so viele Outro-Bilder je Sekunde vorab erzeugen (null: so
  /// schnell wie möglich, eines je Bild). Dieselben Bilder, nur über den
  /// Zielanflug verteilt statt als Spitze.
  final double? outroPrewarmPerSecond;

  /// Ab dem Zielanflug: so viele zuletzt benutzte Fahrbilder halten, die
  /// vorab geplanten Outro-Bilder zusätzlich (null: wie bisher bis
  /// [maxDriveSpritesOutro] zusammen).
  final int? approachDriveSprites;

  static const previewPerformance = CinematicQuality._(
    'previewPerformance',
    spritePx: 8,
    outroSpritePx: 16,
    maxDriveSprites: 48,
    maxDriveSpritesOutro: 160,
    maxMapPixelRatio: 1.5,
    // Gemessen (iPhone mini): am Ende des Hero 469 Bilder / 42 MB Lkw-Bilder
    // (160 Schwenk-/Fahrbilder + 40 große Lichtbilder). Gier 8° fällt dank
    // Bilddrehung nicht auf; die Neigung bleibt bei 5° – 10° war im Hero
    // deutlich sichtbar (Lkw wirkte steiler, A/B-Vergleich).
    outroYawStep: 8,
    outroPitchStep: 5,
    outroSweepSteps: 4,
    releaseDriveSpritesAtOutro: true,
    // Gemessen (Peking→Phuket nachts, iPhone-mini-Ansicht): ab dem
    // Zielanflug entstanden ~130 Bilder in 3 s (~35/s), JS-Speicher
    // +130 MB in 2–3 s. Verteilt und mit früher freigegebenen Fahrbildern
    // bleibt der Bedarf derselbe, nur ohne Spitze.
    outroPrewarmPerSecond: 8,
    approachDriveSprites: 16,
  );

  /// Bisheriger Live-Stand.
  static const previewHigh = CinematicQuality._(
    'previewHigh',
    spritePx: 12,
    outroSpritePx: 24,
    maxDriveSprites: 48,
    maxDriveSpritesOutro: 160,
  );

  /// Film: volle Qualität. Heute wie [previewHigh] (so entstanden die
  /// bisherigen Exporte); höher aufgelöste Lkw-Bilder und Hero-Assets kommen
  /// später nur hier hinzu.
  static const exportFullHD = CinematicQuality._(
    'exportFullHD',
    spritePx: 12,
    outroSpritePx: 24,
    maxDriveSprites: 160,
    maxDriveSpritesOutro: 400,
  );

  /// Profil für die Wiedergabe: Film immer [exportFullHD]; sonst Touch-
  /// Geräte (iPad, Smartphone) [previewPerformance], übrige [previewHigh].
  /// Bewusst keine Geräteliste.
  static CinematicQuality choose({required bool videoExport, required bool touchDevice}) {
    if (videoExport) return exportFullHD;
    return touchDevice ? previewPerformance : previewHigh;
  }
}
