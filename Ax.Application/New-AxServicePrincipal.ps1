#Requires -Version 5
<#
.SYNOPSIS
	Create a self-signed certificate and add it as an Application to Azure.
.DESCRIPTION
	This script creates a new Azure AD Application and associated service principal.
	A certificate is created in the current user's certificate store which may be used
	for authentication.  Additionally, a password is assigned to the Service Principal
	which also may be used.
	
	You must authenticate to Azure in order to run this script(e.g. Login-AzAccount).
.PARAMETER ApplicationDisplayName
	Indiates the Application Display Name. Typically 'App_Name'. Spaces are NOT allowed.
.PARAMETER Owner
	Indicates the named owner / primary contact for this application account.
.PARAMETER PFXPassword
	Indicates the password to be given to the PFX certificate file.
	If not specified, then a random password is generated.
.PARAMETER GenerateKey
	If specified, indicates the name of an application Key to be generated.
.PARAMETER UpdateCertificate
	If specified, then the client certificate for the application is replaced with a new cert.
	This is useful for certificate renewal.
	The user is prompted to select the application name.
.PARAMETER SubscriptionId
	If specified, indicates the subscription to apply to. Otherwise, user is prompted for subscriptions.
.PARAMETER whatif
	If indicated along with update, the update is not performed but the processing leading up to it is.
.NOTES
	Author: Lester Waters
	Version: v0.68
	Date: 05-Jun-20
	
	TO DO: (1) Prompt to select an image (Kubernetes, general, etc.)
	       (2) Set the Owner of the app (unless it is a Microsoft account)
.LINK
	https://docs.microsoft.com/en-us/azure/mobile-engagement/mobile-engagement-api-authentication
	https://raw.githubusercontent.com/matt-gibbs/azbits/master/src/New-AzureRmServicePrincipalOwner.ps1
	https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-authenticate-service-principal 
	https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal 
	https://blogs.endjin.com/2016/01/azure-resource-manager-authentication-from-a-powershell-script/ 
	https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-certificates-point-to-site-makecert
	https://mcpmag.com/articles/2014/11/20/back-up-certificates-using-powershell.aspx
	https://gist.github.com/devigned/dae74a7ca54000f7b714 
	http://paulstovell.com/blog/x509certificate2
#>

# +=================================================================================================+
# |  PARAMETERS	              																		|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
Param (
	[Parameter(Mandatory=$false)] [string] $ApplicationDisplayName,				# App_name
	[Parameter(Mandatory=$false)] [string] $Owner,								# Name of Primary Owner
	[Parameter(Mandatory=$false)] [string] $PFXPassword = "",					# Password for PFX file
	[Parameter(Mandatory=$false)] [string] $GenerateKey = "",					# Name of App Key to generate
	[Parameter(Mandatory=$false)] [switch] $UpdateCertificate = $false,			# If set, then refreshes the certificate
	[Parameter(Mandatory=$false)] [string] $SubscriptionId = "",
	[Parameter(Mandatory=$false)] [switch] $whatif = $false
)

#
# Verify the length and that there are no spaces in the PFX Password
#
if (($PFXPassword.Length -gt 0) -And ($PFXPassword.Contains(" ") -Or $PFXPassword.Length -lt 8))
{
	write-host -ForegroundColor Red " PFX Password may NOT contain any spaces and must be at least 8 characters!"
	return
}

#
# Verify there are no spaces in the Application Display Name
# Set the "App_" prefix for our certificate name
# And Cleanup any case errors
#
if ($ApplicationDisplayName.Contains(" "))
{
	write-host -ForegroundColor Red " Application Display Name may NOT contain any spaces!"
	return
}
if (!$UpdateCertificate -And !$ApplicationDisplayName.ToLower().StartsWith("app_"))
{
	$ApplicationDisplayName = "App_" + $ApplicationDisplayName
}
if (!$UpdateCertificate -And $ApplicationDisplayName.Length -lt 7)
{
	write-host -ForegroundColor Red " ApplicationDisplayName '$ApplicationDisplayName' must be at least 7 characters"
	return
}
# $ApplicationDisplayName = "App_" + ([string]$ApplicationDisplayName[4]).ToUpper() + $ApplicationDisplayName.SubString(5)



