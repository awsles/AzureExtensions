#Requires -Version 5.1
<#
.SYNOPSIS
	Create-AxBillingSummary - Create the Azure Billing Data Summary given an Azure detailed usage CSV.
.DESCRIPTION
	This cmdlet takes a CSV as input which is expected to contain one month or less of Azure detailed
	billing data.  The CSV may be in EA v3 format or in the standard Azure consumption export format.
	
	The CSV is ingested and analysed for the monthly spend across each of:
	
		- Enterprise Agreement (overall)
		- Subscription (overall)
		- Subscription + MeterCategory
		- Subscription + Resource Group
		- Subscription + Tag (costCenter, serviceOwner)
		- Subscription + CostCenter (as specified in EA portal only; not the tag)
		- Subscription + DepartmentName (as specified in EA portal only; not the tag)
		- Subscription + Resource Group + Tag

	NOTE: Runtime for a large tenant with ~2.2M records in a month will take about 10 hours
	to complete (or 4+ DAYS if -UseSystemIO is specified). System.IO is VERY slow.

.PARAMETER InputPath
	Specifies the path to the Azure Detailed Usage CSV file to import.
.PARAMETER InputObject
	Specifies an optional AxEAUsageDetail object which contains the Path to
	the CSVFile to use as input. This is an alternate input to -Path and may be pipelined in
	from the Get-AxEAUsageDetail.ps1 cmdlet.
.PARAMETER OutputPath
	Specifies the path and (optionally) the filename in which to place the CSV and TXT output.
	If an asterisk is specified ('*'), then an output filename is generated based on the
	input filename with '_Summary.csv' appended.
.PARAMETER NoClobber
	NoClobber prevents an existing file from being overwritten and displays a message that the
	file already exists. By default, if a file exists in the specified path, this cmdlet
	overwrites the file without warning.
.PARAMETER DailyTotals
	If indicated, then the summation is done for each subscription on a daily basis.
	Otherwise, summation is done on a monthly basis.
.PARAMETER UseSystemIO
	Indicates that System.IO should be used to read the CSV line by line rather than
	reading the file entirely into memory using Get-Content. This should only be used
	where the available memory precludes reading the entire input file into memory.
	Using System.IO is SIGNIFICANTLY slower, so thi option is not recommended unless
	absolutely necessary.

.NOTES
	Author: Lester Waters
	Version: v0.15
	Date: 19-May-20
	
	As the input CSV file may be quite large in an Enterprise, System.IO is used to
	read the data rather than native powershell cmdlets (which tend to read the entire
	file into memory at once). 
	
	Customize the $TagsToMonitor as needed (no weird characters allowed!).

	TEST:
	CD c:\git\lesterw1\CloudBilling\Azure
	$r = .\Create-AxBillingSummary.ps1 -InputPath  'Test.csv' -OutputPath '*' -Verbose
	
	$r = .\Create-AxBillingSummary.ps1 -InputPath "C:\Scripts\BillingData\csv\66289628_Usage_202004.csv" -OutputPath '*' -Verbose
	
.LINK
	https://portal.azure.com/#blade/Microsoft_Azure_CostManagement/Menu/exports 
	https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail
#>


# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
Param
(
	[Parameter(Mandatory=$false)] [string]  $InputPath,								# Input CSV			
	[Parameter(ValueFromPipeline,Mandatory=$false)] [PSObject] $InputObject,		# Optional AxEAUsageDetail object
	[Parameter(Mandatory=$false)] [string]  $OutputPath,
	[Parameter(Mandatory=$false)] [switch]  $NoClobber = $false,				# If true, don't overwrite exiting output file
	[Parameter(Mandatory=$false)] [switch]  $DailyTotals = $false,				# If true, generate daily totals
	[Parameter(Mandatory=$false)] [switch]  $UseSystemIO = $false				# If true, use the faster Get-Content cmdlet
)


# +=================================================================================================+
# |  CUSTOMIZATIONS     (customize these values for your subscription and needs)					|
# +=================================================================================================+
$TagsToMonitor 		= @('Cost Code ID', 'Service Name')			# These are the Tag Names to sum up
$IncludeUnspecified	= $False									# Include TAG:{unspecified} sums in CSV 

# +=================================================================================================+
# |  CONSTANTS     																					|
# +=================================================================================================+
$HashTables 	= @('MeterCategories', 'ResourceGroups', 'CostCenters', 'DepartmentNames', 'Locations')		    # All Except 'Tags'
$HTPropNames	= @('MeterCategory',   'ResourceGroup',  'CostCenter',  'DepartmentName',  'ResourceLocation')	# MUST be 1:1 with HashTables entry


# +=================================================================================================+
# |  CLASSES																						|
# +=================================================================================================+
Class AxEAUsageDetail
{
	[int]	 $Status			# HTTP Result Code (200=success)
	[string] $BillingMonth		# 'YYYYMM' (if specified)
	[string] $StartDate			# Starting Date (if specified as YYYY-MM-DD)
	[string] $EndDate			# Ending Date (if specified as YYYY-MM-DD)
	[string] $EABlob			# Interim EA Blob URI
	[string] $CSVPath			# Full path and name for local CSV output file
	[string] $BlobPath			# Full path for saved Azure blob (future feature)
}

Class DataSchema
{
	[string] $Name				# Column Name from CSV
	[string] $NameLower			# Name in lower case
	[string] $SqlType			# SQL Data Type
	[string] $PSType			# PowerShell Data Type
	[int]	 $Order				# Column order in input CSV (0..N; -1 = not present)
	
	# SetValues() - Sets the primary values of the class in one function
	# Usage: $x = [DataSchema]::New().SetValues('accountName', 'varchar(250)', 'string')
	[DataSchema] SetValues ($a1, $a2, $a3)
	{
		$This.Name		= $a1
		$This.NameLower	= $a1.ToLower()
		$This.SqlType	= $a2
		$This.PSType	= $a3
		$This.Order		= -1
		Return $This
	}
}

class SubscriptionEntry
{
	[string]	$Key							# SubscriptionID_YYYYMMDD
	[string]	$TenantId						# GUID
	[string]	$SubscriptionId					# GUID
	[string]	$SubscriptionName				# Subscription Name
	[string]	$BillingPeriod					# 6 characters in the form 'YYYYMM' or 8 characters as 'YYYYMMDD'
	[double]	$TotalAzure						# Raw Sum
	[double]	$TotalAzureRounded				# Each value is rounded before adding to sum
	[double]	$TotalAzureTrunc				# Each value is truncated before adding to sum
	[double]	$TotalMarketplace				# Raw Marketplace Sum
	[string]	$Currency						# This comes from a different location
	[string]	$OfferID
	[string]	$Note = "Marketplace is not summed up yet"
	# The ResourceGroups and Tags are hashtable by name which have the sum of the total for the day
	[hashtable] $MeterCategories = @{}			# Sum by MeterCategory
	[hashtable]	$ResourceGroups = @{}			# Sum by Resource Group name
	[hashtable]	$Tags = @{}						# Sum by (selected) tag name values  (.Name__Value)
	[hashtable]	$Locations = @{}				# Sum by Azure Locations
	[hashtable]	$CostCenters = @{}				# Sum by CostCenter (EA Only)
	[hashtable]	$DepartmentNames = @{}			# Sum by DepartmentID (EA Only)
	[hashtable] $RG_Tags = @{}					# Sum by ResourceGroup + Tag

	# AddTotal() - Adds a double value to AzureTotal
	# Usage: $x = $SubscriptionEntry.AddTotal(value)
	[SubscriptionEntry] AddTotal ([double] $a1)
	{
		$This.TotalAzure		+= $a1
		$This.TotalAzureRounded	+= [math]::Round($a1,2)
		$This.TotalAzureTrunc	+= [math]::Truncate($a1*100)/100
		Return $This
	}
}


