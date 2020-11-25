# +-------------------------------------------------------------------------+
# |  Get-AxMyIdentity()	   [ a.k.a. whoami ]								|
# |  Returns information about the logged on user							|
# +-------------------------------------------------------------------------+
function Get-AxMyIdentity
{
	<#
	.SYNOPSIS
		Get-AxMyIdentity.ps1 -  Returns information about the logged on user
	.DESCRIPTION
		Returns details about the logged on user.
		The alias 'whoami' also may be used.
		
		This takes a few seconds to run.
		
	.NOTES
		Author: Lester Waters
		Version: v0.05
		Date: 21-Nov-20
	#>
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	param ()

	class WhoAmI
	{
		[string] $UserPrincipalName
		[string] $DisplayName
		[string] $ObjectId
		[string] $AppId
		[string] $type
		[string] $CertThumbprint
		[string] $Subscription
		[system.array] $Tenant
		[system.array] $VisibleTenants
		[system.array] $Roles
		[system.array] $azAccounts
	}
	
	$Result = New-Object -TypeName WhoAmI

	# Get Azure Context
	$c 			= Get-AzContext
	$Account 	= $c.Account
	if (!$Account.Id)
	{
		$R.Account = "You are not logged in."
		return $Result
	}
	
	
	# Extract ObjectId (AppId if ServicePrincipal)
	if ($Account.ExtendedProperties.HomeAccountId)  
		{ $Id = $Account.ExtendedProperties.HomeAccountId.Split('.')[0] }
	else
		{ $Id = $Account.Id }
		
	# Get More details
	$AzAduser 	= Get-AzAdUser -ObjectId $Id # -ErrorAction SilentlyContinue
	$azProfile	= [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
	$tmp1 = ($AzProfile.Accounts | Select-Object -Property Id,Type,ExtendedProperties)
	$tmp1 | foreach {$_ | Add-Member -NotePropertyName 'CertificateThumbprint' -NotePropertyValue $_.ExtendedProperties.CertificateThumbprint }	
	$Result.azAccounts = $tmp1 | Select-Object -Property Id,Type,CertificateThumbprint
	
	$Result.type = $Account.type
	if ($Account.Type -like 'User' -And ($Account.Id).Contains('@'))
	{
		$Result.DisplayName			= $AzAduser.DisplayName
		$Result.ObjectId			= $Id
		$Result.UserPrincipalName	= $AzAdUser.UserPrincipalName
		$Roles = Get-AzRoleAssignment -ObjectId $Id # -ErrorAction SilentlyContinue
	}
	elseif ($Account.Type -like 'ServicePrincipal')
	{
		# Map to Application Name
		$sp = Get-AzADServicePrincipal -ApplicationId $id
		$Result.DisplayName			= $sp.DisplayName
		$Result.ObjectId			= $sp.Id
		$Result.AppId				= $Id
		$Roles = Get-AzRoleAssignment -ObjectId $sp.Id # -ErrorAction SilentlyContinue
	}
	else
	{
		# Other
		$Result.ObjectId			= $Id
		$Result.UserPrincipalName	= $AzAdUser.UserPrincipalName
		$Result.DisplayName			= $AzAduser.DisplayName
		$Roles = Get-AzRoleAssignment -ObjectId $Id # -ErrorAction SilentlyContinue
	}
	
	# If a certificate was used...
	if ($Account.CertificateThumbprint)
		{ $Result.CertThumbprint = $Account.CertificateThumbprint }
	
	# Currently selected subscription
	$Result.Subscription		= "$($c.Subscription.Name)  ($($c.Subscription.id))"

	# Process Tenants
	$tList = @()
	$Tenants	= Get-AzTenant # -ErrorAction SilentlyContinue  # visible tenants with names
	foreach ($t in $Account.Tenants)
	{
		$thisTenant = $Tenants | Where-Object {$_.Id -like $t}
		if ($thisTenant.Name)
		{
			$tList += "$($thisTenant.Name)  ($($t))"
			# $thisTenant | Add-Member -NotePropertyName 'Seen' -NotePropertyValue $true
		}
		else
			{ $tList += $t }
	}
	$Result.Tenant				=  $tList
	$Result.VisibleTenants		= $Tenants.Name
# 	$Result.VisibleTenants		= @( $Tenants | foreach {"$($_.Name) ($($_.id))" } )			# (($Tenants | Where-Object {$_.Seen -ne $true}).Name)
	
	# User's roles
	$Result.Roles				=  $Roles.RoleDefinitionName 
	
	Return $Result
}

# Create an alias for this function
set-alias -Name whoami -Value Get-AxMyIdentity -Option AllScope -Scope Global -Description 'Invokes Get-AxMyIdentity()'

