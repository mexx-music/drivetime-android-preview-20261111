#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROXY_DIR="$REPO_ROOT/proxy"
PROXY_PORT=3000
PROXY_LOG="$PROXY_DIR/proxy.log"

print_banner(){
  echo "========================================="
  echo " DriverRoute ETA — start helper"
  echo "========================================="
}

print_banner

# Load .env if present (but do not commit .env)
if [ -f "$REPO_ROOT/.env" ]; then
  echo "Loading environment from .env"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
fi

if [ -z "${GOOGLE_MAPS_API_KEY:-}" ]; then
  echo "ERROR: GOOGLE_MAPS_API_KEY is not set in environment."
  echo "Please set it before running, for example:"
  echo "  export GOOGLE_MAPS_API_KEY=\"YOUR_KEY\""
  echo "Or create a .env file with: GOOGLE_MAPS_API_KEY=YOUR_KEY"
  exit 1
fi

# Check if proxy port is in use
is_port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$1" -sTCP:LISTEN -n -P >/dev/null 2>&1
    return $?
  elif command -v nc >/dev/null 2>&1; then
    nc -z localhost "$1" >/dev/null 2>&1
    return $?
  else
    # fallback: try curl
    curl -s "http://localhost:$1/health" >/dev/null 2>&1
    return $?
  fi
}

if is_port_in_use "$PROXY_PORT"; then
  echo "Proxy port $PROXY_PORT appears to be in use — will reuse the existing listening process."
  echo "If you want to restart the proxy, stop the process that listens on port $PROXY_PORT first."
else
  echo "Starting proxy (node server.js) in background — logs: $PROXY_LOG"
  (cd "$PROXY_DIR" && \
    GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS_API_KEY" node server.js >"$PROXY_LOG" 2>&1 &)
  sleep 1
  # Give proxy a little time to bind
  if is_port_in_use "$PROXY_PORT"; then
    echo "Proxy started and listening on port $PROXY_PORT"
  else
    echo "Warning: proxy did not start as expected — check $PROXY_LOG for details"
  fi
fi

# Start Flutter web with the local proxy and a separately restricted client key.
echo "Starting Flutter (web) with MAPS_PROXY_BASE=http://localhost:$PROXY_PORT"
cd "$REPO_ROOT"
flutter run -d chrome \
  --dart-define=MAPS_PROXY_BASE="http://localhost:$PROXY_PORT" \
  --dart-define=GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS_API_KEY"
