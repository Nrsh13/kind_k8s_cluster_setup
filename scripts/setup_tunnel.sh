#!/usr/bin/env bash

set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-kind-tunnel}"
BASE_DOMAIN="${BASE_DOMAIN:-nrsh13-hadoop.com}"
LOCAL_SERVICE="${LOCAL_SERVICE:-http://localhost:8080}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.cloudflared/config.yml}"
TUNNEL_FILE="${TUNNEL_FILE:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"  # Check for changes every 10 seconds
LOG_FILE="${LOG_FILE:-/tmp/tunnel-monitor.log}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
CLOUDFLARE_ZONE_ID=""

# Setup logging
mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

get_zone_id() {
  # Fetch zone ID from Cloudflare API using domain name
  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    log_msg "❌ Error: CLOUDFLARE_API_TOKEN not set"
    return 1
  fi
  
  local zone_response
  zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null)
  
  local zone_id
  zone_id=$(echo "$zone_response" | jq -r '.result[0].id // empty' 2>/dev/null)
  
  if [[ -z "$zone_id" ]]; then
    log_msg "❌ Error: Could not find zone ID for domain $BASE_DOMAIN"
    return 1
  fi
  
  echo "$zone_id"
}

get_tunnel_cname() {
  # Get the CNAME for the tunnel from tunnel credentials file
  if [[ -f "$TUNNEL_FILE" ]]; then
    local tunnel_uuid
    tunnel_uuid=$(jq -r '.TunnelID' "$TUNNEL_FILE" 2>/dev/null || echo "")
    if [[ -n "$tunnel_uuid" ]]; then
      echo "${tunnel_uuid}.cfargotunnel.com"
      return 0
    fi
  fi
  
  return 1
}

create_cloudflare_dns_record() {
  local hostname="$1"
  local tunnel_cname="$2"
  local zone_id="$3"
  
  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    log_msg "⚠️  Cloudflare API token not configured, skipping DNS record creation for $hostname"
    return 0
  fi
  
  log_msg "Creating/updating Cloudflare DNS record for $hostname -> $tunnel_cname"
  
  # Check if DNS record already exists
  local existing_record
  existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null)
  
  local record_id
  record_id=$(echo "$existing_record" | jq -r '.result[0].id // empty' 2>/dev/null)
  
  if [[ -n "$record_id" ]]; then
    # Update existing record
    log_msg "  ✓ Updating DNS record for $hostname"
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tunnel_cname}\",\"ttl\":1,\"proxied\":true}" > /dev/null 2>&1
  else
    # Create new record
    log_msg "  ✓ Creating DNS record for $hostname"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tunnel_cname}\",\"ttl\":1,\"proxied\":true}" > /dev/null 2>&1
  fi
}

get_ingress_hostnames() {
  # Get all ingresses from all namespaces and extract hostnames
  kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null | sort -u || echo ""
}

get_ingress_host_and_service() {
  # Get ingress hostnames with their backend service info
  kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\t"}{.http.paths[0].backend.service.name}{"\t"}{.http.paths[0].backend.service.port.number}{"\n"}{end}{end}' 2>/dev/null | sort -u || echo ""
}

generate_tunnel_config() {
  local config_file="$1"
  
  mkdir -p "$(dirname "$config_file")"
  
  log_msg "Generating tunnel configuration..."
  
  # Start with base config
  cat > "$config_file" <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${TUNNEL_FILE}

ingress:
EOF
  
  # Get all ingresses from cluster
  local hostnames
  hostnames=$(get_ingress_host_and_service)
  
  if [[ -z "$hostnames" ]]; then
    log_msg "⚠️  No ingresses found in cluster"
  else
    log_msg "Found ingresses:"
    echo "$hostnames" | while IFS=$'\t' read -r hostname service port; do
      if [[ -n "$hostname" ]]; then
        # Determine the service URL
        local service_url="${LOCAL_SERVICE}"
        if [[ -n "$service" && "$service" != "<nil>" ]]; then
          # Try to use the actual service from cluster if available
          # For now, we'll use localhost but could be enhanced
          service_url="${LOCAL_SERVICE}"
        fi
        
        log_msg "  - Adding ingress: $hostname -> $service_url"
        cat >> "$config_file" <<EOF
  - hostname: ${hostname}
    service: ${service_url}
    originRequest:
      httpHostHeader: ${hostname}
EOF
      fi
    done
  fi
  
  # Add catch-all
  cat >> "$config_file" <<'EOF'
  - service: http_status:404
EOF
  
  log_msg "✅ Configuration file updated"
}

