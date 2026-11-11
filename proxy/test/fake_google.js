/* Ersatz fuer Googles Endpunkte. Zaehlt mit, wie oft tatsaechlich gerufen
 * wurde - damit laesst sich beweisen, dass die Telemetrie selbst keinen
 * einzigen zusaetzlichen Google-Aufruf erzeugt. */
const http = require('http');

function startFakeGoogle() {
  const calls = { directions: 0, geocode: 0, autocomplete: 0, total: 0 };
  /** Abfrageparameter des letzten Aufrufs (ohne Schlüssel). */
  const last = { params: null };
  let mode = 'ok';

  const server = http.createServer((req, res) => {
    calls.total += 1;
    const path = req.url.split('?')[0];
    let kind = 'autocomplete';
    if (path.includes('/directions/')) kind = 'directions';
    else if (path.includes('/geocode/')) kind = 'geocode';
    calls[kind] += 1;
    const params = new URL(req.url, 'http://x').searchParams;
    params.delete('key');
    last.params = Object.fromEntries(params);

    const send = (status, body) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };

    if (mode === 'http_error') return send(500, { error: 'boom' });
    if (mode === 'google_error') {
      return send(200, { status: 'REQUEST_DENIED', error_message: 'nope' });
    }
    if (mode === 'zero_results') return send(200, { status: 'ZERO_RESULTS', routes: [] });
    if (mode === 'hang') return; // Antwort bleibt aus

    if (kind === 'directions') {
      return send(200, {
        status: 'OK',
        routes: [{ legs: [{ distance: { value: 1000 }, duration: { value: 60 } }] }],
      });
    }
    if (kind === 'geocode') {
      return send(200, { status: 'OK', results: [{ formatted_address: 'X' }] });
    }
    return send(200, { suggestions: [] });
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({
        base: `http://127.0.0.1:${server.address().port}`,
        calls,
        last,
        setMode: (m) => { mode = m; },
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

module.exports = { startFakeGoogle };