# +=================================================================================================+
# |  CONSTANTS (define these prior to calling ./Runbook_Login.ps1)									|
# +=================================================================================================+
# Set-Variable -name TenantID -value ([string]"xxxxx") -option Constant
$MakeCertEXE = "C:\Program Files (x86)\Windows Kits\8.1\bin\x64\makecert.exe"		# Legacy 
$CertificatesMSC = "Certificates.msc"		# MSC for Managing Certificates on a PC

# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.Resources
Import-Module AzureAD


# +=================================================================================================+
# |  FUNCTIONS																						|
# +=================================================================================================+

function New-SWRandomPassword {
    <#
    .Synopsis
       Generates one or more complex passwords designed to fulfill the requirements for Active Directory
    .DESCRIPTION
       Generates one or more complex passwords designed to fulfill the requirements for Active Directory
    .EXAMPLE
       New-SWRandomPassword
       C&3SX6Kn

       Will generate one password with a length between 8  and 12 chars.
    .EXAMPLE
       New-SWRandomPassword -MinPasswordLength 8 -MaxPasswordLength 12 -Count 4
       7d&5cnaB
       !Bh776T"Fw
       9"C"RxKcY
       %mtM7#9LQ9h

       Will generate four passwords, each with a length of between 8 and 12 chars.
    .EXAMPLE
       New-SWRandomPassword -InputStrings abc, ABC, 123 -PasswordLength 4
       3ABa

       Generates a password with a length of 4 containing atleast one char from each InputString
    .EXAMPLE
       New-SWRandomPassword -InputStrings abc, ABC, 123 -PasswordLength 4 -FirstChar abcdefghijkmnpqrstuvwxyzABCEFGHJKLMNPQRSTUVWXYZ
       3ABa

       Generates a password with a length of 4 containing atleast one char from each InputString that will start with a letter from 
       the string specified with the parameter FirstChar
    .OUTPUTS
       [String]
    .NOTES
       Written by Simon Wåhlin, blog.simonw.se
       I take no responsibility for any issues caused by this script.
    .FUNCTIONALITY
       Generates random passwords
    .LINK
       http://blog.simonw.se/powershell-generating-random-password-for-active-directory/
	   https://gallery.technet.microsoft.com/scriptcenter/Generate-a-random-and-5c879ed5
   
    #>
    [CmdletBinding(DefaultParameterSetName='FixedLength',ConfirmImpact='None')]
    [OutputType([String])]
    Param
    (
        # Specifies minimum password length
        [Parameter(Mandatory=$false,
                   ParameterSetName='RandomLength')]
        [ValidateScript({$_ -gt 0})]
        [Alias('Min')] 
        [int]$MinPasswordLength = 8,
        
        # Specifies maximum password length
        [Parameter(Mandatory=$false,
                   ParameterSetName='RandomLength')]
        [ValidateScript({
                if($_ -ge $MinPasswordLength){$true}
                else{Throw 'Max value cannot be lesser than min value.'}})]
        [Alias('Max')]
        [int]$MaxPasswordLength = 12,

        # Specifies a fixed password length
        [Parameter(Mandatory=$false,
                   ParameterSetName='FixedLength')]
        [ValidateRange(1,2147483647)]
        [int]$PasswordLength = 8,
        
        # Specifies an array of strings containing charactergroups from which the password will be generated.
        # At least one char from each group (string) will be used.
        [String[]]$InputStrings = @('abcdefghijkmnpqrstuvwxyz', 'ABCEFGHJKLMNPQRSTUVWXYZ', '23456789', '!#%&'),

        # Specifies a string containing a character group from which the first character in the password will be generated.
        # Useful for systems which requires first char in password to be alphabetic.
        [String] $FirstChar,
        
        # Specifies number of passwords to generate.
        [ValidateRange(1,2147483647)]
        [int]$Count = 1
    )
    Begin {
        Function Get-Seed{
            # Generate a seed for randomization
            $RandomBytes = New-Object -TypeName 'System.Byte[]' 4
            $Random = New-Object -TypeName 'System.Security.Cryptography.RNGCryptoServiceProvider'
            $Random.GetBytes($RandomBytes)
            [BitConverter]::ToUInt32($RandomBytes, 0)
        }
    }
    Process {
        For($iteration = 1;$iteration -le $Count; $iteration++){
            $Password = @{}
            # Create char arrays containing groups of possible chars
            [char[][]]$CharGroups = $InputStrings

            # Create char array containing all chars
            $AllChars = $CharGroups | ForEach-Object {[Char[]]$_}

            # Set password length
            if($PSCmdlet.ParameterSetName -eq 'RandomLength')
            {
                if($MinPasswordLength -eq $MaxPasswordLength) {
                    # If password length is set, use set length
                    $PasswordLength = $MinPasswordLength
                }
                else {
                    # Otherwise randomize password length
                    $PasswordLength = ((Get-Seed) % ($MaxPasswordLength + 1 - $MinPasswordLength)) + $MinPasswordLength
                }
            }

            # If FirstChar is defined, randomize first char in password from that string.
            if($PSBoundParameters.ContainsKey('FirstChar')){
                $Password.Add(0,$FirstChar[((Get-Seed) % $FirstChar.Length)])
            }
            # Randomize one char from each group
            Foreach($Group in $CharGroups) {
                if($Password.Count -lt $PasswordLength) {
                    $Index = Get-Seed
                    While ($Password.ContainsKey($Index)){
                        $Index = Get-Seed                        
                    }
                    $Password.Add($Index,$Group[((Get-Seed) % $Group.Count)])
                }
            }

            # Fill out with chars from $AllChars
            for($i=$Password.Count;$i -lt $PasswordLength;$i++) {
                $Index = Get-Seed
                While ($Password.ContainsKey($Index)){
                    $Index = Get-Seed                        
                }
                $Password.Add($Index,$AllChars[((Get-Seed) % $AllChars.Count)])
            }
            Write-Output -InputObject $(-join ($Password.GetEnumerator() | Sort-Object -Property Name | Select-Object -ExpandProperty Value))
        }
    }
}


