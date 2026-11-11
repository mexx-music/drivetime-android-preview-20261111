# DriverRoute ETA

Flutter-Web/PWA zur verständlichen Tour- und ETA-Planung für LKW-Fahrer. Die
Ergebnisansicht zeigt Distanz, reine Fahrzeit, Pausen/Ruhe, Ankunft sowie den
kompletten Ablauf als Timeline.

Der Planungsschnitt kann automatisch aus Distanz und Routendauer ermittelt
oder als Profil gewählt werden: 80 km/h Standard, 70 km/h bei viel
Bundes-/Landstraße und 60 km/h für Norwegen bzw. langsame Strecken.

Start und Ziel bieten laufende Ortsvorschläge; beim Start kann direkt
`Meine Position` verwendet werden. Berechnete Ergebnisse lassen sich über das
System-Teilen, WhatsApp, E-Mail oder die Zwischenablage weitergeben.

Die aktuelle technische und fachliche Bestandsaufnahme steht in
[`docs/PROJECT_AUDIT.md`](docs/PROJECT_AUDIT.md).

## Entwicklung

```sh
flutter pub get
flutter test
flutter run -d chrome \
  --dart-define=MAPS_PROXY_BASE=http://localhost:3000 \
  --dart-define=GOOGLE_MAPS_API_KEY=YOUR_RESTRICTED_CLIENT_KEY
```

Der Schlüssel im Web-Build muss in Google Cloud auf die erlaubten HTTP-Referrer
und ausschließlich benötigte APIs eingeschränkt sein. Der Proxy verwendet den
serverseitigen Schlüssel aus seiner eigenen Umgebungsvariable.

Für Android wird `GOOGLE_MAPS_API_KEY=...` in `android/local.properties`
eingetragen oder als Umgebungsvariable gesetzt. Für iOS wird
`ios/Flutter/GoogleMaps.xcconfig.example` nach `GoogleMaps.xcconfig` kopiert und
mit einem auf die iOS-App eingeschränkten Schlüssel befüllt. Diese lokalen
Dateien werden nicht eingecheckt.

## Quick start script

You can start the proxy and run Flutter web with the included helper:

```
./start.sh
```

It expects `GOOGLE_MAPS_API_KEY` to be set in your environment or in a `.env` file at the repo root.

## Deploying the proxy to Render

To make the GitHub Pages‑hosted web app work (geocoding/directions), deploy the Node proxy in `/proxy` to a hosted service such as Render.

Render settings (minimal):
- Root directory: `proxy`
- Build command: `npm install`
- Start command: `npm start`
- Env var: `GOOGLE_MAPS_API_KEY` (set in Render dashboard, do not commit)

After deploying, update your web build to use the deployed proxy URL:

```
flutter build web --release --base-href "/drive-time-arrival/" --dart-define=MAPS_PROXY_BASE=https://your-proxy.onrender.com
```

Locally continue to use `MAPS_PROXY_BASE=http://localhost:3000` for development.
