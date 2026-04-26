#!/usr/bin/env bash

set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-kind-tunnel}"
BASE_DOMAIN="${BASE_DOMAIN:-nrsh13-hadoop.com}"
LOCAL_SERVICE="${LOCAL_SERVICE:-http://localhost:8080}"

if [[ "$#" -gt 0 ]]; then
  OVERLAYS=("$@")
else
  OVERLAYS=("dev" "prod")
fi

build_hostname() {
  local overlay="$1"
  echo "nrsh13-jenkins-${overlay}.${BASE_DOMAIN}"
}

echo "======================================="
echo " Cloudflare Tunnel Setup"
echo "======================================="
echo "Hostnames:"
for overlay in "${OVERLAYS[@]}"; do
  echo "  - $(build_hostname "${overlay}")"
done

echo "👉 Checking cloudflared installation..."
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Installing cloudflared..."
  brew install cloudflared
else
  echo "cloudflared already installed"
fi

echo "👉 Logging into Cloudflare (browser will open)..."
cloudflared tunnel login

echo "👉 Creating tunnel..."
cloudflared tunnel create "${TUNNEL_NAME}" || echo "Tunnel may already exist"

echo "👉 Fetching tunnel credentials..."
TUNNEL_FILE="$(ls ~/.cloudflared/*.json | head -n 1)"

echo "👉 Creating config file..."
mkdir -p ~/.cloudflared

cat <<EOF > ~/.cloudflared/config.yml
tunnel: ${TUNNEL_NAME}
credentials-file: ${TUNNEL_FILE}

ingress:
EOF

for overlay in "${OVERLAYS[@]}"; do
  HOSTNAME="$(build_hostname "${overlay}")"
  cat <<EOF >> ~/.cloudflared/config.yml
  - hostname: ${HOSTNAME}
    service: ${LOCAL_SERVICE}
    originRequest:
      httpHostHeader: ${HOSTNAME}
EOF
done

cat <<'EOF' >> ~/.cloudflared/config.yml
  - service: http_status:404
EOF

echo "👉 Creating DNS route..."
for overlay in "${OVERLAYS[@]}"; do
  HOSTNAME="$(build_hostname "${overlay}")"
  echo "Routing DNS for ${HOSTNAME}"
  cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}" || true
done

echo "👉 Starting tunnel..."
pkill cloudflared || true
sleep 2

cloudflared tunnel run "${TUNNEL_NAME}"
