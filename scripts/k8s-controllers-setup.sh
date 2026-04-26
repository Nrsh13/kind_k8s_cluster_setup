#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-nrsh13}"
ZONE_NAME="${ZONE_NAME:-127.0.0.1.nip.io}"
CLUSTER_NAME="${CLUSTER_NAME:-dev-cluster}"
WILDCARD_CERT="${HOME}/.ssh/ingress_controller_wildcard_cert.pem"
WILDCARD_KEY="${HOME}/.ssh/ingress_controller_wildcard_key.pem"
METALLB_MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml"
INGRESS_HTTP_PORT="${INGRESS_HTTP_PORT:-8080}"
INGRESS_HTTPS_PORT="${INGRESS_HTTPS_PORT:-8443}"
CONTROL_PLANE_HOSTNAME="${CONTROL_PLANE_HOSTNAME:-${CLUSTER_NAME}-control-plane}"

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  CYAN=$'\033[1;36m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  GREEN=""
  CYAN=""
  YELLOW=""
  RED=""
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

wait_for_pods() {
  local label="$1"
  local namespace="$2"
  local timeout="$3"

  kubectl wait --for=condition=Ready pods -l "${label}" -n "${namespace}" --timeout="${timeout}s"
}

create_namespace_if_needed() {
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Namespace '${NAMESPACE}' already exists."
    return 0
  fi

  log_info "Creating namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" >/dev/null
}

install_metallb() {
  print_section "MetalLB Setup"
  log_warning "Skipping MetalLB for local kind access."
  log_warning "MetalLB setup is intentionally commented out for now."
}

configure_metallb_ip_pool() {
  log_warning "Skipping MetalLB IP pool configuration for local kind access."
}

install_sealed_secrets() {
  print_section "Sealed Secrets Setup"

  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n "${NAMESPACE}" >/dev/null

  wait_for_pods "app.kubernetes.io/name=sealed-secrets" "${NAMESPACE}" 300
}

create_wildcard_cert_if_needed() {
  log_info "Setting up wildcard cert..."

  if [[ -f "${WILDCARD_CERT}" && -f "${WILDCARD_KEY}" ]]; then
    if openssl x509 -in "${WILDCARD_CERT}" -text -noout | grep -Fq "${ZONE_NAME}"; then
      log_info "Ingress controller wildcard cert already exists."
      return 0
    fi

    log_warning "Existing wildcard cert does not include ${ZONE_NAME}. Regenerating it."
    rm -f "${WILDCARD_CERT}" "${WILDCARD_KEY}"
  fi

  mkdir -p "$(dirname "${WILDCARD_CERT}")"

  cat <<EOF >/tmp/openssl_config.cnf
[ v3_req ]
basicConstraints = CA:false
extendedKeyUsage = serverAuth
subjectAltName = DNS:${ZONE_NAME},DNS:*.${ZONE_NAME},DNS:localhost,DNS:jenkins.localhost,IP:127.0.0.1
EOF

  openssl req -x509 -new -nodes -days 365 \
    -subj "/C=NZ/ST=AKL/L=Auckland/O=NRSH13/OU=HADOOP/CN=${ZONE_NAME}/emailAddress=nrsh13@gmail.com" \
    -keyout "${WILDCARD_KEY}" \
    -out "${WILDCARD_CERT}" \
    -extensions v3_req \
    -config /tmp/openssl_config.cnf >/dev/null 2>&1

  rm -f /tmp/openssl_config.cnf
}

apply_wildcard_sealed_secret() {
  local existing_fingerprint=""
  local new_fingerprint=""

  if kubectl get secret wildcard -n "${NAMESPACE}" >/dev/null 2>&1; then
    existing_fingerprint="$(kubectl get secret wildcard -n "${NAMESPACE}" -o jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -noout -fingerprint)"
  fi

  kubeseal --controller-name=sealed-secrets --controller-namespace="${NAMESPACE}" --fetch-cert > sealed-secrets.crt
  kubectl create secret -n "${NAMESPACE}" tls wildcard --cert="${WILDCARD_CERT}" --key="${WILDCARD_KEY}" --dry-run=client -o yaml | kubeseal -n "${NAMESPACE}" --cert sealed-secrets.crt -o yaml | kubectl apply -f - >/dev/null

  if kubectl get secret wildcard -n "${NAMESPACE}" >/dev/null 2>&1; then
    new_fingerprint="$(kubectl get secret wildcard -n "${NAMESPACE}" -o jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -noout -fingerprint)"
  fi

  rm -f sealed-secrets.crt

  if [[ -n "${existing_fingerprint}" && "${existing_fingerprint}" != "${new_fingerprint}" ]]; then
    log_info "Wildcard cert fingerprint changed."
  fi
}

