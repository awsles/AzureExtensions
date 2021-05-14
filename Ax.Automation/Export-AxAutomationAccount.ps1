<#
.SYNOPSIS
	Export-AxAutomationRunbooks
	
.DESCRIPTION
	Exports the Automation runbooks and Parameters CSV for the selected Azure Automation Account.

.PARAMETER ResourceGroupName
	The Azure resource group name.

.PARAMETER AutomationAccountName
	The Azure Automation account name.
	
.PARAMETER Path
	Export path (folder). Default is local folder.

.NOTES
	Author: Lester Waters
	Version: v0.02 DRAFT
	Date: 14-May-21

.LINK
	https://harvestingclouds.com/post/script-sample-export-all-azure-automation-account-runbooks-and-variables/
	
#>
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
Param (
	[Parameter(Mandatory = $false)] [string]	$AutomationAccountName,
	[Parameter(Mandatory = $false)] [string]	$ResourceGroupName,
	[Parameter(Mandatory = $false)] [string]	$path = '.\'
)

# +---------------------------------------------------------+
# |  Modules													|
# +---------------------------------------------------------+
Import-Module Az.Automation


# +---------------------------------------------------------+
# |  Main													|
# +---------------------------------------------------------+

# If $AutomationAccountName was not specified, then prompt for it.
if (!$AutomationAccountName)
{
	$AutomationAccount = (Get-AzAutomationAccount | Out-GridvIew -Title "Choose one automation account to update:" -PassThru)
	if (!$AutomationAccount) { return }
	if ($AutomationAccount.Count -gt 1)
		{ write-warning "Choose only one automation account"; return }
		
	$AutomationAccountName	= $AutomationAccount.AutomationAccountName
	$ResourceGroupName 		= $AutomationAccount.ResourceGroupName
}
else
{
	$AutomationAccount = Get-AzAutomationAccount -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName
	if (!$AutomationAccount) { return }
}
write-verbose "AutomationAccountName: $AutomationAccountName  ResourceGroupName: $ResourceGroupName"

$AllRunbooks = Get-AzAutomationRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName
$AllRunbooks | Export-AzAutomationRunbook -OutputFolder $Path -Force

# Path for parameters.csv
if ($path[-1] -eq '\')
	{ $CsvPath = $path + 'parameters.csv' }
else
	{ $CsvPath = path + '\parameters.csv' }

# Output parameters.csv
$variables			= Get-AzAutomationVariable -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName
if ($variables)
{
	write-verbose "Exporting Parameters"
	$variables | Export-Csv -Path $CsvPath -NoTypeInformation -Force
}
