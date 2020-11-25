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
	Version: v0.80
	Date: 21-Nov-20
	
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
	[Parameter(Mandatory=$false)] [switch] $Force   = $false,
	[Parameter(Mandatory=$false)] [switch] $WhatIf  = $false
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.ResourceGraph


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
	write-output "Using logged in account ID $((Get-AzContext).Account.Id) ($($(Get-AzContext).Account.Type))"
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
	
	$TResults = @()
	$Subscriptions	= $InputObject | Select-Object -Property subscriptionId,subscriptionName | Select-Object -Unique
	
	ForEach ($sub in $Subscriptions)
	{
		write-host -ForegroundColor Cyan "=== Subscription: $($sub.subscriptionName)  ($($sub.subscriptionId)) ==="
		$x = Select-AzSubscription -Subscription $sub.subscriptionId -ErrorAction Stop
		[Console]::Out.Flush() 
		
		# Loop through the untagged Resources
		$TheseResources = $InputObject | Where-Object {$_.subscriptionId -like $sub.subscriptionId}
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
					$OriginalCreatedBy = $CreatedB
				}
				else
				{
					$OriginalCreatedBy = "-Unknown-"
				}
				$CreatedTime = $Tags.Keys | Where-Object { $_ -like "CreatedTime"} 
				if ($CreatedTime)
					{ $CreatedTime = $Tags[$CreatedTime] }
				
				# $OriginalCreatedBy = "-Unknown-"  # DEBUG
				write-verbose "  PROCESSING: $($r.ResourceId)"
				
				# NOTE: There are a lot of different resource types... many of which may not generate any event logs
				# as they may be indirectly created, etc.  We will want to limit the resources that we tag to the most
				# strategic: VMs, Disks, Storage Accounts, Data Lakes, SQL Servers, NICs, network stuff, etc.

				# Check on CreatedBy
				if (!$CreatedBy -Or $Force)
				{
					# First, we must look into the event Log for this resource, going back 90 days
					$Events = (Get-AzLog -ResourceId $r.ResourceId -Status 'Succeeded' -StartTime (Get-Date).AddDays(-89) -WarningAction SilentlyContinue) `
                                | Where {($_.Authorization.Action -notLike 'Microsoft.Resources/tags/write') -and `
									($_.Authorization.Action -notLike 'Microsoft.Storage/storageAccounts/listAccountSas/action')} 
								# ALTERNATE Property for Action: $_.OperationName.Value or $_.properties.content.message
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
						$CreatedTime = [String] $Events[$LastEventIndex].EventTimeStamp
						if ($CreatedBy -eq $null -Or $CreatedBy.Length -eq 0) 
						{
							# Check for "securitydata" resource group which is created by the Azure Security Center service
							if ($r.ResourceGroupName -like 'securitydata')
								{ $CreatedBy = "Azure Security Center Service" }
						}
						# else see if it is a managed disk (which does not record the creator properly)
						# Then we need to correlate on the correlationID to find the creator
						elseif (($r.ResourceType -like 'Microsoft.Compute/disks' -or `
                                 $r.ResourceType -like 'Microsoft.Network/networkInterfaces') -And (!$CreatedBy.Contains('@')))
						{
							$E = (Get-AzLog -CorrelationId $Events[$LastEventIndex].CorrelationId -Status "Succeeded" -StartTime (Get-Date).AddDays(-89) -WarningAction SilentlyContinue -ErrorAction Continue `
								| Where-Object {$_.Authorization.Action -like 'Microsoft.Compute/virtualMachines/write'} `
								| select-object -last 1)
                            if ($E)
                            {
							    $CreatedBy = $E.Caller
							    $CreatedTime = [String] $E.EventTimeStamp
                            }
						}

                        # If CreatedBy is not a UPN, then see if it is an Application
                        if (!$CreatedBy.Contains('@'))
                        {
                            $sp = Get-AzureAdServicePrincipal -ObjectId $CreatedBy -ErrorAction Continue
                            if ($sp.DisplayName)
                                { $CreatedBy += " ($($sp.DisplayName))" }
                        }
						write-verbose "    Matching Event: $($Events[$LastEventIndex].Authorization.Action) by $CreatedBy"
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
						write-verbose "    UPDATING (WhatIf):  CreatedBy: $CreatedBy    CreatedTime: $CreatedTime"
						$UpdateStatus = "Updated [WhatIf]"
					} 
					else
					{
						# update the tags (or add the property if it doesn't already exist)
					
						# Create the new tags...
#						$Tags.Remove("CreationInfo")						# Remove LEGACY tag
#						$Tags.Remove("CreationTime")						# Remove LEGACY tag
#						$Tags.Remove("CreatedBy")							# Remove it so that we get the Upper/Lower Case we want
#						$Tags.Set_Item("CreatedBy", $CreatedBy)      		# $Tags["CreatedBy"]    = $CreatedBy
#						if ($CreatedTime)
#							{ $Tags.Set_Item("CreatedTime", $CreatedTime) }   	# $Tags["CreatedTime"]    = $CreatedTime

                        # If using MERGE option
                        $MergeTags = @{}
                        $MergeTags.Set_Item("CreatedBy", $CreatedBy) 
                        if ($CreatedTime)
							{ $MergeTags.Set_Item("CreatedTime", $CreatedTime) } 
						
						# Write the changes...  ($Events[$LastEventIndex] has the event that was used)
						write-verbose "    UPDATING:  $($MergeTags | ConvertTo-Json -compress)"
						$Err1 = $null
						try {
							# $x = Set-AzResource -id $r.ResourceId -Tag $Tags -Force -ErrorAction stop -ErrorVariable Err1 # -Verbose
							$x = Update-AzTag -ResourceId $r.ResourceId -Tag $MergeTags -Operation Merge -ErrorAction stop -ErrorVariable Err1 -Verbose # Only requires TagContributor role permission 
							$UpdateStatus = "Updated"
						}
						catch {
							$UpdateStatus = "Update Error: $($Err1.Message)" 
							Write-warning $UpdateStatus
							write-verbose "Update FAILED for resource name: $($.resourceGroup)/$($r.name)  Type: $($r.type)"
						}
					}
				}
				else
				{ 
					write-verbose " TAG EXISTS: $($r.ResourceGroup)/$($r.Name) - $($r.ResourceType) -  CreatedBy: $CreatedBy"
					$UpdateStatus = "Tag Exists"
				}
				
				# Record the entry for Out-GridView at the end...
				$Property = [ordered]@{
					SubscriptionName    = $r.subscriptionName;
					ResourceName        = $r.Name;
					ResourceGroup       = $r.ResourceGroup;
					ResourceType        = $r.ResourceType;
					CreatedBy           = $CreatedBy;
					CreatedTime         = $CreatedTime;
					Status              = $UpdateStatus;
				}
				$TResults += New-Object -TypeName PSObject -Property $Property
			}
			else
			{
				# Skip this Resource Type
				write-verbose "  EXCLUDING: $($r.ResourceGroup)/$($r.Name) - $($r.ResourceType)"
			}
		}
	}
	
	return $TResults
}


# +=================================================================================================+
# |  MAIN																							|
# +=================================================================================================+
$Results 		= @()
$ScriptStart	= (Get-Date).ToUniversalTime()   # Execution start time for this script


# +-----------------------------------------------------------------+
# | Process all ResourceContainers (1,000 at a time)				|
# +-----------------------------------------------------------------+
# Query for applicable containers up to 1000 at a time (5000 is max allowed by query)
$SkipCount = 0
Do
{	
	# Search-AzGraph doesn't like a -SkipCount of zero
	if ($SkipCount -eq 0)
	{
		$Containers = (Search-AzGraph -First 1000 -Query $KustoContainersWithoutCreatedBy) `
						| Sort-Object -Property subscriptionId, name
	} 
	else
	{
		$Containers	= (Search-AzGraph -First 1000 -Query $KustoContainersWithoutCreatedBy -Skip $SkipCount) `
						| Sort-Object -Property subscriptionId, name 
	}
    write-output "--- Processing $($Containers.Count) ResourceContainers ---"
	$SkipCount += 1000
	if ($Containers)
		{ $Results	+= TagResources -InputObject $Containers }
}
until ($Containers.Count -lt 1000)


# +-----------------------------------------------------------------+
# | Process all Resources (1,000 at a time)							|
# +-----------------------------------------------------------------+
# Query for applicable resources up to 1000 at a time (5000 is max allowed by query)
$SkipCount = 0
Do
{
	# Search-AzGraph doesn't like a -SkipCount of zero
	if ($SkipCount -eq 0)
	{
		$Resources	= (Search-AzGraph -First 1000 -Query $KustoResourcesWithoutCreatedBy) `
						| Sort-Object -Property subscriptionId, name
	} 
	else
	{
		$Resources	= (Search-AzGraph -First 1000 -Query $KustoResourcesWithoutCreatedBy -Skip $SkipCount) `
						| Sort-Object -Property subscriptionId, name
	}
    write-output "--- Processing $($Resources.Count) Resources ---"
	$SkipCount += 1000
	if ($Resources)
		{ $Results	+= TagResources -InputObject $Resources }
}
until ($Resource.Count -lt 1000)

$Finish = (Get-Date).ToUniversalTime()
write-output "`nTagResourceCreators Script finished at $Finish UTC - $($Global:UpdateCount) update(s) performed."

# If VERBOSE, then display a gridview of the changes
if ($VerbosePreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue)
    { $Results | Out-Gridview -Title "Results"  }
