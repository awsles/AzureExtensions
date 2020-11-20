#Requires -Version 5
<#
.SYNOPSIS
	Remove-AxTags.ps1 -- Removes all instances of a named tag or named tag with a given value.
	
.DESCRIPTION
	This cmdlet provides a way to enumerate all resources with a given tag and then remove a tag.
	By default, containers are excluded. Use -IncludeContainers to include containers.
	
.PARAMETER Name
	Specifies the tag name. 
	
.PARAMETER Value
	Optionally specifies the tag value.
	
.PARAMETER IncludeContainers
	If indicated, then the tags on containers are also removed.
	
.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 20-Nov-20
	
	TO DO: Authorization to perform action 'Microsoft.Resources/subscriptions/tagNames/tagValues/delete' 
	over scope '/subscriptions/xxxxxxxxxxxxxxxxxxxxxxxxxx/tagNames/TAGNAME/tagValues/*'
	
	TO DO: Make this a function Remove-AxTags()
	
.LINK

#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$true)]  [string] $Name,
	[Parameter(Mandatory=$false)] [string] $Value = '*',
	[Parameter(Mandatory=$false)] [switch] $IncludeContainers
)


# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.ResourceGraph


# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+


# +=================================================================================================+
# |  KUSTO QUERY DEFINITIONS																		|
# +=================================================================================================+

$KustoResourcesWithTag = 'resources
| where properties.provisioningState =~ "Succeeded" and tostring(tags) contains ''"%%TAG%%"''
| extend
	resourceId = id,
	resourceType = type
| join kind=leftouter (ResourceContainers | where type =~ "microsoft.resources/subscriptions"
    | project subscriptionName=name, subscriptionId) on subscriptionId'

$KustoContainersWithTag = 'resourcecontainers
| where properties.provisioningState =~ "Succeeded" and tostring(tags) contains ''"%%TAG%%"''
| extend
	resourceId = id,
	resourceType = type
| join kind=leftouter (ResourceContainers | where type =~ "microsoft.resources/subscriptions"
    | project subscriptionName=name, subscriptionId) on subscriptionId'

# Wipe tag name with something unlikely if -Force
$q = $Name
if ($Value -And $Value -ne '*')
{
	$q = $Name.Trim() + ([char] 34) + ':' + ([char] 34) + $Value.Trim()
}

# Fill in the Kusto query
$KustoResourcesWithTag		= $KustoResourcesWithTag.Replace('%%TAG%%', $q)
$KustoContainersWithTag	    = $KustoContainersWithTag.Replace('%%TAG%%', $q)



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

Function RemoveTags
{
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	param(
		[Parameter(Mandatory=$true)] [PSObject] $InputObject,
		[Parameter(Mandatory=$true)] [string] 	$TagName,
		[Parameter(Mandatory=$false)] [string]	$TagValue
	)
	
	$Subscriptions	= $InputObject.subscriptionId | Select-Object -Unique
	$TagString		= $Tags | ConvertTo-Json -Compress
	
	ForEach ($sub in $Subscriptions)
	{
		write-host -ForegroundColor Cyan "Processing subscription: $sub"
		$x = Select-AzSubscription -Subscription $sub -ErrorAction Stop
		[Console]::Out.Flush() 
		
		# Loop through the tagged Resources
		$TheseResources = $InputObject | Where-Object {$_.subscriptionId -like $sub}
		ForEach ($r in $TheseResources)
		{
			# Extract the Tags (Search-AzGraph returns these as a string and NOT a hashtable
			# so conversion will be necessary
			# Convert tags string to hashtable
			$Tags = ConvertTo-HashTable $r.tags
			if ($Tags[$TagName].Length -eq 0)
				{  write-warning "Tag $TagName not found on $($r.resourceId)" }
			
			if (!$TagValue -Or $TagValue -eq '*')
				{ $t = @{$TagName = $Tags[$TagName]} }
			else
				{ $t = @{$TagName = $TagValue} }

			write-host -ForegroundColor Yellow "Removing $($t | ConvertTo-json -Compress) from $($r.subscriptionName)/$($r.resourceGroup)/$($r.Name)"
			$x = Update-AzTag -ResourceId $r.ResourceId -Tag $TagsToRemove -Operation Delete -ErrorAction Continue	# Only requires TagContributor role permission 
		}
	}
}

# +=================================================================================================+
# |  MAIN																							|
# +=================================================================================================+
$Results 		= @()
if ($Value)
	{ $TagsToRemove	= @{$name = $Value} }
else
	{ $TagsToRemove = @{$name = '*'} }


# +-----------------------------------------------------------------+
# | Process all ResourceContainers (1,000 at a time)				|
# +-----------------------------------------------------------------+
if ($IncludeContainers)
{
	write-verbose "--- Processing ResourceContainers ---"
	Do
	{
		$Containers		= (Search-AzGraph -First 1000 -Query $KustoContainersWithTag) | Sort-Object -Property subscriptionId, name
		if ($Containers)
			{ $Results	+= RemoveTags -InputObject $Containers -TagName $Name -TagValue $Value }
	}
	until ($Containers.Count -lt 1000)
}


# +-----------------------------------------------------------------+
# | Process all Resources (1,000 at a time)							|
# +-----------------------------------------------------------------+
write-verbose "--- Processing Resources ---"
Do
{
	$Resources		= (Search-AzGraph -First 1000 -Query $KustoResourcesWithTag) | Sort-Object -Property subscriptionId, name
	if ($Resources)
		{ $Results	+= RemoveTags -InputObject $Resources -TagName $Name -TagValue $Value }
}
until ($Resource.Count -lt 1000)


# Now remove the last of the tags
# This requires authorization to perform action 'Microsoft.Resources/subscriptions/tagNames/tagValues/delete' 
# over scope '/subscriptions/xxxxxxxxxxxxxxxxxxxxxxxxxx/tagNames/TAGNAME/tagValues/*'
if ($Value)
{
	$x = Remove-AzTag -Name $Name -Value $Value -Confirm
}
else
{
	$x = Remove-AzTag -Name $Name -Confirm 
}
