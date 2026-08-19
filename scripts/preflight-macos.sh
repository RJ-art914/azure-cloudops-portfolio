#!/usr/bin/env bash
set -u

check() {
  local label="$1"
  local command_name="$2"
  local version_command="$3"
  printf "%-30s" "$label"
  if command -v "$command_name" >/dev/null 2>&1; then
    echo "OK  ($($version_command 2>&1 | head -n 1))"
  else
    echo "MISSING"
  fi
}

echo "Azure CloudOps macOS preflight"
echo "------------------------------"
echo "macOS:   $(sw_vers -productVersion)"
echo "CPU:     $(uname -m)"
echo "Shell:   ${SHELL:-unknown}"
echo

check "Homebrew" brew "brew --version"
check "Git" git "git --version"
check "Azure CLI" az "az version --query '\"azure-cli\"' -o tsv"
check "Terraform" terraform "terraform version"
check "Python 3.12" python3.12 "python3.12 --version"
check "Functions Core Tools" func "func --version"
check "Node.js" node "node --version"
check "npm" npm "npm --version"
check "curl" curl "curl --version"

echo
printf "%-30s%s\n" "Functions telemetry opt-out" "${FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT:-NOT SET}"

if az account show >/dev/null 2>&1; then
  echo
echo "Azure login: OK"
  az account show --query '{subscription:name, subscriptionId:id, tenantId:tenantId, user:user.name}' -o table
else
  echo
echo "Azure login: NOT LOGGED IN"
fi
