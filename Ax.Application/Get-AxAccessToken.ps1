function Get-AxAccessToken {
    <#
    .SYNOPSIS
    Retrieve the cached Azure AccessToken (Bearer) from the current Powershell session and its current Azure Context
 
    .NOTES
    Thanks to Stephane Lapointe (https://www.linkedin.com/in/stephanelapointe/) for this script to get the Bearer Token
	from an existing Powershell session (https://gallery.technet.microsoft.com/scriptcenter/Easily-obtain-AccessToken-3ba6e593/view/Reviews)
	
	.LINK
	https://github.com/Azure/azure-powershell/issues/13337
    #>

    [CmdletBinding()]
    param ()

    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    if (-not $azProfile.Accounts.Count) {
        Write-Error 'Could not find a valid AzProfile, please run Connect-AzAccount'
        return
    }

    $currentAzureContext = Get-AzContext
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
    $token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
    $token.AccessToken
}