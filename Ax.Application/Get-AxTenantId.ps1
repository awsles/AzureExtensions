# +-------------------------------------------------------------------------+
# |  Get-AxTenantId()														|
# |  Return TenantId given the Tenant.onmicrosoft.com name.					|
# +-------------------------------------------------------------------------+
function Get-AxTenantId
{
	<#
	.SYNOPSIS
		Get-AxTenantId - Return TenantId given the Tenant.onmicrosoft.com name.	
	.DESCRIPTION
		Returns the TenantID for a given Azure Tenant Name.
		You do not have to be logged in.
		
	.PARAMETER TenantName
		Tenant name as either 'company' or as 'company.onmicrosoft.com'.
		
	.NOTES
		Author: Lester Waters
		Version: v0.02
		Date: 20-Nov-20
	#>
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	Param 
	(
		[Parameter(Mandatory=$true)] [string] $TenantName					# 
	)
	
	# If the Tenant Name is a GUID, then we are done
	[regex]$guidRegex = '(?im)^[{(]?[0-9A-F]{8}[-]?(?:[0-9A-F]{4}[-]?){3}[0-9A-F]{12}[)}]?$'
	
	if ($TenantName -match $guidRegex)
		{ return $TenantName }
    
	# Append the FQDN if needed
	if (!$TenantName.ToLower().Trim().EndsWith('.onmicrosoft.com'))
		{ $TenantName += ".onmicrosoft.com" }
	
	$URI = "https://login.windows.net/$TenantName/.well-known/openid-configuration"
	Try {
		$Response = (Invoke-WebRequest -UseBasicParsing -Uri $URI -Method Get -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Content | ConvertFrom-Json
	}
	Catch [System.Net.WebException]
	{
		Write-Verbose "An exception was caught: $($_.Exception.Message)"
		return $null
	}
	$Response = (Invoke-WebRequest -UseBasicParsing -Uri $URI -Method Get -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Content | ConvertFrom-Json
	if ($Response.authorization_endpoint)
	{ return ($Response.authorization_endpoint.Split('/')[3]) }
	return $null
}
