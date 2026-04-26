#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-dev-cluster}"

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
log_step()    { printf "\n${BLUE}▶ %s${RESET}\n" "$*"; }
log_info()    { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"; }
log_warning() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }

# ---------- MAIN ----------
log_step "Deleting kind cluster"

if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  log_info "Deleting cluster: ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
  log_success "Cluster deleted successfully"
else
  log_warning "Cluster '${CLUSTER_NAME}' does not exist"
fi