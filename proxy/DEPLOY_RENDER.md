Render deployment instructions (minimal)

1. Create a new Web Service on Render.

2. Repository settings:
   - Root Directory: `proxy`
   - Branch: select your branch (e.g., `main`)

3. Build & Start commands:
   - Build Command: `npm install`
   - Start Command: `npm start`

4. Environment variables:
   - `GOOGLE_MAPS_API_KEY` = <your Google Maps API key>

5. Port: Render will provide `PORT` env var; the proxy reads `process.env.PORT`.

After deployment, copy the service URL (e.g. `https://your-proxy.onrender.com`) and use it when building the Flutter web app:

`flutter build web --release --base-href "/drive-time-arrival/" --dart-define=MAPS_PROXY_BASE=https://your-proxy.onrender.com`

Or in GitHub Actions set the dart-define to the Render URL.
