#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-nrsh13}"
ZONE_NAME="${ZONE_NAME:-127.0.0.1.nip.io}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s}"   # optional consistency
WILDCARD_CERT="${HOME}/.ssh/ingress_controller_wildcard_cert.pem"
WILDCARD_KEY="${HOME}/.ssh/ingress_controller_wildcard_key.pem"
INGRESS_HTTP_PORT="${INGRESS_HTTP_PORT:-8080}"
INGRESS_HTTPS_PORT="${INGRESS_HTTPS_PORT:-8443}"
CONTROL_PLANE_HOSTNAME="${CONTROL_PLANE_HOSTNAME:-${CLUSTER_NAME}-control-plane}"

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

# ---------- HELPERS ----------
wait_for_pods() {
  local label="$1"
  local namespace="$2"
  local timeout="$3"

  log_info "Waiting for pods: ${label}"
  kubectl wait --for=condition=Ready pods -l "${label}" -n "${namespace}" --timeout="${timeout}s"
  log_success "Pods ready: ${label}"
}

create_namespace_if_needed() {
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Namespace exists: ${NAMESPACE}"
  else
    log_info "Creating namespace: ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}" >/dev/null
    log_success "Namespace created"
  fi
}

# ---------- SEALED SECRETS ----------
install_sealed_secrets() {
  log_step "Sealed Secrets Setup"

  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n "${NAMESPACE}" >/dev/null

  wait_for_pods "app.kubernetes.io/name=sealed-secrets" "${NAMESPACE}" 300
}

# ---------- CERT ----------
create_wildcard_cert_if_needed() {
  log_step "Wildcard Certificate Setup"

  if [[ -f "${WILDCARD_CERT}" && -f "${WILDCARD_KEY}" ]]; then
    if openssl x509 -in "${WILDCARD_CERT}" -text -noout | grep -Fq "${ZONE_NAME}"; then
      log_info "Wildcard cert already valid"
      return
    fi

    log_warning "Existing cert invalid → regenerating"
    rm -f "${WILDCARD_CERT}" "${WILDCARD_KEY}"
  fi

  mkdir -p "$(dirname "${WILDCARD_CERT}")"

  cat <<EOF >/tmp/openssl_config.cnf
[ v3_req ]
basicConstraints = CA:false
extendedKeyUsage = serverAuth
subjectAltName = DNS:${ZONE_NAME},DNS:*.${ZONE_NAME},DNS:localhost,IP:127.0.0.1
EOF

  openssl req -x509 -new -nodes -days 365 \
    -subj "/C=NZ/ST=AKL/L=Auckland/O=NRSH13/CN=${ZONE_NAME}" \
    -keyout "${WILDCARD_KEY}" \
    -out "${WILDCARD_CERT}" \
    -extensions v3_req \
    -config /tmp/openssl_config.cnf >/dev/null 2>&1

  rm -f /tmp/openssl_config.cnf

  log_success "Wildcard cert created"
}

apply_wildcard_sealed_secret() {
  log_step "Applying TLS Secret (Sealed)"

  kubeseal --controller-name=sealed-secrets --controller-namespace="${NAMESPACE}" --fetch-cert > sealed-secrets.crt

  kubectl create secret tls wildcard \
    --cert="${WILDCARD_CERT}" \
    --key="${WILDCARD_KEY}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | \
    kubeseal -n "${NAMESPACE}" --cert sealed-secrets.crt -o yaml | \
    kubectl apply -f - >/dev/null

  rm -f sealed-secrets.crt

  log_success "Wildcard TLS secret applied"
}

# ---------- INGRESS (FIXED) ----------
install_ingress_controller() {
  log_step "Ingress Controller Setup"

  create_namespace_if_needed
  create_wildcard_cert_if_needed
  apply_wildcard_sealed_secret

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${NAMESPACE}" \
    --set controller.kind=DaemonSet \
    --set controller.hostPort.enabled=true \
    --set controller.service.type=ClusterIP \
    --set controller.nodeSelector."node-role\.kubernetes\.io/control-plane"="" \
    --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set controller.tolerations[0].operator=Exists \
    --set controller.tolerations[0].effect=NoSchedule \
    --set controller.ingressClassResource.default=true \
    --set controller.extraArgs.default-ssl-certificate="${NAMESPACE}/wildcard" >/dev/null

  kubectl rollout status daemonset/ingress-nginx-controller -n "${NAMESPACE}" --timeout=300s >/dev/null

  log_success "Ingress ready"
}

# ---------- MAIN ----------
log_step "Controllers Setup Started"

install_sealed_secrets
install_ingress_controller

log_success "Controllers setup complete 🚀"