#Requires -Version 5
<#
.SYNOPSIS
	Automatically Start and Stop Virtual Machines based on associated tags.
.DESCRIPTION
	This script, when run on a regular scheduled basis (every 15 minutes), will retrieves 
	the tags 'AutoStart' and 'AutoStop' for each virtual machine using a kusto query
	(which can span multiple Azure subscriptions if the user context has permission to do so).
	
	If there is a match on the time window, the VM will be started or stopped, respectively.
	Note that the starting & stopping are performed as asynchronous PowerShell tasks unless
	the -Synchronous switch is specified. This is because starting and stopping synchronously
	can take a minute or two for each VM.

	AutoStart       - Indicates the time at which the associated VM should be started.
	AutoStop        - Indicates the time at which the associated VM should be stopped.

	The tags are in the form:   "[days] HH:MM" where 'HH:MM' is the time (UTC) and 'days'
	(optional) may be either "Weekdays", "Daily", or include the application three-letter
	weekday names (e.g., "Mon,Wed,Fri"). For example, "Mon,Tue,Fri 08:30" will apply to
	Mondays, Tuesdays, and Fridays 08:30 AM UTC.  Multiple schedules may be specified by
	separating each with a semicolon (e.g., "Weekdays 08:00;Sat,Sun 10:30").
	
	The AutoStop time must be at least 30 minutes after the AutoStart time.  To have a VM
	run from Monday 8am to Wed 5pm, specify AutoStart="Mon 08:00" and AutoStop="Wed 17:00".

	The script must be run in a security context such as 'Virtual Machine Operator' which
	allows the enumerations of VMs, their tags, and stop/stop VM capability.  Do not run it more
	than once every 15 minutes as those VMs which are slow to start or stop may be actioned by
	multiple VMScheduler script instances (though it won't have any adverse affect on the VMs).
	
	IMPORTANT: If a time is specified that is NOT within the grace period at the time this
	runbook is executed, then the associated action will NOT be taken. It is recommended that
	this runbook be run at 15 minute intervals and that AutoStart and AutoStop times be
	configured accordingly (i.e., using either :00, :15, :30, or :45).
	
	This script MUST be run in the context of the service principal (ApplicationId) which
	has sufficient privileges to list, start, and stop the applicable virtual machines.
	
.PARAMETER Synchronous
	If specified, then the VM Start & Stop actions are performed synchronously.
	This is useful for debugging purposes.
.PARAMETER WhatIf
	If specified, then VMs are not actually started or stopped.
	
.NOTES
	Author: Lester Waters
	Version: v0.57
	Date: 21-Nov-20
	
	There is a 1 to 2 minute lag between updating a VM's tag and its propagation to the Azure Graph.
	
.LINK
	https://docs.microsoft.com/en-us/azure/automation/automation-solution-vm-management-config   (terrible solution)

#>


# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [switch] $Synchronous		= $false,
	[Parameter(Mandatory=$false)] [switch] $WhatIf  		= $false
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module -Name Az.Accounts
Import-Module -Name Az.Compute


# +=================================================================================================+
# |  CUSTOMIZATIONS     (customize these values for your subscription and needs)					|
# +=================================================================================================+
$TenantId 				= "00000000-0000-0000-0000-000000000000" 		# YOURDOMAIN.onmicrosoft.com
$CertificateThumbprint 	= 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'				# Certificate Thumbprint for App Service Principal
$ApplicationId 			= 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' 				# ApplicationID for your App Service Principal
$TenantName				= 'tenant.onmicrosoft.com'						# tenant name (.onmicrosoft.com)

# My INFO  [DO NOT SAVE THIS IN GITHUB]
# Service principal name is App_Auditor
#$TenantId				= '64e67b02-e271-467d-b69c-392105c29915'			# cloudmail365.onmicrosoft.com
#$CertificateThumbprint 	= 'ACA7AD6907B05438C1087AA562F8ADED1FF27A38'		# 
#$ApplicationId 			= '15d9e263-166e-49bc-bc9f-30f3b263a49f'			# App_VMOperator
#$TenantName					= 'cloudmail365.onmicrosoft.com'


# +=================================================================================================+
# |  CONSTANTS     																					|
# +=================================================================================================+
$GraceEndPeriod	= 15	# Grace period in minutes to wait for VM Start and Stop
$GraceStart		= 10	# Grace period in minutes where VM can be started early 
$GraceStop		= 5		# Grace period in minutes where VM can be stopped early


# +=================================================================================================+
# |  CLASSES																						|
# +=================================================================================================+


# +=================================================================================================+
# |  LOGIN		              																		|
# +=================================================================================================+
# TO DO: Clean this up...
if ((Get-AzContext).Account.Id)
{
	# We are already logged in.
	write-output "Using logged in account ID $((Get-AzContext).Account.Id) ($(Get-AzContext).Account.Type)"
}
elseif (($ApplicationId -And $ApplicationId.Length -eq 36) -and ($CertificateThumbprint))
{
	write-output "Logging in with certificate as AppId: $ApplicationId"
	Login-AzAccount -ServicePrincipal -CertificateThumbprint $CertificateThumbprint `
					-TenantId $TenantId -ApplicationId $ApplicationId
}
elseif (test-path -path 'Runbook_Login.ps1')
{
	# Use common Runbook_Login.ps1 if it exists (via 'Profile' automation variable)
	# This also sets various global varables such as: $Err1, $TenantId, $ReportStorageAccount, etc.
	write-output "Logging in with Runbook_Login.ps1..."
	. ./Runbook_Login.ps1 -Profile 'VMOperator'
	if ($Err1) { write-host "Error returned in Runbook_Login.ps1 - exiting" ; return; }
}
elseif ((get-AzSubscription -ErrorAction SilentlyContinue).Count -eq 0)
{
	$TenantId = (Login-AzAccount).TenantId
}


# +=================================================================================================+
# |  FUNCTIONS																						|
# +=================================================================================================+

# Is-WithinTimeWindow()
# Ensure we are within the time window given a timespec such as "Mon,Web 18:00; Tue,Thu 20:15"
# Known Issue: If script is run just before midnight, then it may fail the day of week match.
# TEST
#   Is-WithinTimeWindow -Verbose -WindowStart (get-date).AddHours(-1) -WindowEnd (Get-Date).AddHours(1) -InputTag 'Thu 11:55'
#   $WindowStart = (Get-Date).AddHours(-1) ; $WindowEnd = (Get-Date).AddHours(2) ; $InputTag = 'Thu 11:55'
#
function Is-WithinTimeWindow
{
    param (
        [Parameter(Mandatory = $true)] [datetime] $WindowStart,
        [Parameter(Mandatory = $true)] [datetime] $WindowEnd,
		[Parameter(Mandatory = $true)] [string]   $InputTag	
		# $ThisWeekDay = Global Input -- day of week as 3 letters in lower case
    )
	
	# write-verbose "  Is-WithinTimeWindow?  -WindowStart '$($WindowStart)'  -WindowEnd '$($WindowEnd)' -InputTag '$InputTag'"   # DEBUG

	# Loop through the different time specifications, separated by semi-colon (;)
	$TimeSpecs = @($InputTag -Split ';')
	foreach ($ts in $TimeSpecs)
	{
		# Separate the weekday names from the time
		$Parts = @($ts -Split ' ')
		$T = @($Parts | Where-Object {$_.Contains(':')} )
		if (!$T)
			{ write-Error "Invalid InputTag '$InputTag' in Is-WithinTimeWindow()" ; return $false }
			
		# Check specified time
		$time = [datetime]::parse($T.Trim())
		if ($time -lt $WindowStart -Or $time -gt $WindowEnd)
			{ break }  # We are outside the time window, so try the next entry
		
		# We are inside the time window but are we in the right day of the week?
		$days = (@($Parts | Where-Object {$_.Contains(':') -eq $False}) -Join ',')	 # Bring back together if there were spaces
		if ($days.Length -eq 0)
			{ return $true }
		elseif (($days.ToLower().Contains("daily") -Or $days.ToLower().Replace("weekdays", "mon,tue,wed,thu,fri").Contains($ThisWeekday)))
			{ return $true }
	}
	return $false
}


# +=================================================================================================+
# |  SCRIPT BLOCKS																					|
# +=================================================================================================+
#
# ScriptBlob for Start-Job cmdlet - OLD APPROACH
#
$scriptBlockOLD = {
    param ([string]$Id, [string]$VMName, [string]$Action)
	Write-Output "Requested VM $Action for $VMName"
	$p = $Id.Split("/")			# $p[2] = SubscriptionId;  $p[4] = ResourceGrOup;  $p[8] = VMName
	# When Run as a Job, Login-AzAccount is required as well as Subscription Selection
	$c = Get-AzContext -ErrorAction SilentlyContinue		# Are we logged in already?
	if ($c -eq $null -Or $c.Subscription -eq $null -Or $c.Subscription.Id -eq $null)
	{
		# Certificate-based Login
		write-output "Logging in as AppId: %APPID%"
		Login-AzAccount -TenantId "%TID%" -ServicePrincipal -CertificateThumbprint "%CTP%" -ApplicationId "%APPID%" -ErrorAction Stop -Verbose 
		# Select the subscription by extracting it from the ResourceID
		Select-AzSubscription -Subscription $p[2] -ErrorAction Stop 
	}
	$x = Select-AzSubscription -Id $p[2] -ErrorAction Stop
	# Start or stop the VM
	try {
		if ($Action -like "Start") { $r = Start-AzVm -Id $Id -Name $VMName -ErrorAction Stop }
		if ($Action -like "Stop")  { $r = Stop-AzVm  -Id $Id -Name $VMName -Force -ErrorAction Stop }
	}
	Catch {Throw "VM $Action failed for $VMName - $Error"; return }
	if ($r.Error) { Throw "VM $Action failed for $VMName - $($r.Error)" ; return }
	Write-Output "VM $Action completed for $VMName"
}

# This scriptblock is used to start the VM using the service principal.
# But now, Start-AzVm has a NoWait option... So this may not be needed.
# $ScriptBlock = [scriptblock]::Create($ScriptBlockText)
$scriptBlockText = '{
     param ([string]$Id, [string]$VMName, [string]$Action)
	Write-Output "Requested VM $Action for $VMName"
	# When Run as a Job, Login-AzAccount is required as well as Subscription Selection
	$c = Get-AzContext -ErrorAction SilentlyContinue
	if ($c -eq $null -Or $c.Subscription -eq $null -Or $c.Subscription.Id -eq $null)
	{
		# Certificate-based Login
		write-output "Logging in as AppId: %APPID%"
		Login-AzAccount -TenantId "%TID%" -ServicePrincipal -CertificateThumbprint "%CTP%" -ApplicationId "%APPID%" -ErrorAction Stop -Verbose 
		# Select the subscription by extracting it from the ResourceID
		$p = $Id.Split("/")
		Select-AzSubscription -Subscription $p[2] -ErrorAction Stop 
	}
	$x = Select-AzSubscription -Id $SubId -ErrorAction Stop
	# Start or stop the VM
	try {
		if ($Action -like "Start") { $r = Start-AzVm -Id $Id -Name $VMName -ErrorAction Stop }
		if ($Action -like "Stop")  { $r = Stop-AzVm  -Id $Id -Name $VMName -Force -ErrorAction Stop }
	}
	Catch {Throw "VM $Action failed for $VMName - $Error"; return }
	if ($r.Error) { Throw "VM $Action failed for $VMName - $($r.Error)" ; return }
	Write-Output "VM $Action completed for $VMName"
}'

# Fill in TenantID, CertificateThumbprint, and ApplicationId
$scriptBlockText = $scriptBlockText.Replace('%TID%',$TenantID).Replace('%CTP%',$CertificateThumbprint).Replace('%APPID%',$ApplicationID)
$ScriptBlock = [scriptblock]::Create($ScriptBlockText)

# If we want to double-check the tags at run=time, then use the following:
#	# Array indexing $vm.Tags["AutoStart"] is case SeNsItIvE so we need to find the tag case-insensitively
#	$AutoStartTag = $vm.Tags.Keys | Where-Object { $_ -like "AutoStart"} 
#	if ($AutoStartTag) { $AutoStartTag = $vm.Tags[$AutoStartTag] }
#	$AutoStopTag = $vm.Tags.Keys | Where-Object { $_ -like "AutoStop"} 
#	if ($AutoStopTag) { $AutoStopTag= $vm.Tags[$AutoStopTag] }


# +=================================================================================================+
# | MAIN																							|
# +=================================================================================================+

$ScriptStart   = (Get-Date).ToUniversalTime()   			# Execution start time for this script
write-output "Runbook_VMScheduler script started at $ScriptStart UTC"

# Grace period windows
$GraceEndTime  = $ScriptStart.AddMinutes($GraceEndPeriod)   # Grace Period AFTER for both Start and Stop VM
$StartupGrace  = $ScriptStart.AddMinutes(-$GraceStart)   	# Grace Period BEFORE for Start
$ShutdownGrace = $ScriptStart.AddMinutes(-$GraceStop)    	# Grace Period BEFORE for Shutdown
$ThisWeekday   = $ScriptStart.DayOfWeek.ToString().SubString(0,3).ToLower()

# Statistical variables
$StartupCount	= 0			# Count of VMs started in this run
$ShutdownCount	= 0			# COunt of VMs stopped in this run
$VMCount		= 0			# Count of VMs with an AutoStart or AutoStop tag
$Completed		= 0			# 
$Jobs 			= @()		# PowerShell jobs queued
$Error.Clear()



# +=================================================================================================+
# | Query for all VMs containing an AutoStart or AutoStop tag (or both)	using Resource Graph		|
# | Results are joined with subscription name for logging purposes.									|
# +=================================================================================================+
$ApplicableVMs = @()
$KustoQuery = "Resources 
| where type =~ 'Microsoft.Compute/virtualMachines' 
  and (tags contains 'AutoStart' or tags contains 'AutoStop')
| extend AutoStart = tostring(tags['AutoStart'])
| extend AutoStop = tostring(tags['AutoStop'])
| extend AutoStopWebhook = tostring(tags['AutoStopWebhook'])
| join kind=leftouter (ResourceContainers | where type=~'microsoft.resources/subscriptions' 
	| project SubName=name, subscriptionId) on subscriptionId 
| project subscriptionId, name, resourceGroup, location,
	vmSize = tostring(properties.hardwareProfile.vmSize), 
	osType = tostring(properties.storageProfile.osDisk.osType),
	hostId = tostring(properties.host.id), 
	AutoStart,AutoStop,AutoStopWebhook,tags,properties, id"

# Query for applicable VMs up to 1000 at a time (5000 is max allowed by query)
$SkipCount = 0
Do 
{	# Search-AzGraph doesn't like a -SkipCount of zero
	if ($SkipCount -eq 0)
		{ $r = Search-AzGraph -query $KustoQuery -First 1000 } # -ErrorAction SilentlyContinue
	else
		{ $r = Search-AzGraph -query $KustoQuery -First 1000 -Skip $SkipCount } # -ErrorAction SilentlyContinue
	$ApplicableVMs += ,$r
	$SkipCount += 1000
}
Until ($r.Count -lt 1000)

if ($ApplicableVMs.Count -eq 0)
{
	write-output "No VMs found with AutoStart or AutoStop tag (for any day/time)"
	return
}
# $ApplicableVMs | Out-GridView		# DEBUG


# +-----------------------------------------------------------------------------------------------------+
# |  Loop through $ApplicableVMs to examine the AUtoStart and AutoStop tags.							|
# |  If any apply, the spawn a task to start or stop the VM unless -Synchronous switch was specified	|
# +-----------------------------------------------------------------------------------------------------+
# TODO: CONDENSE THIS BLOCK 
$CurrentSubscription = ""
foreach ($vm in ($ApplicableVMs | Sort-Object -Property subscriptionId,name))
{
	# Ensure we don't Start and Stop a VM in the same run of this script!
	$VMStarted = $false
		
	# Informational Tracking
	if ($vm.AutoStart -Or $vm.AutoStop)
		{ $VMCount++ ; write-verbose "Checking: $($vm.Name)  $($vm.ResourceGroup)  $($vm.Location)  $($vm.PowerState) - AUTOSTART: $($vm.AutoStart)   AUTOSTOP: $($vm.AutoStop)" }

	# Check on AUTOSTART
	if ($vm.AutoStart -And (Is-WithinTimeWindow -WindowStart $StartupGrace -WindowEnd $GraceEndTime -InputTag $vm.AutoStart))
	{
		# We need to START this VM!
		if ($WhatIf)
		{
			write-host -ForegroundColor Yellow "   WHATIF: Would have STARTED VM: $($vm.Name)   $($vm.ResourceGroup)    $($vm.Location)   $($vm.vmSize)"
		} 
		else
		{
			# What we don't have is .PowerState so we don't know if the VM is currently running or not, so get the PowerState
			if ($CurrentSubscription -NotLike $vm.subscriptionId)
			{
				# Select the subscription
				$x = Select-AzSubscription -Subscription $vm.subscriptionId -ErrorAction Stop 
				$CurrentSubscription = $vm.subscriptionId
			}
			$vmDetail = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroup -Status
			write-host "Get-AzVM -Name '$($vm.Name)' -ResourceGroupName '$($vm.ResourceGroup)' -Status"  # DEBUG
			if (!$vmDetail)
			{
				write-warning "No VM detail found for: $($vm.id)"
				break
			}
			if ($vmDetail.Statuses.Code -NotContains 'ProvisioningState/succeeded')
			{
				write-warning "VM is not in 'ProvisioningState/succeeded': $($vm.Id) "
				break
			}
			# Is the VM already running?
			if ($vmDetail.Statuses.Code -NotContains 'PowerState/running')
			{
				if ($Synchronous)
				{
					# SYNCHRONOUS is slow as you have to wait for action to complete					
					# EFFECTIVELY: $x = Start-AzVM -Id $vm.Id -Name $vm.Name -Confirm 
					Write-Output "  STARTING VM: $($vm.Name)   $($vm.ResourceGroup)    $($vm.Location)   $($vm.vmSize)"
					# & $scriptBlock -Id $vm.Id -VMName $vm.Name -Action "Start"
					$x = Start-AzVM -Id $vm.Id -Confirm -ErrorAction Continue
					$Completed++
				}
				else
				{
					Write-Output "  STARTING VM: $($vm.Name)   $($vm.ResourceGroup)    $($vm.Location)   $($vm.vmSize)"
					# $j = Start-Job -ScriptBlock $scriptBlock -ArgumentList @($vm.Id,$vm.Name,'Start')   # | wait-Job
					$j = Start-AzVM -Id $vm.Id -Verbose -AsJob 
					$j | Add-Member -NotePropertyName 'LastState' -NotePropertyValue $j.State
					write-Output "     Job $($j.Id) started."
					# $j | select *    # DEBUG
					$Jobs += $j
				}
			}
			else
			{
				write-output "  VM is already started: $($vm.Id)"
			}
		}
		$StartupCount++
		$VMstarted = $true
	}
	
	# Now check on AUTOSTOP - Don't stop a VM we just started due to a small time window either
	if ($vm.AutoStop -And !$VMStarted -And (Is-WithinTimeWindow -WindowStart $ShutdownGrace -WindowEnd $GraceEndTime -InputTag $vm.AutoStop))
	{
		# We need to STOP this VM!
		if ($WhatIf)
		{
			write-host -ForegroundColor Yellow "   WHATIF: Would have STOPPED VM: $($vm.Name)   $($vm.ResourceGroupName)    $($vm.Location)   $($vm.PowerState)"
		} 
		else
		{
			# What we don't have is .PowerState so we don't know if the VM is currently running or not, so get the PowerState
			if ($CurrentSubscription -NotLike $vm.subscriptionId)
			{
				# Select the subscription
				$x = Select-AzSubscription -Subscription $vm.subscriptionId -ErrorAction Stop 
				$CurrentSubscription = $vm.subscriptionId
			}
			$vmDetail = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroup -Status
			if (!$vmDetail)
			{
				write-warning "No VM detail found for: $($vm.id)"
				break
			}
			if ($vmDetail.Statuses.Code -NotContains 'ProvisioningState/succeeded')
			{
				write-warning "VM is not in 'ProvisioningState/succeeded': $($vm.Id) "
				break
			}
			if ($vmDetail.Statuses.Code -Contains 'PowerState/running')
			{
				if ($Synchronous)
				{
					# SYNCHRONOUS is slow as you have to wait for action to complete					
					# EFFECTIVELY: $x = Stop-AzVM -Id $vm.Id -VMName $vm.Name -Confirm  
					Write-Output "  STOPPING VM: $($vm.Name)   $($vm.ResourceGroupName)    $($vm.Location)   $($vm.PowerState)  (Synchronous)"
					# & $scriptBlock -Id $vm.Id -VMName $vm.Name -Action "Stop" 
					$x = Stop-AzVM -Id $vm.Id -Confirm -ErrorAction Continue
					$Completed++
				}
				else
				{
					Write-Output "  STOPPING VM: $($vm.Name)   $($vm.ResourceGroupName)    $($vm.Location)   $($vm.PowerState)"
					# $j = Start-Job -ScriptBlock $scriptBlock -ArgumentList @($vm.Id,$vm.Name,'Stop')   # | wait-Job
					$j = Stop-AzVM -Id $vm.Id -Force -Verbose -AsJob 
					$j | Add-Member -NotePropertyName 'LastState' -NotePropertyValue $j.State
					write-Output "     Job $($j.Id) started."
					# $j | select *     # DEBUG
					$Jobs += $j
				}
			}
			else
			{
				write-output "  VM is already stopped: $($vm.Id)"
			}
		}
		$ShutdownCount++
	}
}

# $jobs | fl 	# DEBUG


# +---------------------------------------------------------+
# |  Wait up to 10 minutes for all of the jobs to complete	|
# +---------------------------------------------------------+
$ExitStates = @('Failed', 'Completed', 'Blocked')  
if ($Jobs.Count -gt 0)
{
	Write-Host "`nWaiting for $($Jobs.Count) job(s) to complete.." 
	$Timeout = (Get-Date).AddMinutes(10)
	Do
	{
		$Completed = 0
		Start-Sleep -Seconds 10		# Wait 10 seconds between checks
		foreach ($j in $Jobs)
		{
			$j1 = (Get-Job -Id $j.Id)
			if ($j.LastState -NotLike $j1.State)
			{
				write-output "  Job $($j.id) $($j.Command) : $($j.LastState) -> $($j1.State)"
				# $j1 | fl		# DEBUG
				$j.LastState = $j1.State
			}
			if ($ExitStates -Contains $j1.State) { $Completed++ }
		}
	}
	while ($Completed -lt $Jobs.Count -And (Get-Date) -lt $TimeOut)
}


# Loop through jobs and get the results
foreach ($j in $Jobs)
{
	$j1 = (Get-Job -Id $j.Id)
	Write-Verbose "  Job $($j.id)  $($j1.State)  $($j1.ChildJobs[0].jobStateInfo.Reason)" 
	$r = Receive-Job -Id $j.Id 
	# $r | fl  # DEBUG
	$r.Error | fl
	if ($j1.State -like 'Failed' -Or $j1.State -like 'Blocked')
	{ 
		Write-Error "Job $($j.id) $($j1.State): $($j1.ChildJobs[0].jobStateInfo.Reason)" 
		$j1 | fl
	}
	elseif ($j1.State -like 'Completed')
		{ Write-Output "Job $($j.id) Completed: $($j1.ChildJobs[0].Output)" }
	else
		{ Write-Error "Job $($j.id) Incomplete: $($j1.State) - $($j1.ChildJobs[0].Output)" }
}


$Finish = (Get-Date).ToUniversalTime()
write-output "`nScript finished at $Finish UTC - $VMcount VMs checked; $StartupCount VM START requests; $ShutdownCount VM STOP requests; $Completed Jobs."
