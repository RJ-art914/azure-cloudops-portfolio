#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="$ROOT_DIR/infrastructure/bootstrap"
DEMO_DIR="$ROOT_DIR/infrastructure/environments/demo"
API_DIR="$ROOT_DIR/app/api"
FRONTEND_DIR="$ROOT_DIR/app/frontend"
PYTHON_BIN="python3.12"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is not installed or not in PATH." >&2
    exit 1
  }
}

for cmd in az terraform "$PYTHON_BIN" func node npm curl; do
  need "$cmd"
done

PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$PYTHON_VERSION" != "3.12" ]]; then
  echo "ERROR: Python 3.12 is required. Found: $($PYTHON_BIN --version 2>&1)" >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "Azure login required. Running: az login"
  az login
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

cat <<INFO

Azure account selected
----------------------
Subscription: $SUBSCRIPTION_NAME
ID:           $SUBSCRIPTION_ID
Tenant:       $TENANT_ID

INFO

read -r -p "Continue and create Azure resources in this subscription? [y/N] " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "Deployment cancelled."; exit 0 ;;
esac

echo "[1/6] Bootstrapping Terraform remote state..."
cd "$BOOTSTRAP_DIR"
terraform init -upgrade
terraform fmt -check -recursive
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan

STATE_RG="$(terraform output -raw resource_group_name)"
STATE_STORAGE="$(terraform output -raw storage_account_name)"
STATE_CONTAINER="$(terraform output -raw container_name)"

# Azure RBAC can take a short time to propagate.
echo "Waiting briefly for Azure RBAC propagation..."
sleep 20

echo "[2/6] Initializing demo environment with Azure Blob remote state..."
cd "$DEMO_DIR"
export ARM_USE_AZUREAD=true
export ARM_USE_CLI=true
terraform init -upgrade -reconfigure \
  -backend-config="resource_group_name=$STATE_RG" \
  -backend-config="storage_account_name=$STATE_STORAGE" \
  -backend-config="container_name=$STATE_CONTAINER" \
  -backend-config="key=demo.terraform.tfstate" \
  -backend-config="use_azuread_auth=true" \
  -backend-config="use_cli=true" \
  -backend-config="tenant_id=$TENANT_ID"

terraform fmt -recursive "$ROOT_DIR/infrastructure"
terraform validate
terraform plan -out=demo.tfplan

echo "[3/6] Applying demo infrastructure..."
terraform apply demo.tfplan

FUNCTION_APP_NAME="$(terraform output -raw function_app_name)"
API_BASE_URL="$(terraform output -raw api_base_url)"
SWA_NAME="$(terraform output -raw static_web_app_name)"
FRONTEND_URL="$(terraform output -raw frontend_url)"
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"

echo "[4/6] Writing Azure API URL into frontend config..."
cat > "$FRONTEND_DIR/config.js" <<CONFIG
window.CLOUDOPS_CONFIG = {
  apiBaseUrl: "$API_BASE_URL"
};
CONFIG

echo "[5/6] Preparing Python 3.12 virtual environment and publishing Azure Functions API..."
cd "$API_DIR"
if [[ ! -d .venv ]]; then
  "$PYTHON_BIN" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
func azure functionapp publish "$FUNCTION_APP_NAME" --python --build remote
deactivate

echo "[6/6] Publishing Azure Static Web App..."
DEPLOYMENT_TOKEN="$(az staticwebapp secrets list --name "$SWA_NAME" --resource-group "$RESOURCE_GROUP" --query properties.apiKey -o tsv)"
export SWA_CLI_DEPLOYMENT_TOKEN="$DEPLOYMENT_TOKEN"
cd "$ROOT_DIR"
npx -y @azure/static-web-apps-cli deploy "$FRONTEND_DIR" --env production
unset SWA_CLI_DEPLOYMENT_TOKEN DEPLOYMENT_TOKEN

echo
echo "Deployment finished."
echo "Frontend: $FRONTEND_URL"
echo "API:      $API_BASE_URL"
echo
echo "Health test:"
curl -fsS "$API_BASE_URL/health" || true
echo
