#Requires -Version 5
<#
.SYNOPSIS
	Scans all resources ensuring each has a "CreatedBy" and a "CreationDate" tags.
	The creator is (crudely) identified by the earliest successful activity log action.
.DESCRIPTION
	This script, when run on a regular scheduled basis (daily), retrieves all Azure resources
	WITHOUT the tag 'CreatedBy'.  Then the ActivityLog is scanned for the earliest
	'Succeeded' event and the CreateBy tag is applied.

	CreatedBy       - Indicates the User Principal Name of the creator.
					  For example, "bacsger@mydomain.net"
	CreatedTime    - Indicates the Date & Time when the resource was created and action,
					  the OperationName, and the event CorrelationId, separated by spaces.
	                  For example, "10/08/2017 14:30:09 UTC Microsoft.Resources/marketplace/purchase/action be751098-cc00-40e8-9273-f3c760227142"

	The script must be run in a security context which allows tags to be read and written
	for all resources. "Tag Contributor" role is required.
	
	Note that for resources older than the history in the ActivityLog, the 'CreatedBy' tag
	will be set to '-UNKNOWN-'.
	
.PARAMETER Force
	If specified, then all entries are updated, even if there is an existing tag.
.PARAMETER Verbose
	If specified, then progress is displayed. Useful for interactive mode.
	
.NOTES
	Author: Lester Waters
	Version: v0.75
	Date: 20-Nov-20
	
	TO DO:  If the ActivityLog is configured with a storage account, then optionally look back further
	using data in the storage account.
	
.LINK
	https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-audit
	https://technet.microsoft.com/en-us/library/ee692803.aspx
	https://docs.microsoft.com/en-us/azure/azure-monitor/platform/activity-log
#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [switch] $Force   = $true,
	[Parameter(Mandatory=$false)] [switch] $WhatIf  = $false
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.ResourceGraph


# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+
$TenantId				= '**SET_THIS_FIRST**'			# Your Azure Tenant ID
$CertificateThumbprint	= '**SET_THIS_FIRST**'			# Certificate Thumbprint for App Service Principal
$ApplicationId			= '**SET_THIS_FIRST**'			# ApplicationID for your App Service Principal

# My INFO  [DO NOT SAVE THIS IN GITHUB]
# Service principal name is App_Auditor
# $TenantId				= 'f55850c9-aa72-40b9-b21a-a7e7abc0897e'			# Your Azure Tenant ID