# +=================================================================================================+
# |  MAIN BODY																						|
# +=================================================================================================+

# Get Domain
$TenantInfo = Get-AzureADTenantDetail -all $true
$MyDomain = $TenantInfo.VerifiedDomains[0].Name			# Typically domain.onmicrosoft.com


#
# Variables
#
$WinVer = [System.Environment]::OSVersion.Version
$AppHomePage = "https://$MyDomain/$ApplicationDisplayName"
$AppIdentifierUris = "https://$MyDomain/$ApplicationDisplayName"
$AppTitle = $ApplicationDisplayName
$ServicePrincipalPassword = New-SWRandomPassword -MinPasswordLength 18 -MaxPasswordLength 24  # Generate one if needed

# Set our Certificate dates
$startDate	= (Get-Date -Hour 0 -Minute 00 -Second 00)   # Midnight today
$endDate	= (Get-Date -Hour 0 -Minute 00 -Second 00 -Day 31 -Month 12).AddYears(2)	# 2 years at end of year


# Ensure we have a PFX password
if ($PFXPassword -eq "") { $PFXPassword = New-SWRandomPassword -MinPasswordLength 8 -MaxPasswordLength 12}

# +-------------------------------------+
# |  Set our TenantID					|
# +-------------------------------------+
$Tenants = @(Get-AzTenant)
$TenantID = $Tenants[0].Id
write-host -ForegroundColor Yellow "`n*** Tenant is $($Tenants[0].Directory)  ($TenantID) ***`n"

#
# Retrieve our startup directory and set our current
# directory (PowerShell scripts seem to default to the Windows System32 folder)
# The variable $PSScriptRoot is also defined.
# $scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
#
$invocation = (Get-Variable MyInvocation).Value
$Currentdirectorypath = Split-Path $invocation.MyCommand.Path
[IO.Directory]::SetCurrentDirectory($Currentdirectorypath)   # Set our current directory