# +=================================================================================================+
# |  FUNCTIONS																						|
# +=================================================================================================+

# +-------------------------------------------------------------------------+
# |  HashTableToString()													|
# |																			|
# |  Converts a Hash Table into a json string								|
# |  http://stackoverflow.com/questions/21413483/converting-hashtable-to-array-of-strings
# |	 Can also do: $HashTable.Tags | ConvertTo-JSON -compress).Replace('"',"'")
# +-------------------------------------------------------------------------+
function HashTableToString
{
    param (
        $HashTable
    )

	$tagString = ""
	if ($HashTable.Count -gt 0)
	{
		$tagsList = $HashTable.GetEnumerator() | % { "$($_.Name)='$($_.Value)'" }
		foreach ($tag in $tagsList)
			{ $tagString += $tag + ";" }
		$tagString = "{" + $tagString.Substring(0,$tagString.Length-1) + "}"
	}
	else
	{
		return "{}"		# Empty list
	}
	return $tagString
}

# +-------------------------------------------------------------------------+
# |  HashTableToPSObject()													|
# |																			|
# |  Converts a Hash Table into a json string								|
# +-------------------------------------------------------------------------+
function HashTableToPSObject
{
    param (
        $HashTable
    )
	
	$obj = New-Object PSObject
	foreach ($key in $HashTable.Keys)
	{
		$obj | Add-Member -NotePropertyName $key -NotePropertyValue $HashTable.$Key
	}
	return ([PSObject] $obj)
}