# +=================================================================================================+
# |  LOGIN		              																		|
# +=================================================================================================+
# Use common Runbook_Login.ps1 if it exists.
# This also sets various global varables such as: $Err1, $TenantId, $ReportStorageAccount, etc.
if ((Get-AzContext).Account.Id)
{
	# We are already logged in.
	write-output "Using logged in account ID $((Get-AzContext).Account.Id) ($(Get-AzContext).Account.Type)"
}
elseif (test-path -path 'Runbook_Login.ps1')
{
	write-output "Logging in with Runbook_Login.ps1..."
	. ./Runbook_Login.ps1
	if ($Err1) { write-host "Error returned in Runbook_Login.ps1 - exiting" ; return; }
}
elseif (($ApplicationId -And $ApplicationId.Length -eq 36) -and ($CertificateThumbprint))
{
	write-output "Logging in with certificate..."
	Login-AzAccount -ServicePrincipal -CertificateThumbprint $CertificateThumbprint `
					-TenantId $TenantId -ApplicationId $ApplicationId
}
elseif ((get-AzSubscription -ErrorAction SilentlyContinue).Count -eq 0)
{
	$TenantId = (Login-AzAccount).TenantId
}


# +=================================================================================================+
# |  KUSTO QUERY DEFINITIONS																		|
# +=================================================================================================+

$KustoResourcesWithoutCreatedBy = 'resources
| where properties.provisioningState =~ "Succeeded" and tostring(tags) !contains ''"CreatedBy"''
| extend
	resourceId = id,
	resourceType = type
| join kind=leftouter (ResourceContainers | where type =~ "microsoft.resources/subscriptions"
    | project subscriptionName=name, subscriptionId) on subscriptionId'

$KustoContainersWithoutCreatedBy = 'resourcecontainers
| where properties.provisioningState =~ "Succeeded" and tostring(tags) !contains ''"CreatedBy"''
| extend
	resourceId = id,
	resourceType = type
| join kind=leftouter (ResourceContainers | where type =~ "microsoft.resources/subscriptions"
    | project subscriptionName=name, subscriptionId) on subscriptionId'

# Wipe tag name with something unlikely if -Force
if ($Force)
{
	$KustoResourcesWithoutCreatedBy		= $KustoResourcesWithoutCreatedBy.Replace('CreatedBy','aayybb')
	$KustoContainersWithoutCreatedBy	= $KustoContainersWithoutCreatedBy.Replace('CreatedBy','aayybb')
}


# +=================================================================================================+
# |  EXCLUSIONS																						|
# +=================================================================================================+
# List of ResourceTypes that we EXCLUDE from tagging (tagging not required or supported)
$Exclusions = @()
$Exclusions += "Microsoft.Compute/virtualMachines/extensions"
$Exclusions += "Microsoft.OperationsManagement/solutions"
$Exclusions += "Microsoft.VisualStudio/account"
$Exclusions += "Microsoft.ClassicStorage/storageAccounts"
$Exclusions += "Microsoft.insights/alertrules"
$Exclusions += "microsoft.insights/alertrules"
$Exclusions += "Microsoft.Databricks/workspaces"


# +=================================================================================================+
# |  FUNCTIONS																						|
# +=================================================================================================+
Function ConvertTo-HashTable
{
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	param(
		[Parameter(Mandatory=$true)] [PSCustomObject] $InputObject
	)
	
    $hash = @{}
     $InputObject | Get-Member -MemberType Properties | SELECT -exp "Name" | % {
                $hash[$_] = ($InputObject | SELECT -exp $_)
      }
      $hash
}

Function TagResources
{
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	param(
		[Parameter(Mandatory=$true)] [PSObject] $InputObject
	)
	
	$Results = @()
	$Subscriptions	= $InputObject.subscriptionId | Select-Object -Unique
	
	ForEach ($sub in $Subscriptions)
	{
		write-host -ForegroundColor Cyan "Processing subscription: $sub"
		$x = Select-AzSubscription -Subscription $sub -ErrorAction Stop
		[Console]::Out.Flush() 
		
		# Loop through the untagged Resources
		$TheseResources = $InputObject | Where-Object {$_.subscriptionId -like $sub}
		ForEach ($r in $TheseResources)
		{
			# Check the ResourceType against the exclusions list and whether the .Tags property exists at all
			if (!($Exclusions -Contains $r.type))
			{		
				# Extract the Tags (Search-AzGraph returns these as a string and NOT a hashtable
				# so conversion will be necessary
				if ($r.Tags -eq $null)
					{ $Tags = @{} }   # Use @{} so Tag functions don't bomb out
				else
				{
					# Convert tags string to hashtable
					$Tags = ConvertTo-hashtable -InputObject $r.Tags
				}
				
				# Array indexing $vm.Tags["CreatedBy"] is case SeNsItIvE so we need to find the tag case-insensitively
				$CreatedBy = $Tags.Keys | Where-Object { $_ -like "CreatedBy"} 
				if ($CreatedBy)
				{
					$CreatedBy = $Tags[$CreatedBy]
					$OriginalCreatedBy = $CreatedBy
				}
				else
				{
					$OriginalCreatedBy = "-Unknown-"
				}
				$CreatedTime = $Tags.Keys | Where-Object { $_ -like "CreatedTime"} 
				if ($CreatedTime)
					{ $CreatedTime = $Tags[$CreatedTime] }
				
				$OriginalCreatedBy = "-Unknown-"  # DEBUG
				write-output "PROCESSING: $($r.ResourceId)"
				
				# NOTE: There are a lot of different resource types... many of which may not generate any event logs
				# as they may be indirectly created, etc.  We will want to limit the resources that we tag to the most
				# strategic: VMs, Disks, Storage Accounts, Data Lakes, SQL Servers, NICs, network stuff, etc.

				# Check on CreatedBy
				if (!$CreatedBy -Or $Force)
				{
					# First, we must look into the event Log for this resource, going back 90 days
					$Events = (Get-AzLog -ResourceId $r.ResourceId -Status "Succeeded" -StartTime (Get-Date).AddDays(-89) -WarningAction SilentlyContinue) `
                                | Where {$_.Authorization.Action -ne "Microsoft.Resources/tags/write"}  # ALTERNATE: $_.OperationName.Value or $_.properties.content.message
					if ($Events.Count -gt 0)
					{
						
						# For now, we assume that the earliest event is the "creation" event
						# This may not be true is the resource is more than 90 days old (activity log only retains 90 days)
						# Also, if a resource is created and deleted, and then re-created with the same name
						# then the earliest action is still the one that is taken.  This will need to be
						# fixed in a future iteration of this script, possibly by looking at the ObjectId of the
						# resource and comparing it with the objectId of the object in the event log (using -DetailedOutput).
						
						$LastEventIndex = $Events.Count - 1
						$CreatedBy = $Events[$LastEventIndex].Caller
						if ($CreatedBy -eq $null -Or $CreatedBy.Length -eq 0) 
						{
							# Check for "securitydata" resource group which is created by the Azure Security Center service
							if ($r.ResourceGroupName -like "securitydata")
								{ $CreatedBy = "Azure Security Center Service" }
							# else see if it is a managed disk (which does not record the creator properly)
							elseif ($r.ResourceType -like "Microsoft.Compute/disks")
							{
								$Disk = Get-AzDisk -ResourceGroupName $r.ResourceGroupName -Name $r.Name
								if ($Disk.OwnerId -ne $null -And $Disk.OwnerId.Length -gt 10)
									{ $CreatedBy = (Get-AzLog -ResourceId $Disk.OwnerId -Status "Succeeded" -StartTime (Get-Date).AddDays(-89) -WarningAction SilentlyContinue -ErrorAction Continue | select-object -last 1).Caller }
								if ($CreatedBy -eq $null -Or $CreatedBy.Length -eq 0) { $CreatedBy = "(see associated VM)" }
							}
							else
								{ $CreatedBy = $OriginalCreatedBy }
						}
						else
							{ $CreatedTime = ([String] $Events[$LastEventIndex].EventTimeStamp) }
						
					}
					else
					{
						# No events found (unusual but it does happen)
						$CreatedBy    = $OriginalCreatedBy
					}

					# Write the tags back out to the Resource
					if ($WhatIf)
					{
						# WriteLogFile -Action "WhatIf:UpdateTag:CreatedBy" -Info1 $CreatedBy -Info2 $CreatedTime -ResourceId $r.ResourceId 
						write-host -ForegroundColor Yellow -NoNewLine "   WHATIF: "
						write-host "   CreatedBy: $CreatedBy       CreatedTime: $CreatedTime"
						$UpdateStatus = "Updated [WhatIf]"
					} 
					else
					{
						# update the tags (or add the property if it doesn't already exist)
						write-output "    ==>  CreatedBy: $CreatedBy    CreatedTime: $CreatedTime"
					
						# Create the new tags...
						$Tags.Remove("CreationInfo")						# Remove LEGACY tag
						$Tags.Remove("CreationTime")						# Remove LEGACY tag
						$Tags.Remove("CreatedBy")							# Remove it so that we get the Upper/Lower Case we want
						$Tags.Set_Item("CreatedBy", $CreatedBy)      		# $Tags["CreatedBy"]    = $CreatedBy
						if ($CreatedTime)
							{ $Tags.Set_Item("CreatedTime", $CreatedTime) }   	# $Tags["CreatedTime"]    = $CreatedTime
						
						
						# Write the changes...
						$Err1 = $null
						try {
							# $x = Set-AzResource -id $r.ResourceId -Tag $Tags -Force -ErrorAction stop -ErrorVariable Err1 # -Verbose
							$x = Update-AzTag -ResourceId $r.ResourceId -Tag $Tags -Operation Replace	-ErrorAction stop -ErrorVariable Err1	# Only requires TagContributor role permission 
							$UpdateStatus = "Updated"
						}
						catch {
							$UpdateStatus = "Update Error" 
							Write-warning "Update Error: $($Err1.Message)"
							write-output "Update FAILED for resource type: $($r.type)"
						}
					}
					$UpdateCount++
				}
				else
				{ 
					write-verbose " TAG EXISTS: $($r.ResourceType) - $($r.Name) - $($r.ResourceGroupName) - $CreatedBy"
					$UpdateStatus = "Existing Tag"
				}
				
				# Record the entry for Out-GridView at the end...
				$Property = [ordered]@{
					SubscriptionName = $r.subscriptionName;
					ResourceName = $r.Name;
					ResourceGroupName = $r.ResourceGroupName;
					ResourceType = $r.ResourceType;
					CreatedBy = $CreatedBy;
					CreatedTime = $CreatedTime;
					Status = $UpdateStatus;
				}
				$Results += New-Object -TypeName PSObject -Property $Property
			}
			else
			{
				# Skip this Resource Type
				write-verbose " EXCLUDING: $($r.type) - $($r.Name) - $($r.ResourceGroup)"
			}
		}
	}
	
	return $Results
}


