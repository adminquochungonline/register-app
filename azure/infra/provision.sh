#!/usr/bin/env bash
# Provision the Azure infrastructure for register-app and (optionally) a
# least-privilege service principal for Jenkins.
#
# Usage:
#   az login
#   ACR_NAME=myuniqueacr ./azure/infra/provision.sh
#
# Environment variables (all optional except where noted):
#   RESOURCE_GROUP   Resource group name            (default: register-app-rg)
#   LOCATION         Azure region                   (default: southeastasia)
#   ACR_NAME         Globally unique ACR name       (default: registerappacr)
#   AKS_NAME         AKS cluster name               (default: register-app-aks)
#   NODE_COUNT       AKS node count                 (default: 2)
#   NODE_VM_SIZE     AKS node VM size               (default: Standard_D2s_v5)
#   CREATE_JENKINS_SP  "true" to create a Jenkins service principal (default: true)
#   JENKINS_SP_NAME  Service principal display name (default: register-app-jenkins)
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-register-app-rg}"
LOCATION="${LOCATION:-southeastasia}"
ACR_NAME="${ACR_NAME:-registerappacr}"
AKS_NAME="${AKS_NAME:-register-app-aks}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2s_v5}"
CREATE_JENKINS_SP="${CREATE_JENKINS_SP:-true}"
JENKINS_SP_NAME="${JENKINS_SP_NAME:-register-app-jenkins}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "Run 'az login' first." >&2; exit 1; }

echo ">> Subscription: $(az account show --query name -o tsv)"
echo ">> Creating resource group '${RESOURCE_GROUP}' in '${LOCATION}'"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

echo ">> Deploying Bicep template (ACR '${ACR_NAME}', AKS '${AKS_NAME}'). This takes several minutes."
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name register-app-infra \
  --template-file "${SCRIPT_DIR}/main.bicep" \
  --parameters acrName="${ACR_NAME}" \
               aksName="${AKS_NAME}" \
               nodeCount="${NODE_COUNT}" \
               nodeVmSize="${NODE_VM_SIZE}" \
  --output none

ACR_ID="$(az deployment group show -g "${RESOURCE_GROUP}" -n register-app-infra --query properties.outputs.acrId.value -o tsv)"
AKS_ID="$(az deployment group show -g "${RESOURCE_GROUP}" -n register-app-infra --query properties.outputs.aksId.value -o tsv)"
ACR_LOGIN_SERVER="$(az deployment group show -g "${RESOURCE_GROUP}" -n register-app-infra --query properties.outputs.acrLoginServer.value -o tsv)"

echo ">> ACR login server: ${ACR_LOGIN_SERVER}"
echo ">> AKS cluster:      ${AKS_NAME}"

if [[ "${CREATE_JENKINS_SP}" == "true" ]]; then
  echo ">> Creating service principal '${JENKINS_SP_NAME}' (AcrPush on ACR)"
  SP_JSON="$(az ad sp create-for-rbac \
    --name "${JENKINS_SP_NAME}" \
    --role AcrPush \
    --scopes "${ACR_ID}" \
    --output json)"
  SP_APP_ID="$(printf '%s' "${SP_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])')"

  echo ">> Granting 'Azure Kubernetes Service Cluster User Role' on AKS"
  az role assignment create \
    --assignee "${SP_APP_ID}" \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope "${AKS_ID}" \
    --output none

  cat <<EOF

================================================================================
Jenkins credential (kind: "Azure Service Principal", ID: azure-sp):
  Subscription ID : $(az account show --query id -o tsv)
  Client ID       : ${SP_APP_ID}
  Tenant ID       : $(printf '%s' "${SP_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tenant"])')
  Client Secret   : (printed below ONCE - store it in Jenkins, do not commit it)
$(printf '%s' "${SP_JSON}" | python3 -c 'import json,sys; print("                    " + json.load(sys.stdin)["password"])')
================================================================================
EOF
fi

cat <<EOF

Next steps:
  1. Update ACR_NAME / AKS_RESOURCE_GROUP / AKS_CLUSTER_NAME in azure/Jenkinsfile
     (and acrLoginServer in azure/azure-pipelines.yml, image in azure/k8s/deployment.yaml).
  2. Test cluster access:
       az aks get-credentials -g ${RESOURCE_GROUP} -n ${AKS_NAME}
       kubectl get nodes
EOF
