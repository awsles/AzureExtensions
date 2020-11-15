#Requires -Version 5
<#
.SYNOPSIS
	This command elevates privileges to Global Admin.
	
.DESCRIPTION
	This cmdlet is used to elevate privileges to global admin when Azure Privileged Identity Management
	has been enabled.
	
.PARAMETER Force
	If set, the user is not asked to confirm the shutdown.

.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 15-Nov-20
	
	Install-module AzureADPreview -AllowPrerelease -AllowClobber
	

.LINK
	https://docs.microsoft.com/en-us/azure/active-directory/privileged-identity-management/powershell-for-azure-ad-roles
	https://github.com/Azure/azure-powershell/issues/11928
	
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
Import-Module AzureADPreview


# +=================================================================================================+
# |  CONSTANTS																						|
# +=================================================================================================+
$TenantId				= '**SET_THIS_FIRST**'			# Your Azure Tenant ID
$CertificateThumbprint	= '**SET_THIS_FIRST**'			# Certificate Thumbprint for App Service Principal
$ApplicationId			= '**SET_THIS_FIRST**'			# ApplicationID for your App Service Principal


$TenantId	= (get-azcontext).tenant.id
if ($TenantId)
{
	try
	{
		$UserObjectId	= (Get-AzureAdUser -ObjectId (Get-AzContext).Account -ErrorAction SilentlyContinue).Id
	}
	catch
	{
		$UserObjectId = $null
	}
}
if (!$UserObjectId)
{  
	$ADConnect = Connect-AzureAD
	$TenantId	= $ADConnect.tenant.id.guid
	$UserObjectId	= (Get-AzureAdUser -ObjectId $ADConnect.Account).ObjectId
	if (!$TenantId)
	{
		write-warning "Unable to connect"
		return
	}
}

# First, get the role definitions. This has the role names
$PIMRoles = Get-AzureADMSPrivilegedRoleDefinition -ProviderId aadRoles -ResourceId $TenantId

# Now get the role assignments for the user
$PIMUserRoles = Get-AzureADMSPrivilegedRoleAssignment -ProviderId aadRoles -ResourceId $TenantId -Filter "subjectId eq '$UserObjectId'"

# Now insert the roleName into the PIMUserRoles
foreach ($r in $PIMUserRoles)
{
	$RoleName = ($PIMRoles | Where-Object {$_.id -like $r.RoleDefinitionId}).DisplayName
	$r | Add-Member -NotePropertyName 'RoleName' -NotePropertyValue $RoleName
}


# Allow the user to choose the role to activate
# Get-AzureADMSPrivilegedRoleAssignment -ProviderId "aadRoles" -ResourceId "926d99e7-117c-4a6a-8031-0cc481e9da26" -Filter "subjectId eq 'f7d1887c-7777-4ba3-ba3d-974488524a9d'"
# Get-AzureADMSPrivilegedRoleDefinition -ProviderId aadRoles -ResourceId $TenantId  | out-gridview
$PIMrole = @($PIMUserRoles 	| Sort-Object -Property RoleName | Out-GridView -PassThru -Title "Choose role to activate:")
if ($PIMrole.count -gt 1)
{
	write-warning "Only a single role may be activated at a time"
	return
}
elseif ($PIMrole.count -eq 0)
{
	return
}

# Create a schedule for 1 hour activation
$schedule = New-Object Microsoft.Open.MSGraph.Model.AzureADMSPrivilegedSchedule
$schedule.Type = "Once"
$schedule.StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$schedule.endDateTime = (Get-Date).AddHours(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")


# Now Activate
# Open-AzureADMSPrivilegedRoleAssignmentRequest -ProviderId 'aadRoles' -ResourceId '926d99e7-117c-4a6a-8031-0cc481e9da26' -RoleDefinitionId 'f55a9a68-f424-41b7-8bee-cee6a442d418' -SubjectId 'f7d1887c-7777-4ba3-ba3d-974488524a9d' -Type 'UserAdd' -AssignmentState 'Active' -schedule $schedule -reason "dsasdsas"
write-host -ForegroundColor Yellow "`nActiving $($PIMRole.RoleName)..."
Open-AzureADMSPrivilegedRoleAssignmentRequest -ProviderId 'aadRoles' -ResourceId $TenantId  `
			-RoleDefinitionId $PIMRole.RoleDefinitionId `
			-SubjectId $UserObjectId `
			-Type 'UserAdd' -AssignmentState 'Active' `
			-Schedule $schedule `
			-reason 'Activated via PowerShell'

