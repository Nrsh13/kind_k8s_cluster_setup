#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s}"
TUNNEL_NAME="${TUNNEL_NAME:-kind-tunnel}"
BASE_DOMAIN="${BASE_DOMAIN:-nrsh13-hadoop.com}"

# Cloudflare API token is required for tunnel + DNS cleanup.
# (Used by scripts/setup_tunnel.sh as well.)
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN environment variable is required}"

# ---------- COLORS ----------
if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  CYAN=$'\033[1;36m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  BLUE=$'\033[1;34m'
  RESET=$'\033[0m'
else
  GREEN=""; CYAN=""; YELLOW=""; RED=""; BLUE=""; RESET=""
fi

# ---------- LOGGING ----------
log_step()    { printf "\n${BLUE}▶ %s\n${RESET}\n" "$*"; }
log_info()    { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"; }
log_warning() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }

# ---------- UTILITIES ----------
get_ingress_hostnames() {
  # Capture all ingress hostnames before deleting the cluster.
  # Output is newline-separated.
  kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null | sed '/^[[:space:]]*$/d' || true
}

get_cloudflare_zone_id() {
  # Query Cloudflare zone ID for BASE_DOMAIN.
  curl -sS -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("result") or [{}])[0].get("id",""))' 2>/dev/null || true
}

delete_cloudflare_cname_record() {
  local zone_id="$1"
  local hostname="$2"

  # Find record IDs for CNAME matching hostname.
  local record_ids
  record_ids="$(
    curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); 
ids=[r.get("id") for r in (d.get("result") or []) if r.get("id")]; 
print("\n".join([i for i in ids if i]))'
  )"

  if [[ -z "${record_ids}" ]]; then
    log_info "No Cloudflare CNAME record found for ${hostname} (skipping)"
    return 0
  fi

  while IFS= read -r record_id; do
    [[ -z "${record_id}" ]] && continue
    log_info "Deleting Cloudflare DNS record ${hostname} (id=${record_id})"
    curl -sS -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" 2>/dev/null >/dev/null || true
  done <<< "${record_ids}"
}

cleanup_cloudflared() {
  log_step "Stopping Cloudflare tunnel processes (local)"
  pkill -f "cloudflared tunnel run" >/dev/null 2>&1 || true
  pkill -f "setup_tunnel.sh" >/dev/null 2>&1 || true
}

cleanup_cloudflare_resources() {
  # This deletes:
  # 1) the tunnel in Cloudflare
  # 2) any CNAME DNS records created for ingress hostnames
  log_step "Deleting Cloudflare Tunnel + DNS"

  if ! command -v cloudflared >/dev/null 2>&1; then
    log_error "cloudflared CLI not found on PATH. Can't delete the tunnel or DNS via Cloudflare API."
    return 0
  fi

  local zone_id
  zone_id="$(get_cloudflare_zone_id)"
  if [[ -z "${zone_id}" ]]; then
    log_error "Could not determine Cloudflare zone ID for domain ${BASE_DOMAIN}. Skipping DNS record deletion."
  fi

  local hostnames
  hostnames="$(get_ingress_hostnames)"
  if [[ -z "${hostnames}" ]]; then
    log_info "No ingress hostnames discovered (skipping DNS record deletion)"
  fi

  # Delete tunnel in Cloudflare (DNS cleanup is handled separately).
  log_info "Deleting tunnel '${TUNNEL_NAME}' in Cloudflare"
  cloudflared tunnel delete "${TUNNEL_NAME}" >/dev/null 2>&1 || true

  # Delete DNS records for each discovered ingress hostname.
  if [[ -n "${zone_id}" && -n "${hostnames}" ]]; then
    while IFS= read -r hostname; do
      [[ -z "${hostname}" ]] && continue
      # Only delete records under the expected zone to avoid accidental deletion.
      if [[ "${hostname}" == *".${BASE_DOMAIN}" ]]; then
        delete_cloudflare_cname_record "${zone_id}" "${hostname}"
      else
        log_info "Skipping DNS deletion for ${hostname} (outside zone ${BASE_DOMAIN})"
      fi
    done <<< "${hostnames}"
  fi
}

# ---------- MAIN ----------
log_step "Deleting kind cluster"

# Cloudflare cleanup needs the ingress hostnames, so do it first (while the cluster still exists).
cleanup_cloudflared
cleanup_cloudflare_resources

if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  log_info "Deleting cluster: ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
  log_success "Cluster deleted successfully"
else
  log_warning "Cluster '${CLUSTER_NAME}' does not exist"
fi

echo
printf "${BLUE}=======================================${RESET}\n"
printf "${GREEN} K8s Cluster Deleted Successfully !! 🎉 ${RESET}\n"
printf "${BLUE}=======================================${RESET}\n"
echo
