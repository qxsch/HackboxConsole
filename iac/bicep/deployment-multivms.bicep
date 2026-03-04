@description('Array of user VM definitions. Each element must contain: username, password, vmOwnerTag')
param userVms array

@description('Location for all resources')
param location string = resourceGroup().location

@description('Use Windows 11 BYOL (Bring Your Own License)')
param byol bool = false

@description('Size of the virtual machine')
param virtualMachineSize string = 'Standard_D4s_v4'

@description('OS disk type')
param osDiskType string = 'StandardSSD_LRS'

@description('Full resource ID of the subnet')
param virtualNetworkSubnetId string

module vmDeployments 'deployment-vm.bicep' = [for (vm, i) in userVms: {
  name: 'vm-${uniqueString(vm.username)}'
  params: {
    virtualMachineName: vm.username
    adminUsername: vm.username
    adminPassword: vm.password
    location: location
    virtualMachineSize: virtualMachineSize
    osDiskType: osDiskType
    virtualNetworkSubnetId: virtualNetworkSubnetId
    windowsByol: byol
    vmOwnerTag: vm.vmOwnerTag
  }
}]

@description('Array of objects with vmName, vmOwnerTag, and privateIpAddress for each deployed VM')
output vmInfo array = [for (vm, i) in userVms: {
  vmName: vmDeployments[i].outputs.vmName
  vmOwnerTag: vm.vmOwnerTag
  privateIpAddress: vmDeployments[i].outputs.privateIpAddress
}]