setup_cloudflare() {
  log_msg "======================================="
  log_msg " Cloudflare Tunnel Setup"
  log_msg "======================================="
  
  # Check for required API token
  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    log_msg "❌ Error: CLOUDFLARE_API_TOKEN environment variable is required"
    log_msg "Set it with: export CLOUDFLARE_API_TOKEN='<your-api-token>'"
    return 1
  fi
  log_msg "✓ API token configured"
  
  log_msg "👉 Fetching zone ID for domain $BASE_DOMAIN..."
  CLOUDFLARE_ZONE_ID=$(get_zone_id)
  log_msg "✓ Zone ID: $CLOUDFLARE_ZONE_ID"
  
  log_msg "👉 Checking cloudflared installation..."
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_msg "Installing cloudflared..."
    brew install cloudflared
  else
    log_msg "✓ cloudflared already installed"
  fi
  
  log_msg "👉 Checking required tools..."
  if ! command -v jq >/dev/null 2>&1; then
    log_msg "Installing jq..."
    brew install jq
  else
    log_msg "✓ jq already installed"
  fi
  
  log_msg "👉 Checking Cloudflare authentication..."
  if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
    log_msg "👉 Logging into Cloudflare (browser will open)..."
    cloudflared tunnel login
  else
    log_msg "✓ Already authenticated with Cloudflare"
  fi
  
  log_msg "👉 Creating tunnel..."
  cloudflared tunnel create "${TUNNEL_NAME}" 2>/dev/null || log_msg "ℹ️  Tunnel may already exist"
  
  log_msg "👉 Fetching tunnel credentials..."
  TUNNEL_FILE="$(ls "$HOME/.cloudflared"/*.json 2>/dev/null | head -n 1)"
  if [[ -z "$TUNNEL_FILE" ]]; then
    log_msg "❌ Error: Could not find tunnel credentials file"
    return 1
  fi
  log_msg "✓ Using credentials: $TUNNEL_FILE"
}

restart_tunnel() {
  log_msg "🔄 Restarting tunnel..."
  pkill -f "cloudflared tunnel run" || true
  sleep 2
  
  log_msg "👉 Starting tunnel..."
  # Run in background with nohup to survive script exit
  nohup cloudflared tunnel run "${TUNNEL_NAME}" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  log_msg "✓ Tunnel started with PID: $pid"
}

setup_dns_routes() {
  log_msg "👉 Setting up DNS routes for ingresses..."
  local hostnames
  hostnames=$(get_ingress_hostnames)
  
  if [[ -z "$hostnames" ]]; then
    log_msg "⚠️  No ingresses found, skipping DNS route setup"
    return
  fi
  
  # Get tunnel CNAME
  local tunnel_cname
  if ! tunnel_cname=$(get_tunnel_cname); then
    log_msg "❌ Error: Could not determine tunnel CNAME"
    return 1
  fi
  
  log_msg "📌 Tunnel CNAME: $tunnel_cname"
  
  echo "$hostnames" | while read -r hostname; do
    if [[ -n "$hostname" ]]; then
      # Create Cloudflare DNS record
      create_cloudflare_dns_record "${hostname}" "${tunnel_cname}" "${CLOUDFLARE_ZONE_ID}"
    fi
  done
}

# Main execution
log_msg "======================================="
log_msg "Starting Tunnel Monitor"
log_msg "======================================="

# One-time setup
setup_cloudflare
generate_tunnel_config "$CONFIG_FILE"
setup_dns_routes
restart_tunnel

# Monitor for ingress changes
log_msg ""
log_msg "👉 Starting continuous monitoring for ingress changes..."
log_msg "📝 Log file: tail -f $LOG_FILE"
log_msg ""

last_state=""
first_run=true

while true; do
  current_state=$(get_ingress_hostnames | sort)
  
  # Check if ingresses have changed
  if [[ "$current_state" != "$last_state" ]] || [[ "$first_run" == true ]]; then
    if [[ "$first_run" == false ]]; then
      log_msg "📋 Ingress configuration changed, updating tunnel..."
    fi
    generate_tunnel_config "$CONFIG_FILE"
    setup_dns_routes
    restart_tunnel
    last_state="$current_state"
    first_run=false
  fi
  
  sleep "$WATCH_INTERVAL"
done