if (!$UpdateCertificate)
{
	#################################################################################################################
	#   SUBSCRIPTION SELECTION                                                                                    	#
	#	If no subscription was specified, then popup a list of active subscriptions to choose from.					#
	#################################################################################################################
	$Tenants = ($Subscriptions | Select-Object -Property TenantID -unique).TenantId

	# +---------------------------------------------+
	# |  Select subscription(s)						|
	# +---------------------------------------------+
	write-host -ForegroundColor Yellow -NoNewLine "Please choose the subscription(s) [see popup]: "
	$subscriptions = (Get-AzSubscription -Tenant $TenantID) | Where-Object {$_.State -like "Enabled"} | Select-Object -Property Name, Id, TenantId, State | Out-Gridview -Title "Please choose the subscription(s):" -Passthru
	write-host ""
	if ($subscriptions.Count -eq 0) { return $null }
	$TenantId = $Subscriptions[0].TenantId

	# Now select the subscription  (do this so we can see the available roles)
	$x = Select-AzSubscription -SubscriptionId $subscriptions[0].Id -ErrorAction Stop
	$x = Set-AzContext -SubscriptionId $subscriptions[0].Id -TenantId $TenantId -ErrorAction Stop
	write-host ""



	#################################################################################################################
	#   ROLE SELECTION 			                                                                                   	#
	#	Select the role(s) to be applied. Also allow no role selection (which means no service principal will be    #
	#   created)																									#
	#################################################################################################################
	#
	# Select the role to apply based on roles available in Shared Services
	#
	write-host -ForegroundColor Yellow "Please select the Azure ServicePrincipal role for the application... (see popup window)"
	$jsonRole = "{ `
	'Name': ' DO NOT CREATE A SERVICE PRINCIPAL', `
	'Description':  '*** Choose this to create an Application WITHOUT a Service Principal ***', `
	'Id':  '-', `
	'IsCustom':  true `
	}"
	$NoServicePrincipalRole = ConvertFrom-json $jsonRole.Replace("'",'"')
	$jsonRole2 = "{ `
	'Name': ' NO ROLE ASSIGNMENT', `
	'Description':  '*** Choose this to create a Service Principle without a role assignment ***', `
	'Id':  '', `
	'IsCustom':  true `
	}"
	$NoRoleAssignment = ConvertFrom-json $jsonRole2.Replace("'",'"')
		
	$RoleSelection	= @($NoServicePrincipalRole) + @($NoRoleAssignment) + `
		(Get-AzRoleDefinition | Select-Object -Property Name, Id, IsCustom, Description | Where-Object {$_.Name -NotLike "Owner"} | Sort-Object -Property Name)
	$RoleSelection	= ($RoleSelection  | out-GridView -Title "Choose a role option:" -Passthru)

	if ($RoleSelection.Count -eq 0 -Or $RoleSelection.Count -gt 1)
	{
		write-host -ForegroundColor Yellow "   You must choose one role option."
		return
	}
	#elseif ($RoleSelection.Name.Contains("Owner"))
	#{
	#	write-host -Foregroundcolor Red " ERROR: Owner role may NOT be assigned using this tool."
	#	return
	#}
	if ($RoleSelection.Id -like "-")
	{
		write-host -Foregroundcolor Cyan "   A Service Principal will NOT be created."
		$CreateServicePrincipal = $false
	}
	else
	{
		$CreateServicePrincipal = $true
	}
}
else
{
	#################################################################################################################
	#   UpdateCertificate	 																						#
	#	Select the existing application																				#
	#################################################################################################################

	$CreateServicePrincipal = $false
	write-host -NoNewLine -ForegroundColor Yellow "Please select the Azure Application to update the certificate for..."
	$AppList = Get-AzAdApplication | Select-Object -Property DisplayName, IdentifierUris, ApplicationId, ObjectId | Sort-Object -Property DisplayName
	write-host "Applist has $($AppList.Count) entries"
	if ($ApplicationDisplayName.Length -gt 1)
		{
			if (!$ApplicationDisplayName.Contains('*')) { $ApplicationDisplayName += '*' }  # Add trailing wildcard if none
			$AppList = $AppList | Where-Object {$_.DisplayName -Like $ApplicationDisplayName}
		}
	write-host "Applist now has $($AppList.Count) entries [AppDisplayName is '$ApplicationDisplayName'"
	$Application = ( $AppList | Out-GridView -Title "Select the Azure Application:"  -PassThru )
	if ($Application -eq $null)
	{
		write-host "No application was selected."
		return
	}
	elseif ($Application.Count -gt 1)
	{
		write-host "Please choose only one application to update."
		return
	}
	$ApplicationDisplayName = $Application.DisplayName
	$AppTitle = $ApplicationDisplayName
	# $Application | ft ; return  # DEBUG
}

	

#################################################################################################################
#   CERTIFICATE CREATION	                                                                                   	#
#	Create the client certificate																				#
#################################################################################################################
#
#
# Check if the certificate name is already in our certificate store (to avoid collision) 
#
$CreateCert = $true
$thumbprintA=(Get-ChildItem cert:\CurrentUser\My -recurse | where {$_.Subject -match "CN=$ApplicationDisplayName"} | Select-Object -Last 1).thumbprint 
if ($thumbprintA.Length -gt 0) 
{ 
	Write-Host -ForegroundColor Yellow "Certificate already exists in your Certifificate Store: CN=$ApplicationDisplayName with ThumbPrint $thumbprintA" 
	$Response = read-host "Would you like to use this existing certificate? [Y/N] "
	if ($Response.Length -eq 0 -Or !($Response.StartsWith("y")))
	{
		# TODO: Delete existing certificate...
		write-host -ForegroundColor Yellow " ABORTING... A new certificate cannot be created with the same name."
		write-host -ForegroundColor Yellow " Please delete the existing certificate from your local store OR consider re-using it."
		return
	}
	$CreateCert = $false
} 

if ($CreateCert)
{
	#
	# Now create a Self-Signed Certificate
	#
	$CERName = $ApplicationDisplayName + ".cer"
	if ($WinVer.Major -ge 10)
	{	# REQUIRES WINDOWS 10: 
		$cert = New-SelfSignedCertificate -CertStoreLocation "cert:\CurrentUser\My" -Subject "CN=$ApplicationDisplayName" -KeySpec KeyExchange -NotBefore $startDate -NotAfter $endDate
		$keyValue = [System.Convert]::ToBase64String($cert.GetRawCertData())
		$thumbprintA=(Get-ChildItem cert:\CurrentUser\My -recurse | where {$_.Subject -match "CN=$ApplicationDisplayName"} | Select-Object -Last 1).thumbprint 
		Export-Certificate -Cert "cert:\CurrentUser\my\$thumbprintA" -FilePath $CERName -ErrorAction Stop
	}
	else
	{	# Use MAKECERT.EXE:
		& $MakeCertEXE -sky exchange -r -n "CN=$ApplicationDisplayName" -pe -a sha256 -len 2048 -b $startDate.ToString("MM/dd/yyyy") -e $endDate.ToString("MM/dd/yyyy") -ss My $CERName
		# This results in a certificate which can be uploaded as a Management Certificate or App Certificate
		$pause = Read-Host -Prompt 'Press ENTER to continue and export the certificate to PFX (or CTRL-C to stop)'
	}
}

# Export the certificate's private key as a .pfx (password protected)
$PfxPwd = ConvertTo-SecureString -String $PFXPassword -Force -AsPlainText
# Export-PfxCertificate -FilePath "$ApplicationDisplayName.pfx" -Password $PfxPwd -Cert $AzureCert
#  [enum]::GetNames('System.Security.Cryptography.X509Certificates.X509ContentType')
$AzureCert = Get-ChildItem -Path "Cert:\CurrentUser\My" | where {$_.Subject -match "CN=$ApplicationDisplayName" }
if ($AzureCert -eq $null)
{
	write-host ForegroundColor Red "Certificate CN=$ApplicationDisplayName not found!"
	return
}
$store = new-object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
$store.Open("ReadOnly")   # Or MaxAllowed
$cert = $store.Certificates | where {$_.Subject -match "CN=$ApplicationDisplayName" }
[byte[]]$PFXBytes = $cert.Export('Pfx',$PfxPwd)
$PFXfile = $ApplicationDisplayName + '.pfx'
Set-Content -Path $PFXfile -Value $PFXBytes -Encoding Byte
$keyValue = [System.Convert]::ToBase64String($cert.GetRawCertData())
$store.Close()
if ($cert -eq $null)
{
	write-host -ForegroundColor Yellow " Failed to create or retrieve Certificate for $ApplicationDisplayName"
	return
}
$CertThumbPrint = $cert.Thumbprint
Write-Host -ForegroundColor Cyan "Client certificate for $ApplicationDisplayName created"
write-host -ForegroundColor Cyan -NoNewLine "Certificate Thumbprint: "
write-host -ForegroundColor Yellow $CertThumbPrint
Write-Host -ForegroundColor Cyan -NoNewLine "Please make a note of the PFX file password: " 
Write-Host -ForegroundColor Yellow $PFXPassword 
write-host "CERTIFICATE DETAILS:"
$cert | fl


# Load the certificate
# $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate("C:\certificates\examplecert.pfx", $pwd)
# $keyValue = [System.Convert]::ToBase64String($cert.GetRawCertData())

# Create a KeyCredential to be used with the New-AzADApplication call
# THIS HAS BEEN SUPERCEDED BY New-AzADAppCredential (see: https://github.com/Azure/azure-powershell/issues/4491)
#$keyId = [guid]::NewGuid()
#$keyCredential = New-Object  Microsoft.Azure.Commands.Resources.Models.ActiveDirectory.PSADKeyCredential  # Replaced by New-AzADAppCredential  
#$keyCredential.StartDate = $startDate
#$keyCredential.EndDate= $endDate
#$keyCredential.KeyId = $keyId
## $keyCredential.Type = "AsymmetricX509Cert"   # No Longer Supported
## $keyCredential.Usage = "Verify"
## $keyCredential.CertValue = $keyValue


if ($UpdateCertificate)
{ 
	write-verbose "New-AzAppCredential -ApplicationId $($Application.ApplicationId) -CertValue {omitted} -StartDate $($cert.GetEffectiveDateString()) -EndDate $($cert.GetExpirationDateString())"
	
	# NOTE: New-AzADAppCredential only works for the FIRST credential!
	# Use New-AzureADApplicationKeyCredential to add multiple certificate credentials
	# https://github.com/Azure/azure-powershell/issues/6784
	# New-AzADAppCredential -ApplicationId $Application.ApplicationId -CertValue $keyValue `
	#    # -StartDate $cert.GetEffectiveDateString() -EndDate $cert.GetExpirationDateString() -Verbose # The certificate dates don't seem to matter...

	# IF the ObjectID is needed: $application = Get-AzureADApplication | Where-Object { $_.AppId -eq $servicePrincipal.ApplicationId }
	New-AzureADApplicationKeyCredential -ObjectId $application.ObjectId `
		-CustomKeyIdentifier ([System.Convert]::ToBase64String($cert.GetCertHash())) `
		-Type AsymmetricX509Cert -Usage Verify `
		-Value ([System.Convert]::ToBase64String($cert.GetRawCertData())) `
		-StartDate $cert.NotBefore -EndDate $cert.NotAfter
	return
}

