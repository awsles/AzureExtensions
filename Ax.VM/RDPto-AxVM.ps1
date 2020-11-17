#Requires -Version 5
<#
.SYNOPSIS
	RDPto-AxVM.ps1 - Remote Desktop to a VM, starting it if necessary.
.DESCRIPTION
	This script will start the named VM if it is stopped and will then remote desktop to it.
	
.PARAMETER All
	If specified, then all subscriptions are examined for orphans.
.NOTES
	Author: Lester Waters
	Version: v0.02
	Date: 17-Nov-20
.LINK
	
	
#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [string] $VMname				= '',			# default VM to start/stop
	[Parameter(Mandatory=$false)] [string] $ResourceGroup		= '',					# ResourceGroup
	[Parameter(Mandatory=$false)] [switch] $Force 				= $false
)

# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.Compute
Import-Module Az.ResourceGraph

# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+
# Service principal name is <<insert_name>>
$TenantId				= '**SET_THIS_FIRST**'			# Your Azure Tenant ID
$CertificateThumbprint	= '**SET_THIS_FIRST**'			# Certificate Thumbprint for App Service Principal
$ApplicationId			= '**SET_THIS_FIRST**'			# ApplicationID for your App Service Principal
$SubscriptionId			= '**SET_THIS_FIRST**'			# Default subscriptionID containing the VM


# +=================================================================================================+
# |  KUSTO QUERY DEFINITIONS																		|
# +=================================================================================================+

# The %%CONDITION%% = " name =~ 'VMNAME' and"
$KustoFindVM = 'Resources
| where type == "microsoft.compute/virtualmachines" and %%CONDITION%% isnotempty(properties.networkProfile.networkInterfaces)
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend osType = tostring(properties.storageProfile.osDisk.osType)
| extend nicId = tostring(properties.networkProfile.networkInterfaces[0].id)
| extend vmProperties = tostring(properties)
| join kind=leftouter (Resources
	| where type =~ "microsoft.network/networkinterfaces" 
	| extend privateIP = tostring(properties.ipConfigurations[0].properties["privateIPAddress"])
	| extend pubId = tostring(properties.ipConfigurations[0].properties.publicIPAddress.id)
	| extend subnetId = tostring(properties.ipConfigurations[0].properties.subnet.id)
	| join kind=leftouter (Resources | where type =~ "microsoft.network/publicipaddresses"
		| extend fqdn = properties.dnsSettings.fqdn
		| extend publicIP = tostring(properties.ipAddress) // May be out of date...
		| project pubId=id, publicIP, fqdn, pubIpProperties=properties) on pubId
	| project nicId=id, nicName=name, privateIP, publicIP, fqdn, pubId, nicProperties=properties, pubIpProperties) on nicId
| join kind=leftouter (ResourceContainers | where type=~"microsoft.resources/subscriptions" 
	| project subscriptionName=name, subscriptionId) on subscriptionId 
| project name, resourceGroup, subscriptionName, location, osType, vmSize, nicName, privateIP, publicIP, fqdn, nicProperties, pubIpProperties, vmProperties, subscriptionId, id'



