# DriveTime Studio – Videoexport (Minimalversion)

Erste echte Exportstufe für den Tourfilm.
- **Kostenlos:** ein Kontrollvideo in kleiner Qualität.
- **Später kostenpflichtig:** derselbe Film in Full HD.

## Was es gibt

| Teil | Ort | Aufgabe |
|---|---|---|
| Exportprofile | `lib/export/video_export_preset.dart`, `presets.json` | `VideoExportPreset.controlPreview` / `.fullHD` (getrennt von der Live-Vorschau) |
| Filmspezifikation | `lib/export/film_spec.dart` | Daten der letzten Berechnung als JSON, stabile `filmId` |
| Eine Filmregie | `lib/export/film_view.dart` | „Tour animieren“ und beide Exportprofile bauen den Film hier |
| Ablauf | `lib/export/video_export_job.dart` | `idle → preparing → rendering → encoding → ready / failed / cancelled` |
| Berechtigung | `lib/export/video_export_entitlement.dart` | Kontrollvideo frei, Full HD gesperrt (Dev-Freischaltung ausdrücklich lokal) |
| Oberfläche | `lib/export/video_export_panel.dart` | „Kontrollvideo erstellen“ / „Full HD erstellen“ nach der Berechnung |
| Exportdienst | `tool/studio_export/server.mjs` + `render.mjs` | rendert und kodiert lokal |

## Profile

Beide Profile rendern denselben CSS-Ausschnitt (960 × 540 bzw. 540 × 960) mit derselben Zeitleiste (30 Filmbilder/s über `drivetimeExport.step()`) und mit `CinematicQuality.exportFullHD`. Unterschiedlich sind nur die technischen Werte der Aufnahme:

| | Kontrollvideo | Full HD |
|---|---|---|
| 16:9 / 9:16 | 640 × 360 / 360 × 640 | 1920 × 1080 / 1080 × 1920 |
| Pixeldichte | 2/3 | 2 |
| Bildrate | 10 fps (jedes 3. Filmbild) | 30 fps (jedes Filmbild) |
| H.264 | CRF 34, `veryfast` | CRF 16, `slow` |
| Ton (falls vorhanden) | AAC 64 kbit/s | AAC 256 kbit/s |
| Wasserzeichen | `DRIVETIME PREVIEW` (unten rechts, halbtransparent) | keins |

Der App-Film hat derzeit **keine Tonspur**; beide Dateien sind daher stumm (`-an`).

## Ablauf

1. **Spezifikation:** Die App (Studio-Build) erstellt nach der Berechnung die `TourFilmSpec` aus Kartenplan, ETA-Zeitleiste, Namen, Format, Lkw-Lackierung und Browser-Zeitzone und sendet sie an `POST /api/export`.
2. **Rendering:** Der Dienst öffnet den Studio-Build in headless Chrome unter `?export=1&filmSpec=/jobs/<id>/spec.json`, im CSS-Ausschnitt des Formats, mit der Pixeldichte des Profils und in der Zeitzone der Spezifikation.
   - Die App lädt die Spezifikation und startet den Film direkt im Aufnahmemodus, ohne Bedienelemente.
3. **Aufnahme:** wie bei den bisherigen Filmexporten (`cdp_tiles.mjs`, Final Cut, „Roll On“): `step()`, warten bis Fahrzeugbilder, Kacheln und Lkw-Symbol stimmen, dann Screenshot.
   - Die Bilder gehen direkt an ffmpeg (image2pipe → libx264, Wasserzeichen per `overlay`).
4. **Ergebnis:** Die fertige Datei liefert `GET /api/export/<id>/video`. Halbe Dateien werden nie als fertig gemeldet, bei Abbruch wird der Auftragsordner gelöscht.

**Keine Routen-, Geocoding- oder Autocomplete-Anfrage:** Der Renderer sperrt DriveTime-Proxy und Google-Dienste per CDP und zählt Versuche. Ein Versuch lässt den Auftrag scheitern statt eine Datei auszuliefern.

## Starten (lokal, Mac)

```sh
flutter build web --release --dart-define=DRIVETIME_STUDIO_EXPORT=true \
  --dart-define=MAPS_PROXY_BASE=https://drive-time-arrival-proxy.onrender.com -o build/studio_web
node tool/studio_export/server.mjs --build build/studio_web --work <ordner>
# dann http://127.0.0.1:8150/ öffnen, Tour berechnen, „Kontrollvideo erstellen“
```

**Voraussetzungen:** Google Chrome, ffmpeg mit libx264, Node ≥ 22.

**Entwicklung:**
- `--dev-unlock-fullhd`: Full HD lokal freischalten.
- `--dev-max-seconds N`: Film nach N s beenden. Nur für schnelle Tests; das Ergebnis trägt `truncated: true`.

**End-to-End-Test ohne Netz:** `e2e_replay.mjs <steps.json> <tape.json>`. Die Tour wird über die echte Oberfläche gerechnet, Proxy-Antworten kommen aus einer Aufzeichnung, dann wird der Export geklickt und verfolgt.

## Warum (noch) nicht im Browser

Ein zuverlässiger Export direkt im Browser des Nutzers ist mit dem heutigen Aufbau nicht möglich:

- **Getrennte Bildflächen:** Der Film besteht aus zwei getrennt gezeichneten Ebenen, der MapLibre-WebGL-Karte (Platform-View, eigenes HTML-Canvas) und der Flutter-Oberfläche (CanvasKit, HUD, Titel, Intro/Outro). Es gibt keine Browser-Schnittstelle, die beide bildgenau zu einem Bild zusammenführt. `captureStream()` erfasst nur ein Canvas, Bildschirmaufnahme braucht eine Nutzerfreigabe und nimmt in Echtzeit statt deterministisch auf.
- **Echtzeit statt Ruhe:** Die bildgenaue Aufnahme muss je Bild warten, bis Kacheln und Fahrzeugbilder gezeichnet sind (oft mehrere 100 ms). Ein Tab im Vordergrund des Nutzers würde dabei blockieren.
- **Kodierung:** H.264 per WebCodecs ist nicht in allen Browsern verfügbar (Safari eingeschränkt), MP4-Muxing bräuchte eine zusätzliche Bibliothek.

Deshalb ist die erste Stufe der bewährte lokale Renderer.

## Weg zum serverseitigen Exportjob (später)

**Unverändert übernehmbar:**
- `render.mjs` (headless Chrome + ffmpeg)
- `presets.json`
- der HTTP-Vertrag (`/api/export`, `/api/export/<id>`, `/cancel`, `/video`, `/api/entitlements`)
- die `TourFilmSpec`

**Noch zu bauen:**
- eine Warteschlange und Worker (Chrome + GPU oder Software-GL)
- Speicherung der fertigen Dateien mit befristetem Download-Link
- Anmeldung/Tour-Zuordnung (Supabase-Konto)
- die echte Freischaltung: Full HD nur nach bezahlter Bestellung zur `filmId`, geprüft im Dienst und nicht in der App
- „ein Kontrollvideo je Filmversion“ durchsetzen; die Grundlage zählt `exports.json` bereits
- in der App nur `DRIVETIME_STUDIO_URL` auf den Dienst setzen

Laufende Kosten entstehen erst mit dieser Stufe (Rechenzeit je Film, Speicher). Die heutige Stufe hat keine.
