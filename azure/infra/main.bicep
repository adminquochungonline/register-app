// Azure infrastructure for register-app:
//   - Azure Container Registry (replaces Docker Hub)
//   - Azure Kubernetes Service (replaces AWS EKS)
//   - AcrPull role for the AKS kubelet identity (no imagePullSecret needed)
//
// Deploy:  az deployment group create -g <rg> -f main.bicep -p main.bicepparam

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Globally unique ACR name (5-50 lowercase alphanumeric characters).')
@minLength(5)
@maxLength(50)
param acrName string

@description('ACR SKU.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Basic'

@description('AKS cluster name.')
param aksName string = 'register-app-aks'

@description('Number of nodes in the system node pool.')
@minValue(1)
@maxValue(10)
param nodeCount int = 2

@description('VM size for the AKS nodes.')
param nodeVmSize string = 'Standard_D2s_v5'

@description('Tags applied to all resources.')
param tags object = {
  project: 'register-app'
  managedBy: 'bicep'
}

// Built-in role: AcrPull
var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: acrSku
  }
  properties: {
    // Authenticate with Entra ID (az acr login / managed identity), not the admin user.
    adminUserEnabled: false
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${aksName}-dns'
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        count: nodeCount
        vmSize: nodeVmSize
      }
    ]
  }
}

resource aksAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrId string = acr.id
output aksName string = aks.name
output aksId string = aks.id
