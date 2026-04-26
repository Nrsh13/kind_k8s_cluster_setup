#!/usr/bin/env bash

set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-kind-tunnel}"
BASE_DOMAIN="${BASE_DOMAIN:-nrsh13-hadoop.com}"
LOCAL_SERVICE="${LOCAL_SERVICE:-http://localhost:8080}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.cloudflared/config.yml}"
TUNNEL_FILE="${TUNNEL_FILE:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"  # Check for changes every 10 seconds
LOG_FILE="${LOG_FILE:-/tmp/tunnel-monitor.log}"

# Parse arguments
BACKGROUND_MODE=false
if [[ "$#" -gt 0 ]] && [[ "$1" == "--background" ]]; then
  BACKGROUND_MODE=true
  shift
fi

# Setup logging
mkdir -p "$(dirname "$LOG_FILE")"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
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
  
  log_msg "👉 Checking cloudflared installation..."
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_msg "Installing cloudflared..."
    brew install cloudflared
  else
    log_msg "✓ cloudflared already installed"
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
  
  echo "$hostnames" | while read -r hostname; do
    if [[ -n "$hostname" ]]; then
      log_msg "Routing DNS for ${hostname}"
      cloudflared tunnel route dns "${TUNNEL_NAME}" "${hostname}" 2>/dev/null || true
    fi
  done
}

monitor_ingresses() {
  log_msg "======================================="
  log_msg " Starting Ingress Monitor (PID: $$)"
  log_msg "======================================="
  log_msg "Monitoring interval: ${WATCH_INTERVAL}s"
  log_msg "Log file: ${LOG_FILE}"
  
  local last_state=""
  local first_run=true
  
  while true; do
    local current_state
    current_state=$(get_ingress_hostnames | sort)
    
    # Check if ingresses have changed
    if [[ "$current_state" != "$last_state" ]] || [[ "$first_run" == true ]]; then
      log_msg "📋 Ingress configuration changed, updating tunnel..."
      generate_tunnel_config "$CONFIG_FILE"
      setup_dns_routes
      restart_tunnel
      last_state="$current_state"
      first_run=false
    fi
    
    sleep "$WATCH_INTERVAL"
  done
}

# Main execution
if [[ "$BACKGROUND_MODE" == true ]]; then
  # Run setup once, then monitor in background
  setup_cloudflare
  generate_tunnel_config "$CONFIG_FILE"
  restart_tunnel
  
  # Daemonize the monitoring
  log_msg "Starting background monitoring..."
  nohup bash -c "source '$0'; monitor_ingresses" >> "$LOG_FILE" 2>&1 &
  monitor_pid=$!
  log_msg "✅ Background monitor started with PID: $monitor_pid"
  log_msg "📝 Monitor logs: tail -f $LOG_FILE"
else
  # Original interactive mode
  setup_cloudflare
  generate_tunnel_config "$CONFIG_FILE"
  setup_dns_routes
  restart_tunnel
  
  log_msg "👉 Starting ingress monitoring (will update tunnel automatically)..."
  monitor_ingresses
fi
