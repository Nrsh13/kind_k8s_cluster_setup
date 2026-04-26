#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s}"   # ✅ changed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/kind-config.yaml"
WORKER_MEMORY="${WORKER_MEMORY:-2g}"
NAMESPACE="${NAMESPACE:-nrsh13}"

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

log_info()    { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"; }
log_warning() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_step()    { printf "\n${BLUE}▶ %s${RESET}\n" "$*"; }

# ---------- TOOLING ----------
require_homebrew() {
  if command -v brew >/dev/null 2>&1; then return 0; fi
  echo "Install Homebrew first"; exit 1
}

ensure_brew_package() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    log_info "$cmd already installed"
  else
    log_info "Installing $cmd"
    brew install "$cmd"
  fi
}

ensure_docker_runtime() {
  if docker info >/dev/null 2>&1; then
    log_info "Docker is ready"
    return
  fi

  log_info "Starting Colima..."
  brew install colima || true
  colima start --cpu 4 --memory 6 --disk 20
}

# ---------- CLUSTER ----------
cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"
}

cluster_matches_expected_topology() {
  local worker_count
  worker_count="$(kind get nodes --name "${CLUSTER_NAME}" | grep -c 'worker' || true)"
  [[ "${worker_count}" -eq 3 ]]   # ✅ changed
}

ensure_worker_memory_limits() {
  kind get nodes --name "${CLUSTER_NAME}" | while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    if [[ "${node}" == *worker* ]]; then
      log_info "Limiting ${node} memory to ${WORKER_MEMORY}"
      docker update --memory "${WORKER_MEMORY}" --memory-swap "${WORKER_MEMORY}" "${node}" >/dev/null
    fi
  done
  log_success "Worker memory limits applied"
}

create_cluster() {
  if cluster_exists; then
    if cluster_matches_expected_topology; then
      log_info "Cluster exists with correct topology"
    else
      log_warning "Cluster mismatch → recreating"
      kind delete cluster --name "${CLUSTER_NAME}"
    fi
  fi

  if ! cluster_exists; then
    log_step "Creating cluster ${CLUSTER_NAME}"
    kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_FILE}"
  fi

  ensure_worker_memory_limits
}

# ---------- WAIT ----------
wait_for_nodes_ready() {
  log_step "Waiting for nodes to be Ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
  log_success "All nodes ready"
}

# ---------- NAMESPACE ----------
ensure_namespace() {
  if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Namespace exists: ${NAMESPACE}"
  else
    log_info "Creating namespace: ${NAMESPACE}"
    kubectl create ns "${NAMESPACE}" >/dev/null
  fi
}

# ---------- MAIN ----------
echo
printf "${BLUE}=======================================${RESET}\n"
printf "${GREEN} K8s Cluster and Controller Setup Starting 🚀 ${RESET}\n"
printf "${BLUE}=======================================${RESET}\n"

log_step "Checking tools"
require_homebrew
ensure_brew_package kind
ensure_brew_package kubectl
ensure_brew_package helm
ensure_brew_package kubeseal
ensure_brew_package docker

log_step "Starting runtime"
ensure_docker_runtime

log_step "Cluster setup"
create_cluster

log_step "Cluster info"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

log_step "Waiting for readiness"
wait_for_nodes_ready

log_step "Namespace setup"
ensure_namespace

log_step "Installing controllers"
"${SCRIPT_DIR}/create-controllers.sh"

log_step "Starting Cloudflare Tunnel (background mode)"
chmod +x "${SCRIPT_DIR}/setup_tunnel.sh"
"${SCRIPT_DIR}/setup_tunnel.sh" --background
sleep 3  # Give tunnel time to start

log_success "Cluster setup complete 🚀"

echo
printf "${BLUE}=======================================${RESET}\n"
printf "${GREEN} K8s Cluster and Controller Setup Complete 🎉${RESET}\n"
printf "\n"
printf "${CYAN}📡 Cloudflare Tunnel is running in the background!${RESET}\n"
printf "${CYAN}   It will automatically detect and route new ingresses.${RESET}\n"
printf "${CYAN}   Monitor logs:  tail -f /tmp/tunnel-monitor.log${RESET}\n"
printf "\n"
printf "${BLUE}=======================================${RESET}\n"
echo