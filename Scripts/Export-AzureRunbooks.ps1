<#
.SYNOPSIS
	Export Azure Runbooks
	
.DESCRIPTION
	Select Azure automation and then export the runbooks to the specified directory

.PARAMETER Path
	Output folder. 

.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 12-May-21

.LINK
	https://harvestingclouds.com/post/script-sample-export-all-azure-automation-account-runbooks-and-variables/
	
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "")]
param(
	[string] $path	= ".\"
)

# MODULES
Import-Module Az.Accounts
Import-Module Az.Automation

# CSV Path
if ($path[-1] -eq '\')
{
	$pathCSV = $path + 'variables.csv'
}
else
{
	$pathCSV = $path + '\variables.csv'
}

# Select Subscription
Get-AzSubscription | Out-GridView -Passthru -Title "Select Subscription:" | Select-AzSubscription

# Select Automation Account
$AutomationAccount = Get-AzAutomationAccount | Out-GridView -Passthru -Title "Select Automation Account to export:"

# Enumerate Runbooks
$AllRunbooks = ( $AutomationAccount | Get-AzAutomationRunbook )
if (!$AllRunbooks)
{
	write-warning "No runbooks found!"
	return
}
write-host "$($AllRunbooks.count) runbooks exported to $path"

# Export Runbooks
$x = ($AllRunbooks | Export-AzAutomationRunbook -OutputFolder $Path)

# Export Variables parameter list
$variables = ($AutomationAccount | Get-AzAutomationVariable)
$variables | Export-Csv -Path $pathCSV -NoTypeInformation
if ($Variables)
{
	write-host "Runbook variables exported to $pathCSV"
}