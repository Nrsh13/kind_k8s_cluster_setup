#!/bin/bash

# Define colors for output
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print the Usage
usage="
Usage: Pass Overlay Tooling and Environment as Arguments

        sh $0 --tooling kustomize [--environment dev|ppte|prod|etc]
"

# Define logging functions
log_info() {
      echo  "${CYAN}[INFO] $1${NC}"
}

log_success() {
      echo  "${BOLD_GREEN}[SUCCESS] $1${NC}"
}

log_error() {
      echo  "${RED}[ERROR] $1${NC}"
}

log_warning() {
      echo  "${BOLD_YELLOW}[WARNING] $1${NC}"
}

# Loop through command-line arguments to get values of options:
while [ "X${1}" != "X" ]; do
    case $1 in
        --tooling )
            shift
            TOOLING=$1
            ;;
        --environment )
            shift
            OVERLAY_ENV=$1
            ;;
        -h|h|--help|help )
             log_info "$usage"
            exit 1
            ;;
        * ) 
            log_error "$(date) Invalid options in $0"
            log_info "$usage"
            exit 1
            ;;
    esac
    shift
done

# Tooling validation (only kustomize is valid)
if [[ "${TOOLING}" != "kustomize" ]]; then
     log_error "Only 'kustomize' tooling is supported."
     log_info "$usage"
    exit 1
fi

# Environment validation (required for kustomize)
if [[ -z ${OVERLAY_ENV} ]]; then
     log_error "Overlay Environment is required when using 'kustomize'. E.g. dev, ppte, prod, etc."
     log_info "$usage"
    exit 1
fi

log_info "NOTE: This script uses GITHUB_USER, GITHUB_TOKEN, BITBUCKET_USER, BITBUCKET_TOKEN, NONPROD_AKS_SEALED_SECRET_CERT_URL, PROD_AKS_SEALED_SECRET_CERT_URL from .bashrc. DUMMY if not defined"
log_info "Get sealed-secrets.crt - from current Cluster. Modify script if cert is available at any URL."
rm -rf temp_dir; mkdir temp_dir; cp setup-sealed-secret.sh temp_dir/; cd temp_dir; chmod +x setup-sealed-secret.sh

kubeseal --controller-name=sealed-secrets --controller-namespace=nrsh13 --fetch-cert > sealed-secrets.crt

log_info "Check if BITBUCKET_TOKEN, GITHUB_TOKEN and .ssh/id_rsa exists"
if [ -z "$BITBUCKET_TOKEN" ] || [ -z "$GITHUB_TOKEN" ]; then
     log_warning "Missing required file or environment variables. Kindly set in .bashrc or shell session!!"
     log_warning "These details will be used by seed job. Make sure id_rsa key has access to your bitbucket repo."
     log_warning "Setting DUMMY, Seed Job will FAIL!!"
    BITBUCKET_TOKEN="DUMMY"
    GITHUB_TOKEN="DUMMY"
fi

# Check if ~/.ssh/id_rsa exists
if [ ! -f ~/.ssh/id_rsa ]; then
     log_warning "~/.ssh/id_rsa does not exist. Creating a DUMMY One. Seed Job will FAIL!!"
    echo DUMMY >> ~/.ssh/id_rsa
fi

log_info "Sealing secrets now..."
log_info "Processing bitbucket-user-pass.yaml ..."

# Create the plain text Bitbucket user/pass secret manifest with a placeholder for the password
bitbucket_secret_manifest='
apiVersion: v1
kind: Secret
metadata:
  name: "bitbucket-user-pass"
  labels:
    "jenkins.io/credentials-type": "usernamePassword"
  annotations:
    "jenkins.io/credentials-description" : "Bitbucket Credentials from K8s Secrets"
type: Opaque
stringData:
  username: "USER_PLACEHOLDER"
  password: "PASSWORD_PLACEHOLDER"
'

# Replace the Bitbucket user and password placeholder with the actual environment variable
bitbucket_secret_manifest=$(echo "$bitbucket_secret_manifest" | sed -e "s/USER_PLACEHOLDER/$BITBUCKET_USER/g; s/PASSWORD_PLACEHOLDER/$BITBUCKET_TOKEN/g")

# Save the modified Bitbucket user/pass secret manifest to a YAML file
echo "$bitbucket_secret_manifest" > bitbucket-user-pass.yaml

cat bitbucket-user-pass.yaml | kubeseal --cert "./sealed-secrets.crt" --scope cluster-wide -o yaml > sealed-bitbucket-user-pass.yaml

log_info "Processing github-secret.yaml ..."    

# Create the plain text GitHub token secret manifest with a placeholder for the password
github_secret_manifest='
apiVersion: v1
kind: Secret
metadata:
  name: "github-token"
  labels:
    "jenkins.io/credentials-type": "usernamePassword"
  annotations:
    "jenkins.io/credentials-description" : "Github Credentials from K8s Secrets"
type: Opaque
stringData:
  username: "USER_PLACEHOLDER"
  password: "PASSWORD_PLACEHOLDER"
'

# Replace the GitHub token password placeholder with the actual environment variable
github_secret_manifest=$(echo "$github_secret_manifest" | sed -e "s/USER_PLACEHOLDER/$GITHUB_USER/g; s/PASSWORD_PLACEHOLDER/$GITHUB_TOKEN/g")

# Save the modified GitHub token secret manifest to a YAML file
echo "$github_secret_manifest" > github-secret.yaml

cat github-secret.yaml | kubeseal --cert "./sealed-secrets.crt" --scope cluster-wide -o yaml > sealed-github-token.yaml

log_info "Processing bitbucket-ssh-key.yaml ..."

private_key_content=$(sed 's/^/    /' ~/.ssh/id_rsa)

# Define the Bitbucket SSH key manifest with the private key content
bitbucket_ssh_key_manifest=$(cat <<EOL
apiVersion: v1
kind: Secret
metadata:
  name: "bitbucket-ssh-key"
  labels:
    "jenkins.io/credentials-type": "basicSSHUserPrivateKey"
  annotations:
    "jenkins.io/credentials-description" : "Bitbucket SSH Key from K8s Secret"
type: Opaque
stringData:
  username: "jenkins"
  privateKey: |
$private_key_content
EOL
)

# Save the modified Bitbucket SSH key secret manifest to a YAML file
echo "$bitbucket_ssh_key_manifest" > bitbucket-ssh-key.yaml

cat bitbucket-ssh-key.yaml | kubeseal --cert "./sealed-secrets.crt" --scope cluster-wide -o yaml > sealed-bitbucket-ssh-key.yaml

rm -f sealed-secrets.crt

# Initialize a flag to check if any file is empty
empty_file_found=false

# Loop through the sealed-secret files for kustomize
for file in "sealed-"*.yaml; do
    # Check if the file exists and is not empty
    if [ -s "$file" ]; then
        DESTINATION="overlays/$OVERLAY_ENV/secrets"
        log_info "Seems Kustomize Setup, Copy secrets to the overlays/$OVERLAY_ENV/secrets folder"
        mkdir -p "$DESTINATION"
        cp $file "$DESTINATION/"
    else
         log_error "File $file is empty or does not exist - Something WRONG!! Not copying the secrets!!"
        empty_file_found=true
        break
    fi
done

# Check the flag, if not set, remove the temp_dir
if [ "$empty_file_found" = false ]; then
     log_success "All files are sealed and copied to the overlays/$OVERLAY_ENV/secrets folder. Removing temp_dir...\n"
    cd ..
    rm -rf "temp_dir"
fi
