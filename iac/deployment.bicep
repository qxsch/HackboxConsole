@description('Name of the web app.')
param webAppName string = uniqueString(resourceGroup().id) // Generate unique String for web app name
@description('The pricing tier for the hosting plan.')
@allowed([
  'F1'
  'D1'
  'B1'
  'S1'
])
param sku string = 'B1' // The SKU of App Service Plan
@description('The instance size of the hosting plan (small, medium, or large).')
@allowed([
  '0'
  '1'
  '2'
])
param workerSize string = '0' // The instance size of the hosting plan (small, medium, or large).
@description('The location for all resources.')
param location string = resourceGroup().location // Location for all resources
@description('The username for the hacker')
param hackerUsername string = 'hacker' // The username for the hacker
@description('The password for the hacker')
@secure()
param hackerPassword string
@description('The username for the coach')
param coachUsername string = 'coach' // The username for the coach
@description('The password for the coach')
@secure()
param coachPassword string

// variables
var linuxFxVersion = 'PYTHON|3.12' // The runtime stack of web app
var appServicePlanName = toLower('plan-${webAppName}')
var storageAccountName = toLower('storage${webAppName}')
var webSiteName = toLower('console-${webAppName}')


// add a vnet
resource vnet 'Microsoft.Network/virtualNetworks@2021-02-01' = {
  name: 'hackbox-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/24'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
          ]
        }
      }
    ]
  }
}       

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: '${vnet.id}/subnets/default'
          action: 'Allow'
        }
      ]
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2021-04-01' = {
  name: 'default'
  parent: storageAccount
  properties: {}
}

resource settingsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2021-04-01' = {
  parent: tableService
  name: 'settings'
}

resource credentialsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2021-04-01' = {
  parent: tableService
  name: 'credentials'
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  properties: {
    reserved: true
  }
  sku: {
    name: sku
    capacity: int(workerSize)
  }
  kind: 'linux'
}

resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: webSiteName
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    virtualNetworkSubnetId: vnet.properties.subnets[0].id
    vnetRouteAllEnabled: true
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
      appCommandLine: 'gunicorn --bind=0.0.0.0 --workers=4 startup:app'
      appSettings: [
        {
          name: 'HACKBOX_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'HACKBOX_SECRET_KEY'
          value: '${uniqueString(subscription().id)}${uniqueString(resourceGroup().id)}'
        }
        {
          name: 'HACKBOX_HACKER_USER'
          value: hackerUsername
        }
        {
          name: 'HACKBOX_HACKER_PWD'
          value: hackerPassword
        }
        {
          name: 'HACKBOX_COACH_USER'
          value: coachUsername
        }
        {
          name: 'HACKBOX_COACH_PWD'
          value: coachPassword
        }
        {
          name:'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value:'true'
        }
      ]
    }
  }
}



// output the name of the web app
output webAppName string = webSiteName
// output the url of the web app
output webAppUrl string = appService.properties.defaultHostName
// output the storage account name
output storageAccountName string = storageAccount.name
