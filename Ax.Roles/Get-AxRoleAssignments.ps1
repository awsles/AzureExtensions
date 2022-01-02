#Requires -Version 5
<#
.SYNOPSIS
	Outputs a json of role assignments
	and custom role definitions for each subscription.

.DESCRIPTION
	Pops up a list of subscriptions and then outputs a json of role assignments
	and custom role definitions for each subscription.
	
.PARAMETER Select
	If specified, then a popup lists available subscriptions.

.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 13-Aug-21
.LINK
	
	
#>

# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
param(
	[Parameter(Mandatory=$false)] [switch] $Select 				= $false
)

# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.Accounts
Import-Module Az.Resources


# +=================================================================================================+
# |  MAIN																						|
# +=================================================================================================+

$Subscriptions = @((Get-AzContext).Subscription)
if ($Select)
{
	$Subscriptions = @(Get-AzSubscription `
		| where {$_.State -like 'Enabled'} `
		| Select Name, Id, TenantId `
		| Out-GridView -PassThru)
}

# Loop Through subscriptions
foreach ($s in $Subscriptions)
{
	# Select the Subscription
	write-verbose "Selecting subscription $($s.Name) ($($s.Id))"
	$x = (Set-AzContext -SubscriptionId $s.Id -TenantId $s.TenantId)
	# Beware of $s | Select-AzSubscription ... seems to log you out now weirdly
	
	# Get the custom role definitions
	$FileName = 'Sub_' + $s.Id + '_CustomRoles.json'
	Get-AzRoleDefinition -Custom | Out-File -Encoding utf8 -FilePath $FileName 
	
	# Get Role Assignments
	$FileName = 'Sub_' + $s.Id + '_RoleAssignments.json'
	Get-AzRoleAssignment -IncludeClassicAdministrators | Out-File -Encoding utf8 -FilePath $FileName -width 1000

}

