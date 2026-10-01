using 'main.bicep'

// Change acrName to a globally unique value before deploying.
param acrName = 'registerappacr'
param aksName = 'register-app-aks'
param nodeCount = 2
param nodeVmSize = 'Standard_D2s_v5'