# +=================================================================================================+
# |  MAIN																							|
# +=================================================================================================+
$Results 		= @()
$UpdateCount	= 0
$ScriptStart	= (Get-Date).ToUniversalTime()   # Execution start time for this script


# +-----------------------------------------------------------------+
# | Process all ResourceContainers (1,000 at a time)				|
# +-----------------------------------------------------------------+
write-output "--- Processing ResourceContainers ---"
Do
{
	$Containers		= (Search-AzGraph -First 1000 -Query $KustoContainersWithoutCreatedBy) | Sort-Object -Property subscriptionId, name
	if ($Containers)
		{ $Results	+= TagResources -InputObject $Containers }
}
until ($Containers.Count -lt 1000)


# +-----------------------------------------------------------------+
# | Process all Resources (1,000 at a time)							|
# +-----------------------------------------------------------------+
write-output "--- Processing Resources ---"
Do
{
	$Resources		= (Search-AzGraph -First 1000 -Query $KustoResourcesWithoutCreatedBy) | Sort-Object -Property subscriptionId, name
	if ($Resources)
		{ $Results	+= TagResources -InputObject $Resources }
}
until ($Resource.Count -lt 1000)

$Finish = (Get-Date).ToUniversalTime()
write-output "`nTagResourceCreators Script finished at $Finish UTC - $UpdateCount update(s) performed."
$Results | Out-GridView -Title "Resource Owner Tags"

return

