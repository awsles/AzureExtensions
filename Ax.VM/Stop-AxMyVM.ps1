#Requires -Version 5
<#
.SYNOPSIS
	Stops the VM on which this is running.
.DESCRIPTION
	This will stop the currently running virtual machine.
	This is done by using the Azure Instance Metadata Service (IMDS) Endpoint
	to identify the machine. If this fails, the fallback is to locate the virtual machine
	by its private IP address. A secondary check is done to verify the VM name.
	If the name of the VM in Azure does not match, then a warning is displayed.
	
	The service principal needs to have sufficient rights to enumerate the current VM
	and network interfaces as well as the rights to shutdown the VM.
	
.PARAMETER Force
	If set, the user is not asked to confirm the shutdown.
	
.PARAMETER Wait
	Indicates the name of a running process to wait on.  If the process is running,
	then the script will sleep for 120 seconds and try again.
	
	You can create a Windows Desktop Shortcut with the -Wait pamater by setting the Target to:
	C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -command "& C:\Users\Overlord\Desktop\Stop-AxMyVM.ps1 -Wait PROCESSNAME"

.NOTES
	Author: Lester Waters
	Version: v0.09 
	Date: 02-Jan-22
	
	To run powershell as one-click, apply the following registry setting:
	[HKEY_CLASSES_ROOT\Microsoft.PowerShellScript.1\Shell\Open\Command]
	@="\"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -noLogo -ExecutionPolicy unrestricted -file \"%1\""


.LINK
	https://powershell.org/2015/08/list-users-logged-on-to-your-machines/
	https://docs.microsoft.com/en-us/azure/virtual-machines/windows/instance-metadata-service
	https://docs.microsoft.com/en-us/azure/active-directory/devices/howto-vm-sign-in-azure-ad-windows  # Useful info

	Azure – https://docs.microsoft.com/en-us/azure/virtual-machines/windows/instance-metadata-service
	AWS – https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-identity-documents.html
	GCP – https://cloud.google.com/compute/docs/storing-retrieving-metadata
#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [switch] $Force 				= $false,
	[Parameter(Mandatory=$false)] [string] $Wait
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.ResourceGraph


# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+
# Service principal name is <<insert_name>>
$TenantId				= '**SET_THIS_FIRST**'			# Your Azure Tenant ID
$CertificateThumbprint	= '**SET_THIS_FIRST**'			# Certificate Thumbprint for App Service Principal
$ApplicationId			= '**SET_THIS_FIRST**'			# ApplicationID for your App Service Principal



# +=================================================================================================+
# |  Wait																							|
# +=================================================================================================+
if ($Wait)
{
	if (!(Get-Process -Name $Wait -ErrorAction SilentlyContinue))
	{
		write-warning "No process named '$Wait' was found. Aborting Shutdown."
		return $null
	}
	write-host -ForegroundColor Yellow -NoNewLine "Waiting for process '$Wait' to complete"
	While (Get-Process -Name $Wait -ErrorAction SilentlyContinue)
	{
		Start-Sleep -Seconds 120
		write-host -NoNewLine '.'
	}
	write-host " Done"
}
RETURN

# +=================================================================================================+
# |  Disconnect VPN																					|
# +=================================================================================================+
$vpnApp = 'C:\Program Files\NordVPN\Nordvpn.exe'
$arguments = '--disconnect'
if (test-path -path "C:\Program Files\NordVPN\Nordvpn.exe")
{
	write-host -ForegroundColor Yellow "Disconnecting VPN..."
	Invoke-Command -ScriptBlock { & $vpnApp $arguments }
	Start-Sleep -Seconds 2
}


# +=================================================================================================+
# |  LOGIN																						|
# +=================================================================================================+
write-host -ForegroundColor Yellow "Logging in..."
$Error.Clear()
Try {
	Login-AzAccount -ServicePrincipal -CertificateThumbprint $CertificateThumbprint `
					-TenantId $TenantId -ApplicationId $ApplicationId `
					-ErrorAction Stop
}
Catch [System.ArgumentNullException] {
	write-host -ForegroundColor Yellow 'Invalid or null parameter to Login-AzAccount. Be sure that $TenantId, $CertificateThumbprint, and $ApplicationId are appropriately configured.'
	Start-Sleep -Seconds 15
	return
}
Catch {
	write-host -ForegroundColor Yellow "Unable to login using service principal"
	write-host "EXCEPTION: [$($Error[0].exception.GetType().fullname)]: $($Error[0].Exception.Message)"
	Start-Sleep -Seconds 15
	return
}