check_local_ingress() {
  local timeout=600
  local elapsed=0
  local status_code=""
  local url="http://127.0.0.1:${INGRESS_HTTP_PORT}/"

  log_info "Checking local ingress on ${url}"

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    status_code="$(curl -ks -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [[ "${status_code}" =~ ^(200|308|404)$ ]]; then
      log_success "Local ingress is reachable on port ${INGRESS_HTTP_PORT}."
      return 0
    fi

    sleep 10
    elapsed=$((elapsed + 10))
  done

  log_error "Timeout reached. Local ingress was not reachable on port ${INGRESS_HTTP_PORT} within ${timeout} seconds."
  return 1
}

install_ingress_controller() {
  print_section "Ingress Controller Setup"
  create_namespace_if_needed

  create_wildcard_cert_if_needed
  log_info "Printing the wildcard cert details..."
  openssl x509 -in "${WILDCARD_CERT}" -text -noout | sed -nE '/Issuer:|DNS:/ s/^ +//p' | sed 's/^/\t/'

  log_info "Creating sealed secret for wildcard certs"
  apply_wildcard_sealed_secret

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${NAMESPACE}" \
  --set controller.kind=Deployment \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=ClusterIP \
  --set controller.replicaCount=1 \
  --set controller.nodeSelector."kubernetes\.io/os"=linux \
  --set-string controller.nodeSelector."kubernetes\.io/hostname"="${CONTROL_PLANE_HOSTNAME}" \
  --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set controller.tolerations[0].operator=Exists \
  --set controller.tolerations[0].effect=NoSchedule \
  --set controller.tolerations[1].key=node-role.kubernetes.io/master \
  --set controller.tolerations[1].operator=Exists \
  --set controller.tolerations[1].effect=NoSchedule \
  --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
  --set controller.ingressClassResource.default=true \
  --set controller.extraArgs.default-ssl-certificate="${NAMESPACE}/wildcard" >/dev/null

  kubectl rollout status deployment/ingress-nginx-controller -n "${NAMESPACE}" --timeout=300s >/dev/null
  check_local_ingress
}

install_external_dns() {
  print_section "External DNS Setup"

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_REGION:-}" ]]; then
    log_warning "Skipping external-dns because AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, or AWS_REGION is not set."
    return 0
  fi

  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  helm upgrade --install external-dns external-dns/external-dns \
    --namespace "${NAMESPACE}" \
    --set provider=aws \
    --set policy=sync \
    --set registry=txt \
    --set txtOwnerId="${CLUSTER_NAME}" \
    --set domainFilters[0]="${ZONE_NAME}" \
    --set sources[0]=service \
    --set sources[1]=ingress \
    --set env[0].name=AWS_ACCESS_KEY_ID \
    --set env[0].value="${AWS_ACCESS_KEY_ID}" \
    --set env[1].name=AWS_SECRET_ACCESS_KEY \
    --set env[1].value="${AWS_SECRET_ACCESS_KEY}" \
    --set env[2].name=AWS_DEFAULT_REGION \
    --set env[2].value="${AWS_REGION}" >/dev/null

  kubectl rollout status deployment/external-dns -n "${NAMESPACE}" --timeout=300s >/dev/null
  log_success "external-dns is ready for Route53 updates in zone '${ZONE_NAME}'."
}

print_banner "kind Controllers Setup"
log_info "Starting setup for MetalLB, Sealed Secrets, Ingress Controller, and external-dns in '${NAMESPACE}' namespace..."
install_metallb
configure_metallb_ip_pool
install_sealed_secrets
install_ingress_controller
install_external_dns
log_success "Setup complete for MetalLB, Sealed Secrets, Ingress Controller, and external-dns."
log_warning "Trust the self-signed certificate on macOS with:"
log_warning "  security import ${WILDCARD_CERT}"
log_warning "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${WILDCARD_CERT}"
log_warning "Local access: http://127.0.0.1:${INGRESS_HTTP_PORT} or https://127.0.0.1:${INGRESS_HTTPS_PORT}"
