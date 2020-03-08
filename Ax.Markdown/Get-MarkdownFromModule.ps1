<#
.SYNOPSIS
	Get-MarkdownFromModule
	
.DESCRIPTION
	Create and populate a test CosmosDB
	
.PARAMETER Module
	Indicates the Module Name

.NOTES
	Author: Lester Waters
	Version: v0.03
	Date: 07-Mar-20
	
	TEST: .\New-MarkdownFromModule.ps1 -Module PowerShellforGithub | out-file C:\GIT\lesterw1\TechNotes\GITHUB\PowerShell_for_Github.md

.LINK
	https://docs.microsoft.com/en-us/powershell/scripting/samples/redirecting-data-with-out---cmdlets?view=powershell-7
	
#>

# +=================================================================================================+
# |  PARAMETERS	              																		|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
Param (
	[Parameter(Mandatory=$true)] [string] $Module
)

$MarkdownHeader = "# $Module`n`n| Cmdlet | Synopsis |`n| --- | --- |`n"
$Markdown = ""

# $module = "PowerShellforGithub"   # TEST

# +=================================================================================================+
# |  LOOP	              																		|
# +=================================================================================================+

$Commands = Get-Command -Module $module

foreach ($command in $Commands)
{
	write-host -ForegroundColor Cyan "Command: $($command.Name)"
	$help = Get-Help -Detailed -Name $Command.Name

	$Name 			= $Command.Name
	$NameLink		= $Command.Name.ToLower()
	if ($command.commandType -notlike "Function")
	{
		$Name 		+= " (" + $command.commandType + ")"
		$NameLink	+= "-" + ([string] $command.commandType).ToLower() 
	}
		
	$Markdown 		+= "## " + $Name + "`n`n"
	
	# Synopsis
	$Synopsis		= ($help.synopsis | out-string).Trim()
	$Markdown 		+= "### Synopsis`n`n$Synopsis`n`n"
	
	# Add in a table of contents entry
	$SynopsisClean	= ($help.synopsis | out-string).Trim().Replace("`n",'')
	$MarkdownHeader	+= "| [$Name](#$NameLink) | $SynopsisClean |`n"

	# Syntax
	$Syntax			= ($help.syntax | out-string).Trim()
	$Markdown 		+= "### Syntax`n`n$Syntax`n`n"
	
	# DESCRIPTION
	$description	= $help.Description.Text
	$Markdown 		+= "### Description`n`n$description`n`n"
	
	# PARAMETERS
	$Parameters		= $help.Parameters.parameter 
	$Markdown 		+= "### Parameters`n`n"
	foreach ($p in $Parameters)
	{
		if ($p.Description)
		{
			$ParameterDesc	= $p.Description.Text.Replace("`n","`n`t    ")
			$Markdown	+= "`t-$($p.name) <$($p.parameterValue)>`n`t    $ParameterDesc`n`n"
		}
		else
		{
			$Markdown	+= "`t-$($p.name) <$($p.parameterValue)>`n`n"
		}
	}
	
	# EXAMPLES
	$Examples		= ($help.Examples | out-string).Trim()
	if ($Examples.Length -gt 10)
		{ $Markdown 		+= "### Examples`n`n$Examples`n`n" }
	
	# ----
	$Markdown		+= "---`n"
	
}

return 	$($MarkdownHeader + "`n---`n" + $Markdown)

