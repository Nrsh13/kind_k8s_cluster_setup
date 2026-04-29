#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-nrsh13}"
ZONE_NAME="${ZONE_NAME:-127.0.0.1.nip.io}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s}"   # optional consistency
WILDCARD_CERT="${HOME}/.ssh/ingress_controller_wildcard_cert.pem"
WILDCARD_KEY="${HOME}/.ssh/ingress_controller_wildcard_key.pem"
SEALED_SECRET_CERT_PATH="${SEALED_SECRET_CERT_PATH:-${HOME}/.ssh/sealed-secrets.crt}"
SEALED_SECRET_KEY_PATH="${SEALED_SECRET_KEY_PATH:-${HOME}/.ssh/sealed-secrets.key}"
ENABLE_CUSTOM_CERT_FOR_SEALED_SECRET="${ENABLE_CUSTOM_CERT_FOR_SEALED_SECRET:-true}"
SEALED_SECRETS_TLS_SECRET_NAME="${SEALED_SECRETS_TLS_SECRET_NAME:-sealed-secrets}"
SEALED_SECRETS_ACTIVE_KEY_LABEL="${SEALED_SECRETS_ACTIVE_KEY_LABEL:-sealedsecrets.bitnami.com/sealed-secrets-key}"
SEALED_SECRETS_ACTIVE_KEY_VALUE="${SEALED_SECRETS_ACTIVE_KEY_VALUE:-active}"
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

# ---------- SEALED SECRETS HELPERS ----------
get_cert_fingerprint_sha256_from_pem() {
  # Args:
  #   $1 - PEM string
  # Prints: hex fingerprint without colons
  local pem="$1"
  echo "${pem}" | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/.*=//; s/://g' | head -n 1 || true
}

get_cert_fingerprint_sha256_from_secret() {
  # Args:
  #   $1 - secret name
  # Prints: hex fingerprint without colons (or empty if not found/invalid)
  local secret_name="$1"
  local crt_b64
  crt_b64="$(kubectl -n "${NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
  [[ -z "${crt_b64}" ]] && return 0
  local crt_pem
  crt_pem="$(printf '%s' "${crt_b64}" | base64 -D 2>/dev/null || true)"
  [[ -z "${crt_pem}" ]] && return 0
  get_cert_fingerprint_sha256_from_pem "${crt_pem}"
}

# ---------- SEALED SECRETS ----------
install_sealed_secrets() {
  log_step "Sealed Secrets Setup"

  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n "${NAMESPACE}" >/dev/null

  if [[ "${ENABLE_CUSTOM_CERT_FOR_SEALED_SECRET}" == "true" ]]; then
    if [[ -e "${SEALED_SECRET_CERT_PATH}" && -e "${SEALED_SECRET_KEY_PATH}" ]]; then
      log_info "Using custom sealed-secrets cert/key from ~/.ssh"
    else
      log_warning "Custom sealed-secrets cert/key not found."
      log_warning "Expected: ${SEALED_SECRET_CERT_PATH} and ${SEALED_SECRET_KEY_PATH}"
      log_warning "Regenerating a new self-signed sealed-secrets keypair (for this cluster)."
      mkdir -p "$(dirname "${SEALED_SECRET_CERT_PATH}")"
      openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "${SEALED_SECRET_KEY_PATH}" \
        -out "${SEALED_SECRET_CERT_PATH}" \
        -subj "/CN=sealed-secret/O=sealed-secret" \
        -days 10950 >/dev/null 2>&1 || true
      chmod 600 "${SEALED_SECRET_KEY_PATH}" 2>/dev/null || true
      chmod 644 "${SEALED_SECRET_CERT_PATH}" 2>/dev/null || true
    fi

    # If the controller is already using the same cert as ~/.ssh, do nothing.
    local desired_fp
    desired_fp="$(get_cert_fingerprint_sha256_from_pem "$(cat "${SEALED_SECRET_CERT_PATH}")")"
    local current_fp
    current_fp="$(get_cert_fingerprint_sha256_from_secret "${SEALED_SECRETS_TLS_SECRET_NAME}")"

    if [[ -n "${desired_fp}" && -n "${current_fp}" && "${desired_fp}" == "${current_fp}" ]]; then
      log_info "sealed-secrets controller TLS cert already matches ~/.ssh (sha256 fingerprint). Skipping sealed secret updates."
    else
      # Replace the TLS secret used by the controller.
      # The sealed-secrets controller uses a TLS secret named "sealed-secrets" by default.
      log_step "Applying custom sealed-secrets controller key"
      kubectl -n "${NAMESPACE}" create secret tls "${SEALED_SECRETS_TLS_SECRET_NAME}" \
        --cert="${SEALED_SECRET_CERT_PATH}" \
        --key="${SEALED_SECRET_KEY_PATH}" \
        -o yaml --dry-run=client | kubectl -n "${NAMESPACE}" apply -f - >/dev/null

      # Mark this keypair as the active one (matches the AKS script pattern).
      kubectl -n "${NAMESPACE}" label secret "${SEALED_SECRETS_TLS_SECRET_NAME}" \
        "${SEALED_SECRETS_ACTIVE_KEY_LABEL}=${SEALED_SECRETS_ACTIVE_KEY_VALUE}" \
        --overwrite >/dev/null 2>&1 || true

      # Restart controller so it picks up the new key.
      kubectl -n "${NAMESPACE}" delete pod -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1 || true
    fi
  fi

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

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  # Idempotency: avoid restarting ingress-nginx if it is already installed and fully ready.
  # Sealed-secrets changes do not require ingress-nginx to restart.
  if kubectl -n "${NAMESPACE}" get daemonset/ingress-nginx-controller >/dev/null 2>&1; then
    desired="$(kubectl -n "${NAMESPACE}" get daemonset/ingress-nginx-controller -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
    ready="$(kubectl -n "${NAMESPACE}" get daemonset/ingress-nginx-controller -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
  else
    desired=""
    ready=""
  fi

  if [[ -n "${desired}" && -n "${ready}" && "${desired}" != "0" && "${ready}" == "${desired}" ]]; then
    log_info "ingress-nginx-controller already installed and ready (${ready}/${desired}); skipping helm upgrade."
  else
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
      >/dev/null
  fi

  kubectl rollout status daemonset/ingress-nginx-controller -n "${NAMESPACE}" --timeout=300s >/dev/null

  log_success "Ingress ready"
}

# ---------- MAIN ----------
log_step "Controllers Setup Started"

install_sealed_secrets
install_ingress_controller

log_success "Controllers setup complete 🚀"