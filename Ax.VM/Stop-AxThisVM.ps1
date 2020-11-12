#Requires -Version 5
<#
.SYNOPSIS
	Stops the VM on which this is running.
.DESCRIPTION
	This will stop the currently running virtual machine.
	This is done by locating the virtual machine by its private IP address.
	If the name of the VM in Azure does not match, then a warning is displayed.
	
	The service principal needs to have sufficient rights to enumerate the current VM
	and network interfaces as well as the rights to shutdown the VM.
	
.PARAMETER Force
	If set, the user is not asked to confirm the shutdown.

.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 12-Nov-20
.LINK
	
	
#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [switch] $Force 				= $false
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.ResourceGraph


# +=================================================================================================+
# | LOGIN and SELECT SUBSCRIPTION																	|
# +=================================================================================================+
write-host -ForegroundColor Yellow "Logging in..."
Login-AzAccount -ServicePrincipal `
		-TenantId 'f55850c9-aa72-40b9-b21a-a7e7abc0897e' `
		-CertificateThumbprint 'ACA7AD6907B05438C1087AA562F8ADED1FF27A38' `
		-ApplicationId '15d9e263-166e-49bc-bc9f-30f3b263a49f'


# Get-AzSubscription -SubscriptionId a1326448-627e-4b06-9a7f-4d19b417b3ff | Select-AzSubscription


# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+

# MIME Type Definitions
$TextPlain				= @{"ContentType" = "text/plain"}				# MIME Type for Plain Text
$TextHTML				= @{"ContentType" = "text/html"}				# MIME Type for HTML
$TextCSV				= @{"ContentType" = "text/csv"}					# MIME Type for CSV
$AppJSON				= @{"ContentType" = "application/json"}			# MIME Type for JSON
$AppBinary				= @{"ContentType" = "application/octet-stream"}	# MIME Type for Binary Data

# Miscellaneous
$crlf 					= [char]13 + [char]10


# +=================================================================================================+
# |  KUSTO QUERY DEFINITIONS																				|
# +=================================================================================================+

$KustoFindbyIP = 'Resources
| where type =~ "microsoft.network/networkinterfaces" and isnotempty(properties.ipConfigurations)
| mv-expand ipConfiguration = properties.ipConfigurations
| where ipConfiguration.properties.privateIPAddress =~ "%%IP%%"
| extend privateIPType = tostring(ipConfiguration.properties.privateIPAllocationMethod)
| extend privateIP = tostring(ipConfiguration.properties.privateIPAddress)
| extend publicIPid = tostring(ipConfiguration.properties.publicIPAddress.id)
| join kind=leftouter (Resources | where type =~ "microsoft.network/publicipaddresses"
    | extend publicIPaddr = tostring(properties.ipAddress)
    | project publicIPid=id, publicIPaddr) on publicIPid'	

$KustoFindVMbyInterfaceID = 'Resources
| where type =~ "microsoft.compute/virtualmachines" 
| extend networkProfile = tostring(properties.networkProfile)
| extend computerName = properties.osProfile.computerName
| mv-expand networkInterfaces = properties.networkProfile.networkInterfaces
| where networkInterfaces.id =~ "%%ID%%"'


# +=================================================================================================+
# |  MAIN BODY																						|
# +=================================================================================================+
$networkInterfaces = @()
$CandidateVMs = @()

# Get current IP address and name
$MyActiveIP = (Test-Connection -ComputerName (hostname) -Count 1).IPV4Address.IPAddressToString
$MyName = $env:computername

# Get all IP addresses on this VM
$AllMyIP = Get-NetIPAddress -AddressFamily IPv4 


# Find the VM with our IP address
# If we get more than one response, there may be several VMs with the same IP address in different VNETs...
$Query = $KustoFindbyIP.Replace('%%IP%%', $MyActiveIP)
$networkInterfaces += Search-AzGraph -Query $Query

foreach ($interface in $networkInterfaces)
{
	$Query = $KustoFindVMbyInterfaceID.Replace('%%ID%%', $interface.id)
	$VM = Search-AzGraph -Query $Query
	$CandidateVMs += $vm
}

# Now find our VM
$MatchingVMs = @()
foreach ($vm in $CandidateVMs)
{
	if (($vm.computerName -like $MyName) -Or ($vm.Name -like $MyName))
		{ $MatchingVMs += $vm }
}

# If there is only one matching VM and the names match then go ahead...
if ($MatchingVMs.Count -eq 1)
{
	write-host -ForegroundColor Yellow -NoNewLine "Current VM is " 
	write-host -NoNewLine $MatchingVMs[0].name
	if ($MatchingVMs[0].name -NotLike $MatchingVMs[0].computerName)
	{ 
		write-host -ForegroundColor Yellow -NoNewLine " (computerName is "
		write-host -NoNewLine $MatchingVMs[0].computerName
		write-host -ForegroundColor Yellow -NoNewLine ")"
	}
	write-host -ForegroundColor Yellow -NoNewLine " in Resource Group "
	write-host $MatchingVMs[0].resourceGroup
	write-verbose "VM id: $($MatchingVMs[0].id)"
	
	if (!$Force)
		{ $x = read-host "Type YES to confirm shutdown and deallocate:" }
	if (($x -notlike "YES") -And !$Force)
	{
		write-host -ForegroundColor Yellow "Shutdown aborted."
		Start-Sleep -Seconds 2
		return;
	}
} 
elseif (($MatchingVMs.Count -eq 0) -And ($CandidateVMs -eq 1))
{
	write-warning "The identified VM name does NOT match the name of this VM"
	write-host -ForegroundColor Yellow -NoNewLine "Your VM name is " 
	write-host  $MyName
	write-host -ForegroundColor Yellow -NoNewLine "The VM identified by IP address is " 
	write-host -NoNewLine $MatchingVMs[0].name
	if ($MatchingVMs[0].name -NotLike $MatchingVMs[0].computerName)
	{ 
		write-host -ForegroundColor Yellow -NoNewLine " (computerName is "
		write-host -NoNewLine $MatchingVMs[0].computerName
		write-host -ForegroundColor Yellow -NoNewLine ")"
	}
	write-host -ForegroundColor Yellow -NoNewLine " in Resource Group "
	write-host $MatchingVMs[0].resourceGroup
	write-verbose "VM id: $($MatchingVMs[0].id)"

	if (!$Force)
		{ $x = read-host "Type YES to confirm shutdown and deallocate:" }
	if (($x -notlike "YES") -And !$Force)
	{
		write-host -ForegroundColor Yellow "Shutdown aborted."
		Start-Sleep -Seconds 2
		return;
	}
}
else
{
	write-warning "$($CandidateVMs.Count) VMs were found with the ip address $MyActiveIP, but none matched this VM name '$MyName'"
	write-host "Please shut this machine down via the Azure portal"
	$x = read-host "Press ENTER to continue"
	return $null
}

# Select the Subscription and VM
Get-AzSubscription -SubscriptionId $MatchingVMs[0].subscriptionId | Select-AzSubscription
$vm = Get-AzVm -Name $MatchingVMs[0].Name -ResourceGroupName $MatchingVMs[0].resourceGroup
$VMStatus = (Get-AzVm -Name $MatchingVMs[0].Name -ResourceGroupName $MatchingVMs[0].resourceGroup -Status).Statuses | Where-Object {$_.Code -like 'PowerState/*'}
write-host -ForegroundColor Green $VMStatus.DisplayStatus
if ($VMStatus.Code -like 'PowerState/running') 
{
	write-host -ForegroundColor Yellow "Shutting down..."
	$x = $vm | Stop-AzVm -NoWait
}
else
{
	write-host ''
	write-warning "Unable to stop VM. State is: $($vmStatus.DisplayStatus.Replace('VM ',''))"
	$x = Read-Host "Press Enter to continue:"
	return $null
}

Start-Sleep -Seconds 5