$pause = Read-Host -Prompt 'Press ENTER to continue and create the service principal (or CTRL-C to stop)'
########################################
#
# Create the Application WITH the associated Service Principal
#
$SvcPwd = ConvertTo-SecureString -String $ServicePrincipalPassword -Force -AsPlainText
write-Verbose "New-AzADApplication -DisplayName '$ApplicationDisplayName' -HomePage '$AppHomePage' -IdentifierUris '$AppIdentifierUris' -CertValue '$keyValue'"   # DEBUG
$azureAdApplication = New-AzADApplication -DisplayName $ApplicationDisplayName -HomePage $AppHomePage -IdentifierUris $AppIdentifierUris -CertValue $keyValue -AvailableToOtherTenants $false -ErrorAction Stop -StartDate $cert.NotBefore -EndDate $cert.NotAfter -Verbose # -DEBUG # -Password $SvcPwd -KeyCredentials $keyCredential
if ($azureAdApplication -eq $null)
{
	write-host -ForegroundColor Red " Failed to create Azure AD Application $ApplicationDisplayName"
	write-warning " NOTE: The certificate is still in your certificate store and should be manually deleted!" 
	return
}

Write-Host -ForegroundColor Cyan "Application $ApplicationDisplayName created."
$ApplicationID = $azureAdApplication.ApplicationId
$azureAdApplication | fl