# +=================================================================================================+
# | LOGIN 																							|
# +=================================================================================================+
write-host -ForegroundColor Yellow "Logging in..."
Login-AzAccount -ServicePrincipal -CertificateThumbprint $CertificateThumbprint `
				-TenantId $TenantId -ApplicationId $ApplicationId


# +=================================================================================================+
# | SELECT THE VM																					|
# +=================================================================================================+

if ($SubscriptionId -And $VMname -And $ResourceGroup)
{
	; # Do nothing
	write-host "DO NOTHING"
}
elseif ($VMname)
{
	# Search by name
	write-host "Querying virtual machines..."
	$query = $KustoFindVM.replace('%%CONDITION%%', " name =~ '$VMname' and")
	$VMs = Search-AzGraph -Query $Query
	if (!$VMs) { write-warning "No VMs with name '$VMname' found!" ; Start-Sleep -Seconds 5 ; return }
	if ($VMs.Count -gt 1)
	{
		write-warning "There are multiple VMs with the name '$VMname'"
		$VM = $VMs | out-gridview -passthru -Title "Choose VM instance to connect to:"
		if (!$VM) { return }
		if ($VM.Count -and $VM.Count -gt 1) { write-warning "Choose only one VM" ; Start-Sleep -Seconds 5 ; return }
		$SubscriptionId = $VM.subscriptionId
		$VMname = $VM.name
		$ResourceGroup = $VM.resourceGroup
	}
	else{
		$SubscriptionId = $VMs.subscriptionId
		$VMname = $VMs.name
		$ResourceGroup = $VMs.resourceGroup
	}
}
else
{
	# List all VMs
	write-host "Querying virtual machines 2..."
	$query = $KustoFindVM.replace('%%CONDITION%%', '')
	$VMs = Search-AzGraph -Query $Query
	if (!$VMs) { write-warning "No VMs found!" ; Start-Sleep -Seconds 5 ; return }
	$VM = $VMs | out-gridview -passthru -Title "Choose VM to connect to:"
	if (!$VM) { return }
	if ($VM.Count -and $VM.Count -gt 1) { write-warning "Choose only one VM" ; Start-Sleep -Seconds 5 ; return }
	$SubscriptionId = $VM.subscriptionId
	$VMname = $VM.name
	$ResourceGroup = $VM.resourceGroup
}



# +=================================================================================================+
# |  MAIN BODY																						|
# +=================================================================================================+

write-host -ForegroundColor Yellow -NoNewLine "Retrieving VM status of '$VMname'... "
$x = Get-AzSubscription -SubscriptionId $SubscriptionId | Select-AzSubscription
$vm = Get-AzVm -Name $VMname -ResourceGroupName $ResourceGroup
$VMStatus = (Get-AzVm -Name $VMname -ResourceGroupName $ResourceGroup -Status).Statuses | Where-Object {$_.Code -like 'PowerState/*'}
write-host -ForegroundColor Green $VMStatus.DisplayStatus
# $x = Read-Host "Press Enter to continue:" ; Return		# DEBUG

if (($VMStatus.Code -like 'PowerState/deallocated') -or ($VMStatus.Code -like 'PowerState/stopped'))
{
	$vm | Start-AzVm -Verbose		# This will wait for VM to start...
	$vm = Get-AzVm -Name $VMname -ResourceGroupName $ResourceGroup
	$nic = Get-AzNetworkInterface -ResourceId $vm.networkprofile.NetworkInterfaces[0].id
	$nicName = $vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/') | select -Last 1
	$publicIpName =  (Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name $nicName).IpConfigurations.PublicIpAddress.Id.Split('/') | select -Last 1
	$publicIpInfo = Get-AzPublicIpAddress -ResourceGroupName $vm.ResourceGroupName -Name $publicIpName
	if (!$publicIpInfo)
		{ write-warning "No public IP address information found for VM" ; start-sleep 5 ; return ; }
	$publicIpAddress = $publicIpInfo.IpAddress
	$fqdn = $publicIpInfo.DNSSettings.fqdn
	write-host "VM $fqdn started at IP address $publicIpAddress"
	if (!$fqdn) { $fqdn = $publicIpAddress }		# If VM has no fqdn

	# Remote Desktop to VM
	Start mstsc.exe "/v:$fqdn /admin"
	start-sleep -seconds 5
}
elseif ($VMStatus.Code -like 'PowerState/running')
{
	$vm = Get-AzVm -Name $VMname -ResourceGroupName $ResourceGroup
	$nic = Get-AzNetworkInterface -ResourceId $vm.networkprofile.NetworkInterfaces[0].id
	$nicName = $vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/') | select -Last 1
	$publicIpName =  (Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name $nicName).IpConfigurations.PublicIpAddress.Id.Split('/') | select -Last 1
	$publicIpInfo = Get-AzPublicIpAddress -ResourceGroupName $vm.ResourceGroupName -Name $publicIpName
	if (!$publicIpInfo)
		{ write-warning "No public IP address information found for VM" ; start-sleep 5 ; return ; }
	$publicIpAddress = $publicIpInfo.IpAddress
	$fqdn = $publicIpInfo.DNSSettings.fqdn
	if (!$fqdn) { $fqdn = $publicIpAddress }	# If VM has no fqdn

	write-host -ForegroundColor Yellow "VM $fqdn ($publicIpAddress) is already running"
	# Remote Desktop to VM
	Start mstsc.exe "/v:$fqdn /admin"
	start-sleep -seconds 5
}
else
{
	write-host ''
	write-warning "Unable to RDP to $VMname VM. State is: $($vmStatus.DisplayStatus.Replace('VM ',''))"
	$x = Read-Host "Press Enter to continue:"
}
