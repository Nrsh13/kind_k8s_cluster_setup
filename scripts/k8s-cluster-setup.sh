#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-dev-cluster}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/kind-config.yaml"
WORKER_MEMORY="${WORKER_MEMORY:-2g}"

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  CYAN=$'\033[1;36m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN=""
  CYAN=""
  YELLOW=""
  RED=""
  BOLD=""
  RESET=""
fi

print_banner() {
  local title="$1"
  printf "\n${GREEN}=======================================${RESET}\n"
  printf "${GREEN}  %s${RESET}\n" "${title}"
  printf "${GREEN}=======================================${RESET}\n\n"
}

print_section() {
  local title="$1"
  printf "\n${GREEN}=======================================${RESET}\n"
  printf "${GREEN}  %s${RESET}\n" "${title}"
  printf "${GREEN}=======================================${RESET}\n"
}

log_info() {
  printf "${CYAN}[INFO]${RESET} %s\n" "$*"
}

log_success() {
  printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"
}

log_warning() {
  printf "${YELLOW}[WARNING]${RESET} %s\n" "$*"
}

log_error() {
  printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
}

require_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  cat <<'EOF'
Homebrew is required to bootstrap the local toolchain automatically.

Install Homebrew first, then rerun this script:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF
  exit 1
}

ensure_brew_package() {
  local command_name="$1"
  local package_name="${2:-$1}"

  if command -v "${command_name}" >/dev/null 2>&1; then
    log_info "${package_name} is already installed."
    return 0
  fi

  log_info "Installing ${package_name}"
  brew install "${package_name}"
  log_success "${package_name} installation complete."
}

ensure_docker_runtime() {
  if docker info >/dev/null 2>&1; then
    log_info "Docker runtime is already available."
    return 0
  fi

  if command -v colima >/dev/null 2>&1; then
    log_info "Starting Colima so Docker is available"
    colima start --cpu 6 --memory 8 --disk 30
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    log_info "Installing Colima to provide a local Docker runtime"
    brew install colima
    log_info "Starting Colima so Docker is available"
    colima start --cpu 6 --memory 8 --disk 30
    return 0
  fi

  cat <<'EOF'
Docker is installed but the daemon is not reachable.
Start Docker, then rerun this script.
EOF
  exit 1
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"
}

cluster_matches_expected_topology() {
  local worker_count
  worker_count="$(kind get nodes --name "${CLUSTER_NAME}" | grep -c 'worker' || true)"
  [[ "${worker_count}" -eq 2 ]]
}

ensure_worker_memory_limits() {
  local node

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    if [[ "${node}" == *worker* ]]; then
      log_info "Setting ${node} memory limit to ${WORKER_MEMORY}"
      docker update --memory "${WORKER_MEMORY}" --memory-swap "${WORKER_MEMORY}" "${node}" >/dev/null
    fi
  done < <(kind get nodes --name "${CLUSTER_NAME}")

  log_success "Worker node memory limits applied."
}

create_cluster() {
  if cluster_exists; then
    if cluster_matches_expected_topology; then
      log_info "Cluster ${CLUSTER_NAME} already exists with the expected topology."
    else
      log_warning "Cluster ${CLUSTER_NAME} exists but does not have 2 worker nodes. Recreating it."
      kind delete cluster --name "${CLUSTER_NAME}"
    fi
  fi

  if ! cluster_exists; then
    log_info "Creating kind cluster: ${CLUSTER_NAME}"
    kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_FILE}"
  fi

  ensure_worker_memory_limits
}

print_banner "kind Kubernetes Cluster Setup"
print_section "Installing / Verifying Tools"
require_homebrew
ensure_brew_package kind
ensure_brew_package kubectl
ensure_brew_package helm
ensure_brew_package kubeseal
ensure_brew_package kustomize
ensure_brew_package docker
ensure_brew_package etcd

print_section "Starting Container Runtime"
ensure_docker_runtime

print_section "Creating kind Cluster"
create_cluster

echo
log_success "Cluster is ready"
echo "Current context: kind-${CLUSTER_NAME}"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo
kubectl get nodes

echo
"${SCRIPT_DIR}/k8s-controllers-setup.sh"