# Now add the credentials
# New-AzADAppCredential -ApplicationId $azureAdApplication.Id `
#				-CertValue $keyValue `
#				-StartDate $cert.GetEffectiveDateString() `
#				-EndDate $cert.GetExpirationDateString()


#
# Create the Service Principal for the Application
# Cannot specify Password: https://github.com/MicrosoftDocs/azure-docs/issues/24936
#
if ($CreateServicePrincipal)
{
	write-host -ForegroundCOlor Cyan "Creating Service Principal..."
	# $ServicePrincipal = New-AzADServicePrincipal -DisplayName $ApplicationDisplayName -CertValue $keyValue -EndDate $cert.NotAfter -StartDate $cert.NotBefore -ErrorAction Stop  # -Password $SvcPwd # DO NOT USE
	$ServicePrincipal = New-AzADServicePrincipal -ApplicationId $ApplicationID -Role $null -ErrorAction Stop  # -Password $SvcPwd    # Use THIS cmdlet if the Application entity already exists
	# Get-AzADServicePrincipal -ObjectId $ServicePrincipal.Id 
	if ($ServicePrincipal -eq $null)
	{
		write-host -ForegroundColor Yellow " Failed to create associated Service Principal $ApplicationDisplayName"
		write-warning " NOTE: The certificate is still in your certificate store and should be manually deleted!" 
		Write-Host -ForegroundColor Yellow " Removing Application $($azureAdApplication.DisplayName) from Azure Active Directory due to error." 
		$azureAdApplication | Remove-AzADApplication -Force -ErrorAction Continue
		return
	}
	
	# Retrieve the applicationID
	# $ApplicationID = $ServicePrincipal.ApplicationId
	# write-host "DEBUG:  $applicationId   =   $ApplicationId2"
	
	# Retrieve the generated password 
	# https://github.com/MicrosoftDocs/azure-docs/issues/24936
    if ($ServicePrincipal.Secret)
    {
	    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePrincipal.Secret)
	    $ServicePrincipalPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }
	else
		{ $ServicePrincipalPassword = '{none}' }

	Write-Host -ForegroundColor Cyan "Associated Service Principal $ApplicationDisplayName created."
	Write-Host -ForegroundColor Cyan -NoNewLine "Please make a note of the Service principal's password: " 
	Write-Host -ForegroundColor Yellow $ServicePrincipalPassword
	$ServicePrincipal | fl


	########################################
	#
	# Now assign the Role to the selected subscription(s)
	# Loop through selected subscriptions to apply role
	#
	Write-Host -ForegroundColor Cyan "Assigning roles to application -- This may take up to 30 seconds while AD synchronizes."
	foreach ($sub in $Subscriptions)
	{
		$SubName = $Sub.Name
		$scope = "/subscriptions/" + $Sub.Id
		Try {
			$x = Select-AzSubscription -Subscription $Sub.Id -Tenant $sub.TenantId -ErrorAction Stop
		}
		Catch
		{
			$x = $null
		}
		
		# If we were able to select the subscription...
		if (!$x)
		{
			write-warning "Skipping Subscription $($sub.Name)  ($($sub.Id))"
		}
		else
		{
			foreach ($r in $RoleSelection)
			{
				$roleName = $r.Name 				#
				$RoleID = $r.Id						#
				if ($RoleID.Length -lt 2) { break; }	# Skip if no role ID (i.e., create service principle without role assignment)
				
				write-host -NoNewLine " ADDING application $ApplicationDisplayName as '$roleName' to subscription: $SubName"

				#
				# IMPORTANT: There is a race condition between MSOL and Az
				# so we need to loop and pause a few times waiting for Az
				# to see the new AD entry.
				#
				$Success = $false
				$RetryCount = 7
				$EAerror = @()
				# Wait 5 seconds for role to be created in AD
				Start-Sleep 5
				
				while ($Success -eq $false -And ($RetryCount-- -gt 0))
				{
					# Attempt to assign the Azure role...
					Write-Host -NoNewLine "."   # Output a dot for each loop
					$x = New-AzRoleAssignment -RoleDefinitionName $roleName -ServicePrincipalName $ServicePrincipal.ApplicationId -Scope $Scope -ErrorVariable EAerror -ErrorAction SilentlyContinue

					# write-host "ERROR VARIABLE:" $EAerror.Count " -- " $EAerror
					if ($EAerror.Count -eq 0)
					{
						# Success...
						$Success = $true
						$RetryCount = 0
						write-host (" OK")
					}
					elseif (($EAerror[0].Exception.Message.Contains("PrincipalNotFound") -eq $true) -Or `
							($EAerror[0].Exception.Message.Contains("RoleAssignmentScopeNotAssignableToRoleDefinition")) -Or `
							($EAerror[0].Exception.Message.Contains("does not exist")))
					{
						# Sleep 5 seconds and try again
						Start-Sleep -s 5
						$EAerror = @()
					}
					else
					{
						# Some other error occurred
						write-host -ForegroundColor Yellow " ERROR assigning role to subscription!"
						Write-Error $EAerror[0]
						# Remove the newly created Azure user
						$RetryCount = 0
						$IgnoreErrors = $true		# FOR NOW
						if (!$IgnoreErrors)
						{
							Write-Host " Removing Service Principal $($ServicePrincipal.DisplayName) from Azure Active Directory due to error." 
							Remove-AzADServicePrincipal -Force -ObjectId $ServicePrincipal.Id -ErrorAction Continue
							return $null
						}
					}
				}
			
				if ($Success -ne $true -And !$IgnoreErrors)
				{
					Write-Host -ForegroundColor Red " TIMEOUT! - Unable to assign application to role."
					# Remove the newly created Azure user
					Write-Host -ForegroundColor Yellow " Removing Service Principal $($ServicePrincipal.DisplayName) from Azure Active Directory due to error." 
					Remove-AzADServicePrincipal -Force -ObjectId $ServicePrincipal.Id -ErrorAction Continue
					Write-Host -ForegroundColor Yellow " Removing Application $($azureAdApplication.DisplayName) from Azure Active Directory due to error." 
					$azureAdApplication | Remove-AzADApplication -Force -ErrorAction Continue
					return $null
				}
			}
		}
	}
}