# +-------------------------------------------------------------------------+
# |  Make-CSVFriendly()														|
# |																			|
# |  Fix up a line of text in preparation for writing a CSV file.			|
# |  https://stackoverflow.com/questions/19450616/export-csv-exports-length-but-not-name
# |																			|
# +-------------------------------------------------------------------------+
function Make-CSVFriendly
{
	[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
	param (
		[Parameter(Mandatory=$true)] [AllowEmptyString()] [string] $item
	)
	
	# If Null, we're done
	if (!$item) { return "" }
	
	# Remove <CR> and <LF>
	$result = $item.Replace('`n',' ').Replace('`r',' ')
	
	# If there are no commas, then we're done
	if (!$result.contains(",")) { return $result }
	
	# Replace double quotes with double double quotes
	# and then quote the whole result to process embedded commas
	$result = [char]34 + $result.Replace('"','""') + [char]34
	return $result
}


# +=================================================================================================+
# |  PARAMETER / INPUT VERIFICATION																	|
# +=================================================================================================+
if (!$InputPath -And !$InputObject)
{
	write-error "Must specify either -Path or -InputObject"
	return
}

# Extract Input CSVPath
if ($InputObject)
	{ $InputPath = $InputObject.CSVPath }
	
# Verify that input file exists
if ((test-path -PathType 'leaf' $InputPath) -eq $false)
{
	write-warning "Input file does not exist: $InputPath"
	return
}



# +=================================================================================================+
# +=================================================================================================+
# |  MAIN																							|
# +=================================================================================================+
# +=================================================================================================+
$StartTime = Get-Date
$Global:MBfree	= (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue   # Not available in Runbooks!!
$BillingPeriodStart	= [datetime]::Parse('2050-01-01T00:00:00.000Z') 	# Way in the future!
$BillingPeriodEnd	= [datetime]::Parse('2000-01-01T00:00:00.000Z') 	# Way in the past!

#
# Get Current directory (PowerShell scripts seem to default to the Windows SYstem32 folder)
#
$invocation = (Get-Variable MyInvocation).Value
$directorypath = Split-Path $invocation.MyCommand.Path
# $directorypath = Convert-path "."   # Use the path we launched in (vs. the path of the script)
[IO.Directory]::SetCurrentDirectory($directorypath)   # Set our current directory

# 
# Get Temp Folder into $TempFolder and $TempFile
#
if ($env:TEMP)
	{ $TempFolder = $env:TEMP }
elseif ($env:TMP)
	{ $TempFolder = $env:TMP }
else
	{ $TempFolder = [IO.Directory]::GetCurrentDirectory() }
$TempFile = [System.IO.Path]::GetTempFileName()


#
# Determine the output path and filename
# If no output path specified, use the path of the input file.
# If no filename specified, create one based on the input file named with '_Summary' appended.
# $FullOutputPath contains the path that will be written to (or $null if none)
#
if ($OutputPath -eq '*')
{
	# User has indicated to create an output filename base don the input name
	if ($InputPath.Contains('\'))
		{ $OutputDir = $InputPath.SubString(0,$InputPath.LastIndexOf('\')+1) }		# Better than $OutputDir = [System.IO.Path]::GetDirectoryName($InputPath)
	else
	{
		$OutputDir = $directorypath 
		if ($OutputDir[-1] -ne [char] '\')
			{ $OutputDir += '\' }
	}
	$BaseFilename 	= [System.IO.Path]::GetFileNameWithoutExtension(($InputPath | Split-Path -leaf))
	$FullOutputPath	= $OutputDir + $BaseFilename + '_Summary.csv'
	write-verbose "Auto-generated output file path is: $FullOutputPath"	
}
elseif ($OutputPath)
{
	if (test-path -PathType 'Container' $OutputPath)
	{ 
		# No filename was specified but an output path was specified
		$OutputDir		= $OutputPath
		if ($OutputDir[-1] -ne [char] '\')
			{ $OutputDir += '\' }	# Append trailing slash
		
		# Generate Output name based on input filename
		$BaseFilename	= [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
		$OutputFilename = $BaseFilename + '_Summary.csv'
		# $Ext			= 'csv'
		$FullOutputPath	= $OutputDir + $OutputFilename
	}
	elseif (test-path -PathType 'leaf' $OutputPath)
	{
		# Output file exists
		if ($NoClobber)
		{
			write-warning "Output file $OutputPath exists and -NoClobber was specified. Aborting."
			return
		}
		
		# $OutputDir 		= [System.IO.Path]::GetDirectoryName($OutputFilename)
		# $OutputFilename 	= ($OutputPath | Split-Path -leaf)
		# $BaseFilename		= [System.IO.Path]::GetFileNameWithoutExtension($OutputFilename)
		# $Ext 				= [System.IO.Path]::GetExtension($OutputFilename)
	}
	elseif ($OutputPath[-1] -eq [char] '\') 
	{
		# a non-existant output folder was specified
		# Generate Output name based on input filename
		$BaseFilename	= [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
		$OutputFilename = $BaseFilename + '_Summary.csv'
		$FullOutputPath	= $OutputPath + $OutputFilename
	}
	elseif ((($OutputPath | Split-Path -leaf).Contains('.')) -eq $false)
	{
		# Generate Output name based on input filename
		$BaseFilename	= [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
		$OutputFilename = $BaseFilename + '_Summary.csv'
		$FullOutputPath	= $OutputPath + '\' + $OutputFilename
	}
	else
    {
		# It appears a filename was specified
		# so do nothing ($OutputPath is fine)
		$FullOutputPath	= $OutputPath
	}
	
	write-verbose "Output file path is: $FullOutputPath"
}
else
{
	# No -OutputPath was specified
	write-verbose "No -OutputPath specified."
	$FullOutputPath = $null
}
# write-host -ForegroundColor Cyan "Output file is: $FullOutputPath" ; return		# DEBUG


# +=================================================================================================+
# |  SCHEMA : Data Columns in the CSV and for SQL (future feature)									|
# +=================================================================================================+
# The schema defines known types by their column name (as listed in the CSV).
# Any additional columns are added as varchar[100] / string values.
# This allows the schema to be dynamic should a new column appear in the CSV.
# The Order property dictates the column order as it appears in the CSV.
#

$DataColumns = @()
# CREATE TABLE Detail_$EnrollmentId () based EA COnsumption API v3 and standard CSV formats
$DataColumns += [DataSchema]::New().SetValues('accountID', 'bigint', 'long')
$DataColumns += [DataSchema]::New().SetValues('accountName', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('accountOwnerEmail', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('additionalInfo', 'varchar(1000)', 'string')
$DataColumns += [DataSchema]::New().SetValues('consumedQuantity', 'float', 'double')
$DataColumns += [DataSchema]::New().SetValues('consumedService', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('consumedServiceId', 'bigint', 'long')
$DataColumns += [DataSchema]::New().SetValues('cost', 'float', 'double')
$DataColumns += [DataSchema]::New().SetValues('costCenter', 'nvarchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('date', 'datetime NOT NULL', 'string')				# Do NOT cast as [DateTime] (needs format conversion) !!
$DataColumns += [DataSchema]::New().SetValues('departmentID', 'bigint', 'long')
$DataColumns += [DataSchema]::New().SetValues('departmentName', 'nvarchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('instanceId', 'varchar(1000)', 'string')
$DataColumns += [DataSchema]::New().SetValues('meterCategory', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('meterId', 'char(36)', 'string')
$DataColumns += [DataSchema]::New().SetValues('meterName', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('meterRegion', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('meterSubCategory', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('product', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('productID', 'bigint', 'long')
$DataColumns += [DataSchema]::New().SetValues('resourceGroup', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('resourceLocation', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('resourceLocationID', 'int', 'int')
$DataColumns += [DataSchema]::New().SetValues('resourceRate', 'float', 'double')
$DataColumns += [DataSchema]::New().SetValues('serviceAdministratorId', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('serviceInfo1', 'varchar(1000)', 'string')
$DataColumns += [DataSchema]::New().SetValues('serviceInfo2', 'varchar(1000)', 'string')
$DataColumns += [DataSchema]::New().SetValues('storeServiceIdentifier', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('SubscriptionGuid', 'char(36)', 'string')
$DataColumns += [DataSchema]::New().SetValues('subscriptionId', 'bigint', 'long')
$DataColumns += [DataSchema]::New().SetValues('subscriptionName', 'nvarchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('tags', 'nvarchar(4000)', 'string')
$DataColumns += [DataSchema]::New().SetValues('unitOfMeasure', 'varchar(100)', 'string')
$DataColumns += [DataSchema]::New().SetValues('PartNumber', 'varchar(20)', 'string')
$DataColumns += [DataSchema]::New().SetValues('ResourceGuid', 'char(36)', 'string')
$DataColumns += [DataSchema]::New().SetValues('OfferId', 'varchar(16)', 'string')
$DataColumns += [DataSchema]::New().SetValues('ChargesBilledSeparately', 'varchar(6)', 'string')
$DataColumns += [DataSchema]::New().SetValues('Location', 'varchar(60)', 'string')
$DataColumns += [DataSchema]::New().SetValues('ServiceName', 'varchar(250)', 'string')
$DataColumns += [DataSchema]::New().SetValues('ServiceTier', 'varchar(250)', 'string')
# -- These columns are unique to the Standard format
$DataColumns += [DataSchema]::New().SetValues('AccountOwnerId', 'varchar(250)', 'string')		# Same as EA AccountOwnerEmail
$DataColumns += [DataSchema]::New().SetValues('AvailabilityZone', 'varchar(250)', 'string')		# (not provided in EA)
$DataColumns += [DataSchema]::New().SetValues('UsageQuantity', 'varchar(250)', 'string')		# Same as EA ConsumedQuantity
$DataColumns += [DataSchema]::New().SetValues('PreTaxCost', 'float', 'double')					# Same as EA Cost
$DataColumns += [DataSchema]::New().SetValues('Currency', 'varchar(12)', 'string')				# (not provided in EA)
$DataColumns += [DataSchema]::New().SetValues('UsageDateTime', 'datetime NOT NULL', 'string')	# Same as EA date - Do not cast as [DateTime] (format conversion req'd)
$DataColumns += [DataSchema]::New().SetValues('ProductName', 'varchar(250)', 'string')			# Same as EA Product
$DataColumns += [DataSchema]::New().SetValues('ResourceType', 'varchar(250)', 'string')			# (not provided in EA)
# -- Generated Columns for SQL / additional info
#  BillingMonth AS CAST(CONCAT(YEAR(date),RIGHT('00' + CAST(MONTH(date) AS varchar(2)), 2 )) AS char(6)), 
#  BillingDay AS CAST(CONCAT(YEAR(date),'-',RIGHT('00' + CAST(MONTH(date) AS varchar(2)), 2 ),'-',RIGHT('00' + CAST(DAY(date) AS varchar(2)), 2 ) ) AS char(8)),
$DataColumns += [DataSchema]::New().SetValues('BillingMonth',  "AS CAST(CONCAT(YEAR(date),RIGHT('00' + CAST(MONTH(date) AS varchar(2)), 2 )) AS char(6))", 'string')
$DataColumns += [DataSchema]::New().SetValues('BillingDay',    "AS CAST(CONCAT(YEAR(date),'-',RIGHT('00' + CAST(MONTH(date) AS varchar(2)), 2 ),'-',RIGHT('00' + CAST(DAY(date) AS varchar(2)), 2 ) ) AS char(8))", 'string')


# +=================================================================================================+
# | Get CURRENT list of Resource Groups with tags													|
# +=================================================================================================+
# This is used to find any cost center IDs or service Owners attached to resource groups.
# Unfortunately, this does NOT look back in time but can allow us to do some speculative summations
# for those resources lacking a cost Center ID but where the ResourceGroup itself has the tag.
# The billing data does NOT capture an entry just for resource groups as it is not a billable item by itself.
# The Kusto Query below is dynamically extended to pull up the tags we're interested in
# KUSTO QUERY (via a role that can see all subscriptions!)
# $TagsToMonitor = @('Cost Code ID', 'CostCenter', 'Service Name')
# resourcecontainers
#	| where type == 'microsoft.resources/subscriptions/resourcegroups'
#	| extend CostCodeID = tostring(tags['Cost Code ID'])
#	| extend CostCenter = tostring(tags['CostCenter'])
#	| extend ServiceName = tostring(tags['Service Name'])
# | join kind=leftouter (ResourceContainers | where type=~'microsoft.resources/subscriptions' 
#	 | project SubName=name, subscriptionId) on subscriptionId
#	 | project subscriptionId, SubName, type, resourceGroup, location, CostCodeID, CostCenter, ServiceName, tenantId, tags, id
#
if ($false)
{
	$ProjectList = ""					# Tags to Monitor with Spaces Removed 
	$KustoQuery = "resourcecontainers
	 | where type == 'microsoft.resources/subscriptions/resourcegroups'`n"
	foreach ($tag in $TagsToMonitor)
	{
		$KustoQuery += "	| extend " + $tag.Replace(' ','') + " = tostring(tags['" + $tag + "'])`n"
		$ProjectList += $tag.Replace(' ','') + ', '
	}

	$KustoQuery += " | join kind=leftouter (ResourceContainers | where type=~'microsoft.resources/subscriptions' 
	 | project SubName=name, subscriptionId) on subscriptionId
	 | project subscriptionId, SubName, type, resourceGroup, location, " + $ProjectList + "tenantId, tags, id"
	$ResourceGroups = @()
	$SkipCount = 0
	Do 
	{	# Search-AzGraph doesn't like a -SkipCount of zero
		if ($SkipCount -eq 0)
			{ $r = Search-AzGraph -query $KustoQuery -First 1000 } # -ErrorAction SilentlyContinue
		else
			{ $r = Search-AzGraph -query $KustoQuery -First 1000 -Skip $SkipCount } # -ErrorAction SilentlyContinue
		$ResourceGroups += $r
		$SkipCount += 1000
	}
	Until ($r.Count -lt 1000)
	
	# For resource groups without a 'Cost Code ID' tag, find any resources
	# within the resource group with such a tag to GUESS if that is the cost code...
	# Resources
	# | where resourceGroup =~ 'azsu-rg-azure-sentinel'
	# | where tags has 'Cost Code ID' or tags has 'Service Owner'
	# | extend CostCodeID = tostring(tags['Cost Code ID'])
	# | extend ServiceName = tostring(tags['Service Name'])
}


# +=================================================================================================+
# |  Read the Source CSV																			|
# +=================================================================================================+
# We use System.IO.StreamReader to keep the in-memory footprint small.
# Line by line is slower but these input files may be HUGE (2GB+).

write-verbose "Processing CSV headers..."
Try
{
	$FileSize	= (Get-Item $InputPath).Length
	$Handle 	= New-Object System.IO.StreamReader($InputPath) -ErrorVariable Err1
}
Catch
{
	write-warning "Error opening input file: $($Err1.Message)"
	return
}
### Reading file stuff here

# +---------------------------------+
# | First, find the CSV header...	|
# +---------------------------------+
# Read lines until we get a line with commas. This skips any extra header stuff that Azure adds.
$Header = @()
$ByteCount = [int] 0
$SkipCount = 0
while (($line = $Handle.Readline()).Contains(',') -eq $False)
{
	$Header += $line
	$SkipCount++
	$ByteCount += $line.Length
	if ($line -eq $null)
	{
		write-warning "No header found in CSV."
		return $null
	}
}

# Now $line should have the headers
write-verbose "CSV Header: $line"
# Split by commas and then 
$CSVColumns = $line.split(',')
for ($i = 0; $i -lt $CSVColumns.Count; $i++)
{
	# Trim leading/training whitespace
	$CSVColumns[$i] = $CSVColumns[$i].Trim()
	
	# Merge column list with pending CLASS object
	if (($j = $DataColumns.NameLower.IndexOf($CSVColumns[$i].ToLower())) -ge 0)
		{ $DataColumns[$j].Order = $i }  # DEBUG: ; write-host "DataColumns[$j].$($DataColumns[$j].Name) <- $i [$($CSVColumns[$i])] "
	else
		{ $DataColumns += [DataSchema]::New().SetValues($CSVColumns[$i], 'varchar(100)', 'string') }
}

# Spot check the CSV format
if ($CSVColumns -NotContains 'MeterCategory' `
	-And $CSVColumns -NotContains 'ResourceGroup' `
	-And $CSVColumns -NotContains 'SubscriptionGuid')
{
	write-error "Unrecognized Input File: This must be an Azure detailed usage CSV"
	return $null
}
# And determine the format...
if ($CSVColumns -Contains 'PreTaxCost')
{ 
	# Standard format
	$CSVFormat = 2 
	write-verbose "Input CSV appears to be standard format (non_EA)"
}
elseif ($CSVColumns -Contains 'Cost')
{ 
	# EA format
	$CSVFormat = 1
	write-verbose "Input CSV appears to be in Enterprise Agreement (EA) format"
}
else
{
	write-error "Invalid Azure Usage CSV: 'Cost' or 'PreTaxCost' is missing"
	return $null
}

#
# Dynamically create the Class based on the Schema
#
$CSVColumns2 = ($DataColumns | Where-Object { $_.Order -ge 0 } | Sort-Object -Property Order)
Invoke-Expression @"
Class DataRow {
  $($CSVColumns2.ForEach({"[$($_.PSType)] `${$($_.Name)}`n "}))
}
"@

# +---------------------------------+
# | Now process the CSV body...		|
# +---------------------------------+
$RowCount = [int] 0					# CSV Rows
$Subscriptions = @()			# Data about each subscription for the time period
write-verbose "Processing CSV body..."
$MBfreeNow = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue	# Not available in Runbooks!!
if (($FileSize -ge (($MBfreeNow * 1MB)-500MB)) -And ($UseSystemIO -eq $false))
{
	write-warning "There may not be enough memory to complete the task. The input file is $($FileSize / 1MB)MB and there is estimated only $($MBNfreeNow)MB free."
}

if ($UseSystemIO)
{
	$DataRows = @()					# Row data (we don't have to keep but can)
	$Activity = "Reading CSV Data ($($CSVColumns.Count) columns per Row) - $InputPath"
	$line = $Handle.ReadLine()
}
else
{
	$Handle.Close() ; $Handle.Dispose()	# Close the file
	if ($SkipCount -gt 0)
	{
		write-host -NoNewLine -ForegroundColor Yellow "Ingesting $([Math]::Round(($FileSize / 1MB),2)) MB of data to a temporary CSV file... "
		$Time1 = Get-Date
		get-content $InputPath | select-object -skip $SkipCount | Out-file $TempFile
		$TimeTxt = ((get-Date) - $Time1) -f 'ss'
		$MBfreeNow = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue	# Not available in Runbooks!! ALSO IS SLOW
		$MBused = $Global:MBfree - $MBfreeNow
		write-host " Time Taken: $TimeTxt   ($MBUsed MB used)"
	}
	else
	{
		# No need for temporary file if the header is at the top
		# The EA CSV files have extra lines annoyingly.
		$TempFile = $InputPath
	}
		
	write-host -NoNewLine -ForegroundColor Yellow "Importing $([Math]::Round(($FileSize / 1MB),2)) MB CSV... "
	$Time1 = Get-Date
	$AllData = Import-Csv $TempFile -Delimiter ',' 	# Ingest using Import-CSV
	$TimeTxt = ((get-Date) - $Time1) -f 'ss'
	$MBfreeNow = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue	# Not available in Runbooks!! ALSO IS SLOW
	$MBused = $Global:MBfree - $MBfreeNow
	write-host " $($AllData.Count) entries.  Time Taken: $TimeTxt   ($MBUsed MB used)"
	# Don't delete the source file by accident! 
	if ($TempFile -ne $InputPath)
	{
		write-host -NoNewLine -ForegroundColor Yellow "Deleting temporary file... "
		Del $TempFile								# Remove the temporary file
	}
	$line = "UseSystemIO"						# For the WHILE loop below...
	write-host "OK"
	$Activity = "Analysing in-memory CSV Data ($($CSVColumns.Count) columns per Row) - $InputPath"
}

#
# Loop through the data...
#
$Time1 = Get-Date
write-host -ForegroundColor Yellow -NoNewLine "Analysing Data "
if ($UseSystemIO)
	{ write-host -NoNewLine -ForegroundColor Yellow "via System.IO (slow)... " }
write-host -ForegroundColor Yellow -NoNewLine "... "
while ($line -ne $null)
{
	if ($UseSystemIO)
	{	# System.IO
		$RowCount++
		$ByteCount += $line.Length
		$pctComplete = [string] ([math]::Truncate(($ByteCount / $FileSize)*100))
		write-progress -Activity $Activity -Status "$ByteCount / $FileSize bytes;  Row: $RowCount ($pctComplete%)" -PercentComplete $pctComplete
		$SplitLine = [regex]::Split( $line , ',(?=(?:[^"]|"[^"]*")*$)' )		# Same as: $line -split ',(?=(?:[^"]|"[^"]*")*$)'   OR (?=([^\"]*\"[^\"]*\")*[^\"]*$)")

		# Create a new Row object and populate it
		$j = [int] 0
		$row = [DataRow]::New()			# New-Object DataRow
		foreach ($prop in $CSVColumns)
		{
			if ($prop.DSType -like 'datetime')
				{ $row.$prop = [datetime]::Parse($SplitLine[$j++]) }
			else
				{ $row.$prop = $SplitLine[$j++] }
		}
		# $DataRows += $row	# OPTIONAL!  We don't need to save it
		
		# Move to next line in file (for the loop)
		$line = $Handle.ReadLine()
	}
	else
	{	# Data is in $AllData
		$row = $AllData[$RowCount]
		$pctComplete = [string] ([math]::Truncate(($RowCount / $AllData.Count)*100))
		write-progress -Activity $Activity -Status "Row $RowCount of $($AllData.Count) ($pctComplete%)" -PercentComplete $pctComplete
		$RowCount++
		if ($RowCount -gt $AllData.Count)
			{ $line = $null ; break }
	}

		
	# +-------------------------------------------------+
	# | Extract the cost based on the CSV format		|
	# +-------------------------------------------------+
	if ($CSVFormat -eq 2)		# Standard format
		{ $Cost = [double] $row.PreTaxCost }	
	else 						# EA v3 format (format = 1)
		{ $Cost = [double] $row.Cost }

	# +-------------------------------------------------+
	# | Extract the date and convert to [datetime]		|
	# +-------------------------------------------------+
	# write-host "Row.Date is '$($row.Date)'"  # DEBUG
	if ($row.Date.GetType().Name -Like 'DateTime')
		{ $Date = $row.Date }						# Previously converted
	elseif ($row.Date.Contains('/'))
		{ $Date = [datetime]::ParseExact($row.Date, "MM/dd/yyyy hh:mm:ss", $null) }
	else
		{ $Date = [datetime]::Parse($row.Date)} 	# Convert from ISO-8601 "2011-08-12T20:17:46.384Z"
	$BillingMonth = $Date.ToString('yyyyMM')
	$BillingDay	  = $Date.ToString('yyyyMMdd')
	
	# Determine the BillingPeriod value
	if ($DailyTotals)
		{ $BillingPeriod = $BillingDay }
	else
		{ $BillingPeriod = $BillingMonth }
	
	# Track the earliest and latest dates seen in the billing data overall
	if ($Date -lt $BillingPeriodStart)
		{ $BillingPeriodStart = $Date }
	if ($Date -gt $BillingPeriodEnd)
		{ $BillingPeriodEnd = $Date }
		
	# See if we are spanning more than one month in the input data...
	if (!$FirstDate)
		{ $FirstDate = $Date ; $DateWarning = $false}
	elseif (!$DateWarning -And ($Date.Month -ne $FirstDate.Month -Or $Date.Year -ne $FirstDate.Year))
	{
		write-warning "Input data covers more than the single month of $($FirstDate.ToString('yyyy-MM')) at row $RowCount for date $BillingDay"
		$DateWarning = $true
	}
	
	# +-------------------------------------------------+
	# | Generate a Lookup Key in Array					|
	# | One entry per subscription per billing period	|
	# +-------------------------------------------------+
	$Key = $row.SubscriptionGuid.ToLower() + '_' + $BillingPeriod

	# +---------------------+
	# | Subscriptions		|
	# +---------------------+
	if ($Subscriptions.Key -NotContains $Key)
	{
		# write-host -ForegroundColor Gray "NEW KEY $($Subscriptions.Count):  $Key"		# DEBUG
		$sub = New-Object SubscriptionEntry
		$sub.Key					= $Key			# Lookup Key
		$sub.TenantId 				= ''			# TenantID is not in the billing data!!#
		$sub.SubscriptionID			= $row.SubscriptionGuid
		$sub.SubscriptionName		= $row.SubscriptionName
		$sub.BillingPeriod			= $BillingPeriod # In the form 'YYYYMM' or 'YYYYMMDD'
		$sub.TotalAzure 			= 0.0
		$sub.TotalAzureRounded 		= 0.0
		$sub.TotalAzureTrunc		= 0.0
		$sub.TotalMarketplace 		= 0.0			# Separate Report
		$sub.Currency				= ''			# Currency is in a different report
		$sub.OfferID				= $row.OfferID
		# The ResourceGroups and Tags are hashtable by name which have the sum of the total for the day
		$sub.MeterCategories		= @{}			# Sum by MeterCategory
		$sub.ResourceGroups			= @{}			# Sum by Resource Group name
		$sub.Tags					= @{}			# Sum by (selected) tag name values  (.Name__Value
		$sub.Locations				= @{}			# Sum by Azure Locations
		$sub.CostCenters			= @{}			# CostCenter (EA Only)
		$sub.DepartmentNames		= @{}			# DepartmentID (EA Only)
		$Subscriptions += ,$sub
	}
	$Sub_Index = $Subscriptions.Key.IndexOf($Key)

	# +---------------------+
	# | Subscription Total	| 					
	# +---------------------+
	$Subscriptions[$Sub_Index].AddTotal($Cost) > $null  # $Subscriptions[$Sub_Index].TotalAzure += $Cost 
	
	# +-------------------------------------------------+
	# | Process the various summation hash tables		|
	# |   (e.g., 'MeterCategories', 'ResourceGroups',	|
	# |    'CostCenters', 'DepartmentNames', Locations)	|
	# +-------------------------------------------------+
	$k = [int] 0
	foreach ($ht in $HashTables)
	{
		$Prop = $HTPropNames[$k]
		if ($row.$Prop.Length -gt 0)
			{ $Subscriptions[$Sub_Index].$ht.$($row.$Prop) += [double] $Cost }
		else
			{ $Subscriptions[$Sub_Index].$ht.'{unspecified}' += [double] $Cost }
		$k++
	}
	
	# +---------------------+
	# | Tags				|
	# +---------------------+
	# Tags format without Import-CSV: "{""Cost Code ID"":""D.3545-01-R01"",""Environment"":""Sandbox"",""Service Name"":""CLOUD PLATFORM-MICROSOFT AZURE"",""Service Owner"":""Matthew Johns""}"
	if ($row.Tags.Length -gt 2)
	{
		if ($UseSystemIO)
			{ $Tags	= ($row.tags.SubString(1,$row.tags.Length-2).Replace('""','"') | ConvertFrom-Json) }
		else
			{ $Tags = $row.tags | ConvertFrom-Json }
	}
	else
		{ $Tags = $null }
	# TBD as TagName__Value -- but only for tags we want to track... $TagsToMonitor()
	# WARNING: Tag values may need to be escaped if they have weird characters...
	# For any tags attached to a resource group, all of the subordinate resources should be included
	# We can't see this though 
	foreach ($tag in $TagsToMonitor)
	{
		if ($Tags.$tag)
		{
			$TagValue = $tag + ':' + $Tags.$tag		# Tag:Value
			$Subscriptions[$Sub_Index].Tags.$($TagValue) += [double] $Cost
		}
		else
		{
			# The tag is not present, so construct an "{unspecified}" value
			# so that we sum up those assets lacking this particular tag...
			if ($IncludeUnspecified)
			{
				$TagValue = $tag + ':{unspecified}'
				$Subscriptions[$Sub_Index].Tags.$($TagValue) += [double] $Cost
			}
			else
				{ $TagValue = $null }
		}
		# And now add the value into the .Tags hash table
		
		# +---------------------------------+
		# | Tags under each Resource Group	|
		# +---------------------------------+
		# By capturing all of the Tags of interest in $TagsToMonitor under each resource group
		# and recording it, this will allow someone to better allocate the resource group charges.
		# We would also capture these tags for the resource group itself (using Kusto)... bearing in mind
		# that the resource group tags only reflect the current setting and not at the time of billing.
		# 
		# .RG_Tags = @{}
		# $TagValue contains the "Tagname:TagValue" string and $Cost has the applicable cost.
		# We just need to add the Resource Group name as a prefix so we get "ResourceGroup:Tagname:TagValue" = $Cost
		if ($TagValue)
		{
			$RGTagValue = $Row.ResourceGroup + ':' + $TagValue
			if (($RGTagValue -Split ':').Count -ne 3)
				{ write-warning "Failure creating RG_Tag:Tagname:TagValue at row $RowCount - '$RGTagValue'" }
			$Subscriptions[$Sub_Index].RG_Tags.$($RGTagValue) += [double] $Cost
		}
	}	
}

# Done with ingesting CSV data...
$Handle.Close() ; $Handle.Dispose()		# Close the file
$TimeTxt = ((get-Date) - $Time1) -f 'ss'
write-host " $RowCount rows processed; $($Subscriptions.Count) records generated.   Time Taken: $TimeTxt"
write-progress -Activity $Activity -PercentComplete 100 -Completed

# DEBUG
#	$j = [int] 0
#	foreach ($prop in $CSVColumns)
#		{ write-host "$prop : $($SplitLine[$j++])" }


# +-------------------------------------------------------------------------+
# | Update the $Subscriptions data to convert the HashTables into PSObjects	|
# +-------------------------------------------------------------------------+
# This code is dodgy as it creates many more instances of items in $Subscriptions... Weird
write-verbose "Converting results into output object..."
foreach ($sub in $Subscriptions)
{
	# Rebuild as a PSObject, eliminating HashTables items (ConvertTo-Json fails otherwise)
	$Members = ($sub | Get-Member | Where-Object {$_.MemberType -NotLike 'Method'})
	$HashTableProps = ($sub | Get-Member | Where-Object {$_.Definition -Like 'hashtable*'} ).Name
	$Temp = $Sub | Select-Object -Property * -ExcludeProperty $HashTableProps 		# MeterCategories,ResourceGroups,Tags,Locations,CostCenters,DepartmentNames,DepartmentIDs
	foreach ($prop in $HashTableProps)
		{ $Temp | Add-Member -NotePropertyName $prop -NotePropertyValue ([PSObject]((HashTableToPSObject -HashTable $sub.$prop))) }

	
	
	# Export-CSV won't flatten it.
	# We need to take the unique
	# TBD WHAT??
	
}

# +---------------------------------------------------------------------------------+
# | Update the $OutputPath to include the Billing Period covered if	'*' specified	|
# +---------------------------------------------------------------------------------+
if ($FullOutputPath -And $OutputPath -eq '*')
{
	# Factor in the billing period if it doesn't appear in the source data
	# Default to _YYYYMM is it is for a full single month, otherwise default to
	# _YYYY-MM-DD_YYYY-MM-DD  to indiacte a date range.
	# $BillingPeriodStart and $BillingPeriodEnd has the range we actually saw.
	if ($BillingPeriodStart.Month -eq $BillingPeriodEnd.Month -And $BillingPeriodStart.Year -eq $BillingPeriodEnd.Year)
	{
		# Billing coverage is within a single month (but could be less)
		$LastDayOfMonth = $BillingPeriodStart.AddMonths(1).AddDays(0-$BillingPeriodStart.Day).Day
		if ($BillingPeriodStart.Day -eq 1 -And $BillingPeriodEnd.Day -eq $LastDayofMonth)
			{ $CandidateDate = '_' + $BillingPeriodStart.ToString('yyyyMM') }
#		elseif if ($BillingPeriodStart.Day -eq 1 -And (Get-Date).Month -eq $BillingPeriodEnd.Month -And (Get-Date).Year -eq $BillingPeriodEnd.Year)
#		{
#			# We're in the current month so we can optionally use 'YYYYMM'
#			$CandidateDate = $BillingPeriodStart.ToString('yyyyMM')
#		}
		else
            { $CandidateDate = '_' + $BillingPeriodStart.ToString('yyyy-MM-dd') + '_' + $BillingPeriodEnd.ToString('yyyy-MM-dd') }
	}
	else
	{
		# Date range is not a full month or exceeds a month
		$CandidateDate = '_' + $BillingPeriodStart.ToString('yyyy-MM-dd') + '_' + $BillingPeriodEnd.ToString('yyyy-MM-dd')
	}
	
	# If the $CandidateDate does not already exist in the $FullOutputPath, then we will add it
	if ($FullOutputPath.Contains($CandidateDate) -eq $false)
	{
		$FullOutputPath = $FullOutputPath.Replace('_Summary.csv', $CandidateDate + '_Summary.csv')
	}
}

# +----------------------------------------------------------------------------------+
# | Sum up the grand total(s)														 |
# +----------------------------------------------------------------------------------+
write-verbose "Summing up the Grand Totals"
$Totals_By_Tag				= @{}				# Hash Table for
$Totals_HashTableList		= @('Totals_By_Tag')	# The list of Hashtables we generate
foreach ($pn in $HTPropNames)
{
	if ($pn -NotLike "ResourceGroup")
	{
		Set-Variable -Name "Totals_by_$pn" -Value @{} 
		$Totals_HashTableList += , "Totals_by_$pn"
	}
}

$GrandTotalAzure		= [double] 0.0		# Raw Sum
$GrandTotalAzureRounded = [double] 0.0		# Each value is rounded before adding to sum
$GrandTotalAzureTrunc	= [double] 0.0		# Each value is truncated before adding to sum
$GrandTotalMarketplace	= [double] 0.0		# Raw Marketplace Sum
foreach ($sub in $Subscriptions)
{
	$GrandTotalAzure 		+= [double] $sub.TotalAzure			# Raw Sum
	$GrandTotalAzureRounded += [double] $sub.TotalAzureRounded	# Each value is rounded before adding to sum
	$GrandTotalAzureTrunc 	+= [double] $sub.TotalAzureTrunc		# Each value is truncated before adding to sum
	$GrandTotalMarketplace 	+= [double] $ssub.TotalMarketplace		# Raw Marketplace Sum

	# Tag Totals
	foreach ($key in $Sub.Tags.Keys)
	{
		if ($Totals_By_Tag.Keys -Contains $key)
			{ $Totals_by_Tag.$key += [double] $Sub.Tags.$key }
		else
			{ $Totals_by_Tag += @{ $Key = [double] $Sub.Tags.$key } }
	}

	# Other totals using $HashTables - but we skip 'ResourceGroups' as these are unique per subscription
	# $HashTables 	= @('MeterCategories', 'ResourceGroups', 'CostCenters', 'DepartmentNames', 'Locations')		    # All Except 'Tags'
	# $HTPropNames	= @('MeterCategory',   'ResourceGroup',  'CostCenter',  'DepartmentName',  'ResourceLocation')	# MUST be 1:1 with HashTables entry
	# This creates the HashTables: Totals_MeterCategory, Totals_CostCenter, Totals_DepartmentName, and Totals_ResourceLocation
	$k = [int] 0
	foreach ($ht in $HashTables)
	{
		if ($ht -NotLike 'ResourceGroups')
		{
			$VarName = "Totals_by_$($HTPropNames[$k])" 	# Variable name for Totals_HashTable
			foreach ($key in $sub.$ht.Keys)
			{
				$ThisItem = (Get-Variable $VarName)
				if ($ThisItem.Value.Keys -Contains $key)
					{ $ThisItem.Value.$key += [double] $Sub.$ht.$key }
				#{
				#	write-host -ForegroundColor Gray "Updating key '$key' under $VarName  ($($ThisItem.Name))..."
				#	write-host -ForegroundColor Gray "  KEYS: $($ThisItem.Value.Keys -join ', ')`n"
				#	$ThisItem.Value.$key += [double] $Sub.$ht.$key
				#}
				else
					{ $ThisItem.Value += @{$key = [double] $Sub.$ht.$key} }	   # Add new key
				#{
				#	write-host -ForegroundColor Gray "Adding key '$key' to $VarName..."
				#	write-host -ForegroundColor Gray "  KEYS: $($ThisItem.Value.Keys -join ', ')`n"
				#	$ThisItem.Value += @{$key = [double] $Sub.$ht.$key}
				#}
			}
		}
		$k++
	}
}


# +----------------------------------------------------------------------------------+
# | Generate Output File															 |
# +----------------------------------------------------------------------------------+
write-verbose "Generating output files"
$SortedSubscriptions = ($Subscriptions | Sort-Object -Property SubscriptionName, SubscriptionID, BillingPeriod)
if ($FullOutputPath -And ((test-path -Pathtype 'leaf' $FullOutputPath) -And $NoClobber))
{
	write-warning "The CSV output file exists and -NoClobber was specified, so it won't be overwritten`nCSV FILE: $FullOutputPath"
	$FullOutputPath = $null
}
elseif ($FullOutputPath)
{
	write-verbose "Final output path is: $FullOutputPath"
	
	# Also generate a .txt file (if .csv is the extension)
	if ($FullOutputPath.SubString($FullOutputPath.Length-4) -like '.csv')
	{
		$TextOutputPath = $FullOutputPath.SubString(0,$FullOutputPath.Length-4) + '.txt'
		if ((test-path -Pathtype 'leaf' $TextOutputPath) -And $NoClobber)
		{
			write-warning "The text output file exists and -NoClobber was specified, so it won't be overwritten`nTXT FILE: $TextOutputFile"
			$TextOutputPath = $null
		}
		
		if ($TextOutputPath)
		{
			# Create the file
			$Header  = "====================================================================================================`n"
			$Header += " Summary of Azure Spend                                                      (as of " + (get-date).ToString('MMM dd, yyyy') + ")`n"
			$Header += "====================================================================================================`n`n"
			$Header += "  Period  : " + $BillingPeriodStart.ToString('MMM dd, yyyy') + " through " + $BillingPeriodEnd.ToString('MMM dd, yyyy') + "`n"
			$Header += "  Input   : $InputPath `n"
			$Header | Out-File $TextOutputPath -Width 200 
			
			# Push in the totals
			"  GRAND TOTALS:"														| Out-File $TextOutputPath -Width 200 -Append    
			"    Azure Total (unrounded)  : {0,10:f5}" -f $GrandTotalAzure			| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Total (rounded)    : {0,10:f5}" -f $GrandTotalAzureRounded	| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Total (truncated)  : {0,10:f5}" -f $GrandTotalAzureTrunc		| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Marketplace Total  : {see separate report}`n"				| Out-File $TextOutputPath -Width 200 -Append	
			
			# General Notes
			# "  NOTE: Tag sums are for each Tag:Value combination. `n"	| Out-File $TextOutputPath -Width 200 -Append

			if ($DailyTotals)
			{
				"  NOTE: This report has an entry for each subscription for each billing day."	| Out-File $TextOutputPath -Width 200 -Append
				"        Omit the -DailyTotals switch to summarize by month.`n"	| Out-File $TextOutputPath -Width 200 -Append
			}			
			elseif ($DateWarning)
			{
				"  NOTE: This report covers more than a single month. There is an entry for each"	| Out-File $TextOutputPath -Width 200 -Append
				"        subscription for each billing month.`n"	| Out-File $TextOutputPath -Width 200 -Append
			}
			
			# Totals by various categories
			# $Totals_HashTableList
			foreach ($VarName in $Totals_HashTableList)
			{
				"`n  {0} : " -f $VarName.ToUpper() | Out-File $TextOutputPath -Width 200 -Append	# Header
				foreach ($key in ((Get-Variable -Name $VarName).Value.Keys) | Sort-Object)
				{
					"    {0,-40} : {1,9:f2} " -f $Key, (Get-Variable -Name $VarName).Value.$Key | Out-File $TextOutputPath -Width 200 -Append
				}
			}

			"`n  TOTALS_BY_RESOURCEGROUP :"											| Out-File $TextOutputPath -Width 200 -Append 
            "    { Not shown as resource groups do not span subscriptions }`n`n"    | Out-File $TextOutputPath -Width 200 -Append

		}
		
		if ($FullOutputPath)
		{
			# TODO: CSV Header
			# TBD - Output a Csv
			# MATRIX -Columns: SubscriptionName, SubId, ResourceGroupName, BillingPeriod, TotalSpend, Cost Center ID, Service Name, Service Owner, [Add'l per Tag]
			#     The [Add'l per Tag] columns are triples: TagName1, TagValue1, TagTotal1,     then  TagName2, TagValue2, TagTotal2,   etc.
			# Include: TagNameX, {unspecified}, Total as well  to catch untagged items
			# We generate a numbered column for each Tag of interest * 3 
			# Note that we do NOT include the total spend for the subscription so as not to confuse the data.
			# This can be obtained by summing the values for the subscription and billingPeriod.
			
			$CSVColumns = 'SubscriptionName,SubscriptionId,BillingPeriod,OfferID,Currency,ResourceGroup,Total,RG:' + ($TagsToMonitor -join ',RG:')
			for ($k = 1; $k -le $TagsToMonitor.Count * 4; $k++)
				{ $CSVColumns += ",Tag_$k,Total_$k" }
			
			$CSVColumns | Out-File $FullOutputPath -Width 500
			
			# Get MIME Type
			# Add-Type -AssemblyName "System.Web"
			#[System.Web.MimeMapping]::GetMimeMapping($FullOutputPath)
			#
			# Set the MIME Type
			# & $Env:WinDir\system32\inetsrv\appcmd.exe set config /section:staticContent /-"[fileExtension='.eml']"
			# & $Env:WinDir\system32\inetsrv\appcmd.exe set config /section:staticContent /+"[fileExtension='.eml',mimeType='application/octet-stream']"

		}
		
	}

	foreach ($sub in $SortedSubscriptions)
	{
		if ($TextOutputPath)
		{
			# Generate a nicely formatted text file
			"`n+-------------------------------------------------------------------------------------------------+" | Out-File $TextOutputPath -Width 200 -Append
			"|  {0,-47}  {1}          |" -f  $Sub.SubscriptionName, $Sub.SubscriptionId | Out-File $TextOutputPath -Width 200 -Append
			"+-------------------------------------------------------------------------------------------------+`n" | Out-File $TextOutputPath -Width 200 -Append
			
			# Subscription-level information
			"  SUBSCRIPTION INFORMATION:"									| Out-File $TextOutputPath -Width 200 -Append
			"    BillingPeriod            : $($Sub.BillingPeriod)"			| Out-File $TextOutputPath -Width 200 -Append
			"    OfferID                  : $($Sub.OfferID)"				| Out-File $TextOutputPath -Width 200 -Append
			"    Currency                 : $($Sub.Currency)"				| Out-File $TextOutputPath -Width 200 -Append
			"    Resource Group Count     : $($Sub.ResourceGroups.Count)"	| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Total (unrounded)  : $($Sub.TotalAzure)"				| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Total (rounded)    : $($Sub.TotalAzureRounded)"		| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Total (truncated)  : $($Sub.TotalAzureTrunc)"		| Out-File $TextOutputPath -Width 200 -Append
			"    Azure Marketplace Total  : {see separate report}"		| Out-File $TextOutputPath -Width 200 -Append	
			"`n"															| Out-File $TextOutputPath -Width 200 -Append
			
			# Tag Totals
			"  TOTALS BY TAG :"												| Out-File $TextOutputPath -Width 200 -Append
			if ($Sub.Tags.Keys.Count -gt 0)
			{
				foreach ($key in ($Sub.Tags.Keys | Sort-Object))
				{
					"    {0,-60}  : {1,9:f2}" -f $key, $Sub.Tags.$key | Out-File $TextOutputPath -Width 200 -Append
				}
				"`n"														| Out-File $TextOutputPath -Width 200 -Append
			}
			else 
				{ "    {No Tags Found}`n"									| Out-File $TextOutputPath -Width 200 -Append  }
			
			# Other totals using $HashTables
			# $HashTables 	= @('MeterCategories', 'ResourceGroups', 'CostCenters', 'DepartmentNames', 'Locations')		    # All Except 'Tags'
			# $HTPropNames	= @('MeterCategory',   'ResourceGroup',  'CostCenter',  'DepartmentName',  'ResourceLocation')	# MUST be 1:1 with HashTables entry
			$k = [int] 0
			foreach ($ht in $HashTables)
			{
				$Prop = $HTPropNames[$k]

				"  TOTALS BY $Prop :"												| Out-File $TextOutputPath -Width 200 -Append
				foreach ($key in ($Sub.$ht.Keys | Sort-Object))
				{
					if ($ht -notlike 'ResourceGroups')
						{ "    {0,-60}  : {1,9:f2}" -f $key, $Sub.$ht.$key | Out-File $TextOutputPath -Width 200 -Append }
					else
					# For ResourceGroups, we also output the Tags found within the RG
					{
						$ResourceGroup = $Key
						if (($ResourceGroup.Length % 2) -eq 0)
							{ $RGdots = ($ResourceGroup + (' .' * 30)).SubString(0,60) }
						else
							{ $RGdots = ($ResourceGroup + ' ' + (' .' * 30)).SubString(0,60) }
						"    {0,-60}  : {1,9:f2}" -f $RGdots, $Sub.$ht.$key | Out-File $TextOutputPath -Width 200 -Append
						foreach ($key2 in ($Sub.RG_Tags.Keys | Sort-Object))
						{
							# Output sub-keys EXPECT the {unspecified} just to keep the clutter down
							if ($key2.Contains('{unspecified}') -eq $false)
							{
								$KeyParts = @($Key2 -Split ':')
								if ($KeyParts.Count -eq 3)
								{
									if ($KeyParts[0] -like $ResourceGroup)
										{ "        {0,-66}      {1,9:f2}" -f ($KeyParts[1] + ':' + $KeyParts[2]), [Math]::Round($Sub.RG_Tags.$key2,2) | Out-File $TextOutputPath -Width 200 -Append }
								}
								elseif ($key2.ToLower().StartsWith($ResourceGroup.ToLower()))
								{
									write-warning "Malformed RG_Tag{} entry: '$Key2'" 
									"        {0,-66}      {1,9:f2}" -f "ERROR:$key2", $Sub.RG_Tags.$key2 | Out-File $TextOutputPath -Width 200 -Append
								}
							}
						}
					}
				}
				" "	| Out-File $TextOutputPath -Width 200 -Append
				$k++
			}
		}
		
		if ($FullOutputPath)
		{
			# Output a Csv
			# MATRIX -Columns: SubscriptionName, SubId, ResourceGroupName, BillingPeriod, TotalSpend, Cost Center ID, Service Name, Service Owner, [Add'l per Tag]
			#     The [Add'l per Tag] columns are triples: TagName1, TagValue1, TagTotal1,     then  TagName2, TagValue2, Total2,   etc.
			# There is a row for each resource group in every subscription for each billingPeriod.
			# $CSVColumns = 'SubscriptionName,SubscriptionId,BillingPeriod,OfferID,Currency,ResourceGroup,' + ($TagsToMonitor -join ',') ,TagName_$k,TagValue_$k,Total_$k
			
			# Output a row for the subscription itself
			$SubName	= Make-CSVFriendly -Item $Sub.SubscriptionName
			"{0},{1},{2},{3},{4},{5},{6}" -f $SubName, $Sub.SubscriptionID, $Sub.BillingPeriod, $Sub.OfferID, $Sub.Currency, '{all}', $Sub.TotalAzure | Out-File $FullOutputPath -Width 500 -Append
			
			# Output a row for each ResourceGroup
			foreach ($ResourceGroup in ($sub.ResourceGroups.Keys | Sort-Object))
			{
				$RGName		= Make-CSVFriendly -Item $ResourceGroup
				$CSVRow		= "{0},{1},{2},{3},{4},{5},{6}" -f $SubName, $Sub.SubscriptionID, $Sub.BillingPeriod, $Sub.OfferID, $Sub.Currency, $RGName, $sub.ResourceGroups.$ResourceGroup	# $Sub.TotalAzure = total subscription spend
				
				# Append in the Tags attached directly to the resource group. This is done by examining the Kusto Query results.
				# TBD - Add bllanks for now
				$CSVRow		+= ",,,,,,,,,,,,,".SubString(0,$TagsToMonitor.Count)
				
				# Now append the RG_Tags by looping through them
				# Note that we have to SPLIT the key out of its ResourceGroup:TagName:TagValue
				foreach ($key in ($Sub.RG_Tags.Keys | Sort-Object))
				{
					$KeyParts = @($Key -Split ':')
					if ($KeyParts.Count -eq 3)
					{
						if ($KeyParts[0] -like $ResourceGroup)
							{ 
								$RG_TagName = Make-CSVFriendly -Item ($KeyParts[1] + ':' + $KeyParts[2])
								$CSVRow		+=  ",{0},{1}" -f $RG_TagName, $Sub.RG_Tags.$key
								# OLD: $CSVRow		+=  ",{0},{1},{2}" -f $KeyParts[1], $KeyParts[2], $Sub.RG_Tags.$key 
							}
					}
					elseif ($key.ToLower().StartsWith($ResourceGroup.ToLower()))
					{
						write-warning "Malformed RG_Tag{} entry: '$Key'"
						$RG_TagName = Make-CSVFriendly -Item $Key
						$CSVRow		+=  ",{0},{1}" -f "ERROR:$RG_TagName", $Sub.RG_Tags.$key
						# OLD: $CSVRow		+=  ",{0},{1},{2}" -f $key, '-ERROR-', $Sub.RG_Tags.$key
					}
				}
				
				if ($CSVRow.Length -gt 1000)
					{ write-Warning "CSV row exceeded 1000 characters - $($CSVRow.Length) chars" }
				
				$CSVRow | Out-File $FullOutputPath -Width 5000 -Append
			}
		}
	}
}


# +---------------------------------+
# | Wrap Up							|
# +---------------------------------+

$MBfreeNow = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue	# Not available in Runbooks!! ALSO IS SLOW
$MBused = $Global:MBfree - $MBfreeNow
$TimeTaken = (Get-Date) - $StartTime; $TimeTakenTxt = $TimeTaken -f "ss"
write-host -ForegroundColor Cyan "Overall Time Taken: $TimeTakenTxt    ($MBUsed MB used)`n"

write-host -ForegroundColor Yellow "Grand total for the billing period from $($BillingPeriodStart.ToString('yyyy-MM-dd')) through $($BillingPeriodEnd.ToString('yyyy-MM-dd')):"
write-host "    Azure Total (unrounded)  : $GrandTotalAzure"
write-host "    Azure Total (rounded)    : $GrandTotalAzureRounded"
write-host "    Azure Total (truncated)  : $GrandTotalAzureTrunc"
write-host ""

# Return the Results
Return $Subscriptions


# =======================================================================================
if ($false)
{
    # Output files
    $s | fl | out-file -width 200 -filepath "out1.txt"
    foreach ($a in $s)
    {
	    foreach ($h in $hashTables)
	    {
		    "=== $($a.subscriptionID) ====" | out-file -append -filepath "$h.txt" -Width 250 
		    foreach ($x in $a.$h)
		    {
			    $x | fl | out-file -append -filepath "$h.txt" -Width 250
		    }
	    }
    }


    # As JSON
    foreach ($a in $s)
    {
	    $a | ConvertTo-json -Depth 5 | Out-File -filepath "Results.json" -Append -Width 500
	    "`n`n" | Out-File -filepath "Results.json" -Append
    }
}
