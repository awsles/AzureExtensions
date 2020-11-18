<#
.SYNOPSIS
	Get-MarkdownFromModule - Retrieve the help information in markdown format from one or all cmdlets within the specified module.
	
.DESCRIPTION
	Create and populate a test CosmosDB
	
.PARAMETER Module
	The purpose of this cmdlet is to generate documentation in Markdown format for a single cmdlet or all cmdlets in the specified PowerShell module.
	This is useful not only for modules which you may create, but also for 3rd party modules which have poor online documentation
	Running **Get-Help** on each cmdlet is tedious, so generating reference documentation in Markdown format helps.

	Hopefully, this tool can evolve to help other PowerShell module developers to automatically generate their documentation page
	directly from each cmdlet's help section.


.NOTES
	Author: Lester Waters
	Version: v0.06
	Date: 17-Nov-20

.EXAMPLE
	.\New-MarkdownFromModule.ps1 -Module PowerShellforGithub | out-file C:\PowerShell_for_Github.md

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

$timestamp = Get-Date ([datetime]::UtcNow) -Format "dddd MM/dd/yyyy HH:mm UTC"

$MarkdownHeader = "# Documentation for $Module`nThis is the combined documentation for the $Module cmdlets.`n<br/>Last updated on $timestamp`n<br/><br/>`n`n| Cmdlet | Synopsis |`n| --- | --- |`n"
$MarkdownFooter = "*This combined documentation page was created using https://github.com/lesterw1/AzureExtensions/tree/master/Ax.Markdown cmdlet.*"
$Markdown = ""

# $module = "PowerShellforGithub"   # TEST


# +=================================================================================================+
# |  LOOP through Helpfiles           																|
# +=================================================================================================+
$Helpfiles = get-help -name $module | Where {$_.Category -like 'Helpfile'} 

if ($helpfiles)
	{ $Markdown += "For additional help, type:`n" }
	
foreach ($helpfile in $Helpfiles)
{
	write-host -ForegroundColor Cyan "Helpfile: $($helpfile.Name)"
	$help = Get-Help -Detailed -Name $helpfile.Name
	
	# TO DO: Embed the preformatted text returned by Get-Help.
	# For now, just embed a reference to the helpfile page.
	$Markdown += '```get-help ' + $helpfile.Name + '``` ' + "`n"
}
$Markdown += "`n"


# +=================================================================================================+
# |  LOOP through cmdlets           																|
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
	# Handle lines in the examples with embedded hashtags at line starts
	if ($Examples)
		{ $Examples		= $Examples.Replace("`n# ", "`n#### ") }
	
	# Add to output
	if ($Examples.Length -gt 10)
		{ $Markdown 		+= "### Examples`n`n$Examples`n`n" }
	
	# ----
	$Markdown		+= "`n`n---`n"
	
}

return 	$($MarkdownHeader + "`n---`n" + $Markdown + "`n" + $MarkdownFooter + "`n" )