########################################
#
# Output Guidance
#
$Cert = $ApplicationDisplayName + ".CER"
$Guidance = " `
  AZURE APPLICATION (Service Principal) INFORMATION: `
`
		Application Name:    $ApplicationDisplayName `
		TenantID:            $TenantId `
		Application ID:      $ApplicationID `
		App Identifier URI:  $AppIdentifierUris `
		Cert Thumbprint:     $CertThumbPrint `
		Requested By:        $Owner `               
`
  This archive contains a certificate ($Cert) as well as a the certificate `
  with the private key embedded ($PFXfile), which is password protected. `
  Contact the certificate creator to obtain the password, or re-export the PFX `
  from the PC where the certificate was created or installed. `
`
  The PFX can be imported onto another PC's 'CurrentUser' or 'LocalMachine' Certificate Store.`
  In some cases (such as with the Azure Virtual Machine Exporter App), you may need to store `
  the certificate in the Trusted Certificate Authorities on your local PC. `
`
  Once installed, the client certificate may be used to AUTHENTICATE to Azure in `
  one of the following ways: `
`
      (1) Application ID and Service Principal Password [NOT RECOMMENDED] `
      (2) Application ID and an Application Key obtained from the ARM Portal `
          [ACCEPTABLE provided the Key is stored securely (e.g., CyberArk AIM)] `
      (3) Using a certificate stored on the local PC by providing its Thumbprint [RECOMMENDED] `