# +=================================================================================================+
# |  KUSTO QUERY DEFINITIONS																		|
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


# +-----------------------------------------------------------------+
# | Find VM using AZURE Instance Metadata Service (IMDS) Endpoint	|
# +-----------------------------------------------------------------+
$VMInfo 			= Invoke-RestMethod -Headers @{"Metadata"="true"}  -UseBasicParsing -Method GET -Uri 'http://169.254.169.254/metadata/instance?api-version=2020-06-01' 
$VMTenantId			= (Invoke-RestMethod -Headers @{"Metadata"="true"} -UseBasicParsing -Method GET -Uri 'http://169.254.169.254/metadata/identity/info?api-version=2018-02-01').TenantId
$VMPublicIP			= Invoke-RestMethod -Headers @{"Metadata"="true"}  -UseBasicParsing -Method GET -Uri "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text"
# $AccessToken		= Invoke-RestMethod -Headers @{"Metadata"="true"}  -UseBasicParsing -Method GET -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?resource=urn:ms-drs:enterpriseregistration.windows.net&api-version=2018-02-01'

# Verify TenantIDs
if ($VMTenantId -And ($TenantId -ne $VMTenantId))
{
	write-warning "Service Principal TenantID does not match VM TenantID - VM cannot be deallocated"
	Start-Sleep -Seconds 15
	return;
}

# 
if ($VMInfo.Compute)
{
	write-host "Found VM via IMDS endpoint"
	$ThisVM = $VmInfo.Compute
}
else
{
	# +-----------------------------------------------------------------+
	# | Find VM using Kusto (fallback method)							|
	# +-----------------------------------------------------------------+
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

	# Loop through the network interfaces returned
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

	if ($MatchingVMs.Count -eq 1)
	{
		# If there is only one matching VM and the names match...
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
		$ThisVM	= ($MatchingVMs[0] | Add-Member -NotePropertyName 'resourceGroupName' -NotePropertyValue $MatchingVMs[0].resourceGroup)
	} 
	elseif (($MatchingVMs.Count -eq 0) -And ($CandidateVMs -eq 1))
	{
		# Only the IP address matched a single VM with a different name...
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
		$ThisVM	= ($MatchingVMs[0] | Add-Member -NotePropertyName 'resourceGroupName' -NotePropertyValue $MatchingVMs[0].resourceGroup)
	}
	else
	{
		# No decent match was found...
		write-warning "$($CandidateVMs.Count) VMs were found with the ip address $MyActiveIP, but none matched this VM name '$MyName'"
		write-host "Please shut this machine down via the Azure portal"
		$x = read-host "Press ENTER to continue"
		return $null
	}
}


# +-----------------------------------------------------------------+
# | Shutdown $ThisVM												|
# +-----------------------------------------------------------------+
$x = Get-AzSubscription -SubscriptionId $ThisVM.subscriptionId | Select-AzSubscription
$vm = Get-AzVm -Name $ThisVM.Name -ResourceGroupName $ThisVM.resourceGroupName
$VMStatus = (Get-AzVm -Name $ThisVM.Name -ResourceGroupName $ThisVM.resourceGroupName -Status).Statuses | Where-Object {$_.Code -like 'PowerState/*'}
write-host -ForegroundColor Green $VMStatus.DisplayStatus
if ($VMStatus.Code -Notlike 'PowerState/running') 
{
	write-host ''
	write-warning "Unable to stop VM. State is: $($vmStatus.DisplayStatus.Replace('VM ',''))"
	$x = Read-Host "Press Enter to continue:"
	return $null
}

# Display any logged in users
# https://powershell.org/2015/08/list-users-logged-on-to-your-machines/
# (1) gwmi Win32_LoggedOnUser
# (2) query.exe user
$Users = Query User
if ($Users.Count -gt 2)
{
	write-host "`n"
	write-warning "Other users are logged into this VM"
	write-host "`n Review the logged in users and status below:`n"
	write-host -ForegroundColor Yellow $Users[0]
	write-host -ForegroundColor Yellow ('=' * 84)
	for ($i=1; $i -lt $Users.Count; $i++)
	{ write-host $Users[$i] }
	write-host "`n"
}

# Shutdown
write-host -ForegroundColor Yellow "Shutting down..."
if ($Force)
	{ $x = $vm | Stop-AzVm -NoWait -Force }
else
	{ $x = $vm | Stop-AzVm -NoWait -Confirm }
Start-Sleep -Seconds 5