`
  Option (3) is the recommended practice.  For this application $ApplicationDisplayName, `
  you may authenticate using the PowerShell cmdlet exactly as follows: `

  Login-AzAccount -ServicePrincipal -TenantId '$TenantId' -CertificateThumbprint '$CertThumbPrint' -ApplicationId '$ApplicationID' `
`
  The above is ONLY valid if the associated certificate is installed on the local PC `
  AND it is also provisioned as an Application Service Principal or a Management Certificate. `n"

# Write-host $Guidance
$ReadMe = "README_" + $ApplicationDisplayName + ".txt"
write-host -ForegroundColor Yellow "See $ReadMe for Certificate Usage Guidance."
$Guidance | Out-File $ReadMe -width 160 



########################################
#
# Output Notes in a format for KeePass
#
write-host -ForegroundColor Yellow "`nIMPORTANT: Please add the following information to your KeePass:`n"
$KeePass = "TITLE:    $ApplicationDisplayName`
USERNAME: $AppTitle`
PASSWORD: $ServicePrincipalPassword`
URL:      $AppHomePage`
---------- Place the following in Notes Section -----------`
OWNER: $Owner`
TenantID: $TenantId`
Application ID: $ApplicationID`
App Identifier URI: $AppIdentifierUris`
Cert Thumbprint: $CertThumbPrint`
Service Principal Password: $ServicePrincipalPassword`
Cert PFX Password: $PFXPassword`
Certificate-based Login:`
Login-AzAccount -ServicePrincipal `
     -TenantId '$TenantId'`
	 -CertificateThumbprint '$CertThumbPrint'`
	 -ApplicationId '$ApplicationID'`
`
KEYS:`
{place any keys generated through portal here}`
keyname : value`
`n`n"
write-host -ForegroundColor DarkYellow $KeePass

########################################
#
# Now create a .ZIP containing the .CER, .PFX, the Certificates.MSC, and a README.
#
if ($CreateCert)
{
	$ZipArchive = $ApplicationDisplayName + ".zip"
	Write-host -ForegroundColor Cyan "Creating ZIP $ZipArchive for certificate..."
	Compress-Archive -DestinationPath $ZipArchive -Force -Path $PFXfile
	Compress-Archive -DestinationPath $ZipArchive -Update -Path $CERName
	Compress-Archive -DestinationPath $ZipArchive -Update -Path $ReadMe
	if (test-path $CertificatesMSC) { Compress-Archive -DestinationPath $ZipArchive -Update -Path $CertificatesMSC }
	write-host ""
}

