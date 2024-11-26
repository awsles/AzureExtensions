#Requires -Version 5.1
<#
.SYNOPSIS
	Get-AxEAUsageDetail - Download the Azure Enterprise Agreement (EA) Billing Data Detail as a CSV.
.DESCRIPTION
	This cmdlet queues a request to generate a CSV. Depending on the size, the process can take
	more than 10 minutes to complete. Once complete, the CSV is downloaded to the specified path.
	
	If no path is specified, then a name is generated.

.PARAMETER Path
	Specifies the path and name of the CSV file to create.
	Default is EANUMBER_Usage_YYYYMM.csv or EANUMBER_Usage_YYYY-MMDD_YYYY-MM-DD.csv
.PARAMETER billingMonth
	Indicates the month and year to return data for in the form YYYYMM (e.g., "201707" is July 2017).
	If specified, then StartDate and EndDate are ignored.
.PARAMETER StartDate
	Indicates the start date in YYYY-MM-DD format.
.PARAMETER EndDate
	Indicates the start date in YYYY-MM-DD format..

.NOTES
	Author: Lester Waters
	Version: v0.03
	Date: 17-May-20
	
	TEST:
	CD c:\git\lesterw1\CloudBilling\Azure
    .\Get-AxEAUsageDetail -Verbose
	
	
.LINK
	https://portal.azure.com/#blade/Microsoft_Azure_CostManagement/Menu/exports  billingdata1ca52b11485a
#>


# +=================================================================================================+
# |  PARAMETERS																						|
# +=================================================================================================+
[cmdletbinding()]   #  Add -Verbose support; use: [cmdletbinding(SupportsShouldProcess=$True)] to add WhatIf support
Param
(
	[Parameter(Mandatory=$false)]  [string]  $Path,											# No trailing slash!
	[Parameter(Mandatory=$false,HelpMessage="Enter as YYYYMM format (e.g., '201908')")]
	[ValidateLength(6,6)] 		  [string]  $billingMonth,									# YYYYMM
	[Parameter(Mandatory=$false,HelpMessage="Enter as YYYY-MM-DD format (e.g., '2019-08-01')")]
	[ValidateLength(10,10)] [string]  $StartDate,											# YYYY-MM-DD
	[Parameter(Mandatory=$false,HelpMessage="Enter as YYYY-MM-DD format (e.g., '2019-08-30')")]
	[ValidateLength(10,10)] [string]  $EndDate,												# YYYY-MM-DD
	[Parameter(Mandatory=$false)] [string]  $OutputPath 	= "C:\Scripts\BillingData",		# No trailing slash!
	[Parameter(Mandatory=$false)] [switch]  $SaveToCSV		= $false						# If true, then a CSV is created
)

# +=================================================================================================+
# |  MODULES																						|
# +=================================================================================================+
Import-Module Az.KeyVault
Import-Module Az.Resources


# +=================================================================================================+
# |  CUSTOMIZATIONS     (customize these values for your subscription and needs)					|
# +=================================================================================================+
$TenantId 			= "xxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"	# DOMAIN.onmicrosoft.com
$EnrollmentId			= "12345678"				# EA Enrollment number

# Azure Key Vault containing the EA API key
$kvName 			= "kv-apikeys"				# EA API Keys are stored as secrets here
$kvEASecretName			= "EAKey-$EnrollmentId"			# Name of the Secret (based on Enrollment ID)
$kvSubscriptionId		= "SAMPLES-ee1a66ffe5dd"		# Subscription which contains the Key Vaults

# File Locations
$TempFolder 			= $env:TEMP				# TEMP folder

# EA Access Key (If specified below, then the key is NOT retrieved from the key vault -- Use for DEBUG only!!)
$EnrollmentApiKey		= ""


# +=================================================================================================+
# |  CONSTANTS     																					|
# +=================================================================================================+
# Miscellaneous
$TextHTML				= @{"ContentType" = "text/html"}	# MIME Type for HTML
$TextCSV				= @{"ContentType" = "text/csv"}		# MIME Type for CSV
$crlf 					= [char]13 + [char]10


# +=================================================================================================+
# |  PARAMETER / INPUT VERIFICATION																	|
# +=================================================================================================+
# Check that the billingMonth is correct
if ($billingMonth.Length -eq 6)
{
	Try
		{ $billingDate = [datetime] (new-object System.DateTime $billingMonth.Substring(0,4), $billingMonth.Substring(4,2), 1) }  # Indicate 1st of month
	Catch
	{
		write-error "  BillingMonth must be 6 characters in the form YYYYMM for Year and Month, respectively."
		return $null
	}
	$reportMonth = $billingMonth
	write-host -ForegroundColor Yellow "Billing Month: $reportMonth"
}
elseif ($billingMonth.Length -gt 0)
{
	write-error "  BillingMonth must be 6 characters in the form YYYYMM for Year and Month, respectively."
	return $null
}
elseif ($billingMonth.Length -eq 0 -And !$StartDate -And !$EndDate)
{
	$billingMonth = (get-date -format "yyyyMM")		# Assume THIS month
	Write-Host -ForegroundColor Yellow "Retrieving billing data for the current month..."
}

elseif ($StartDate -And !$EndDate)
{
	$EndDate = (Get-Date).ToString('yyyy-MM-dd')		# Assume End date of today
}
elseif (!$StartDate -And $EndDate)
{
	$StartDate = $EndDate								# StartDate = EndDate (1 day of data)
}

if (($StartDate -Or $EndDate) -And ($StartDate.Length -ne 10 -Or $EndDate.Length -ne 10))
{
	write-error "  StartDate and EndDate must be 10 characters in the form YYYY-MM-DD for Year, Month, and Day, respectively."
	return $null
}

# +=================================================================================================+
# |  CLASSES																						|
# +=================================================================================================+
Class AxEAUsageDetail
{
	[int]	 $Status		# HTTP Result Code (200=success)
	[string] $BillingMonth		# 'YYYYMM' (if specified)
	[string] $StartDate		# Starting Date (if specified as YYYY-MM-DD)
	[string] $EndDate		# Ending Date (if specified as YYYY-MM-DD)
	[string] $EABlob		# Interim EA Blob URI
	[string] $CSVPath		# Full path and name for local CSV output file
	[string] $BlobPath		# Full path for saved Azure blob (future feature)
}

# +=================================================================================================+
# |  FUNCTIONS																						|
# +=================================================================================================+


# +=================================================================================================+
# +=================================================================================================+
# |  MAIN																							|
# +=================================================================================================+
# +=================================================================================================+
$StartTime = Get-Date


#
# Get Current directory (PowerShell scripts seem to default to the Windows System32 folder)
#
$invocation = (Get-Variable MyInvocation).Value
$directorypath = Split-Path $invocation.MyCommand.Path
# $directorypath = Convert-path "."   # Use the path we launched in (vs. the path of the script)
[IO.Directory]::SetCurrentDirectory($directorypath)   # Set our current directory

#
# Set up for Result Set
# 
$MyResult = New-Object AxEAUsageDetail
$MyResult.BillingMonth	= $BillingMonth
$MyResult.StartDate		= $StartDate
$MyResult.EndDate		= $EndDate


# +-------------------------------------------------------------------------+
# |  Retrieve the EA API Key from the key vault (if necessary)				|
# |	 The current user must have permission to access the vault and 			|
# |  retreive the secret.													|
# +-------------------------------------------------------------------------+
if (!$EnrollmentApiKey.Length)
{
	# Retrieve API key from Azure vault...
	write-verbose "Retrieving EA API Key from Key Vault '$kvName'"
	Try
	{
		$keyVault	= Get-AzKeyVault -VaultName $kvName -ErrorVariable err1 -ErrorAction Stop
		$secret 	= Get-AzKeyVaultSecret -VaultName $kvName -Name $kvEASecretName -ErrorVariable err1 -ErrorAction Stop 
	}
	Catch [System.ArgumentException]
	{
		Write-Error " ERROR: Unable to access vault '$kvName' -- $err1"
		return
	}
	
	# Extract the Enrollment API Key
	$EnrollmentApiKey = $secret.SecretValueText	
}


# +-------------------------------------------------------------------------+
# |  Retrieve Detailed Usage												|
# +-------------------------------------------------------------------------+

### $option = 7 : Detailed Usage as a native CSV  (https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail )
# $ReqURLs			+= "https://consumption.azure.com/v3/enrollments/$EnrollmentId/usagedetails/download?billingperiod=%%"
	

### $option = 8 : Detailed Usage as async CSV  (https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail )
$title			= "EA Detailed Usage Detail"
$reqHeader 		= @{"authorization"="bearer $EnrollmentApiKey"}
if ($BillingMonth.Length -eq 6)
{
	$ReqURL		= "https://consumption.azure.com/v3/enrollments/$EnrollmentId/usagedetails/submit?billingPeriod=$billingMonth"
	$CSVPath	= $EnrollmentID + "_AzureUsage_$billingMonth.csv" 
}
else
{
	$ReqURL	= "https://consumption.azure.com/v3/enrollments/$EnrollmentId/usagedetails/submit?startTime=$StartDate&endTime=$EndDate"
	$CSVPath	= $EnrollmentID + "_AzureUsage_$StartDate" + "_$EndDate-Detail.csv"
}

# Save the path to the Result
if ($Path.Contains('\'))
	{ $MyResult.CSVPath = $Path }
else
	{ $MyResult.CSVPath = [IO.Directory]::GetCurrentDirectory() + "\$CSVPath" }
	

# Download the CSV (either directly or asynchronously depending on $ReqURL)
write-host -ForegroundColor Cyan -NoNewLine "Retrieving $title... "
if (!$ReqURL.Contains('submit?'))
{
	# +-----------------------------------------+
	# | Download detailed usage as a native CSV	|
	# +-----------------------------------------+
	Try {
		$webResult = Invoke-WebRequest $reqURL -Headers $reqHeader -ContentType 'application/csv' -OutFile $CSVPath -ErrorVariable Err1   # 'text/csv'
		$MyResult.Status = 200
	}
	Catch
	{
		write-warning "Error $($Err1.Message) retrieving CSV"
		$MyResult.Status = -1
	}
}
else
{
	# +-----------------------------------------+
	# | Poll for result							|
	# +-----------------------------------------+
	$webResult = Invoke-WebRequest $reqURL -Method 'POST' -Headers $reqHeader  # -ContentType 'application/csv' -OutFile $CSVPath   #   "text/csv"
	$PollURL = $null
	$LastState = 0

	# Now poll for result
	# https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail
	# $SubmitStatus.Status: Queued = 1, InProgress = 2, Completed = 3, Failed = 4, NoDataFound = 5, ReadyToDownload=6, TimedOut = 7
	$Statuses = @('Unknown', 'QUEUED', 'In_Progress', 'Completed', 'Failed', 'NoDataFound!', 'ReadyToDownload', 'TimedOut')
	while ($webResult.StatusCode -eq 200 -Or $webResult.StatusCode -eq 202)
	{
		$SubmitStatus = ($webResult.Content | ConvertFrom-Json)
		if (!$PollURL)
			{ $PollURL = $SubmitStatus.reportUrl }
		# Output state changes
		if ($LastState -ne $SubmitStatus.Status)
		{
			write-host -NoNewLine " $($Statuses[$SubmitStatus.Status]) ($($SubmitStatus.Status)) "
			$LastState = $SubmitStatus.Status
			# write-host -foregroundColor Gray $webResult.Content		# DEBUG
		}
		if ($SubmitStatus.Status -lt 3)
		{
			# We are waiting... so Sleep 60 seconds
			write-host -NoNewLine '.'
			Start-Sleep -Seconds 60
			$webResult = Invoke-WebRequest $PollURL -Method 'GET' -Headers $reqHeader 	# Poll for result
		}
		elseif ($SubmitStatus.Status -eq 3 -Or $SubmitStatus.Status -eq 6)
		{
			$TimeTaken = (Get-Date) - $StartTime; $TimeTakenTxt = $TimeTaken -f "ss"
			write-host -ForegroundColor Yellow "`nProcessing time taken: $TimeTakenTxt"
			# We are Done... file is ready for downloading so go get it
			$ReqURL2 = $SubmitStatus.blobPath
			$MyResult.EABlob = $ReqURL2
			if ($ReqURL2)
			{
				write-host "BLOB URL: $ReqURL2"
				Try {
					write-verbose "Downloading: $CSVPath"
					$webResult2 = Invoke-WebRequest $reqURL2  -ContentType 'application/csv' -OutFile $CSVPath -ErrorVariable Err1  # -Headers $reqHeader
					$MyResult.Status = 200
				}
				Catch {
					write-warning "Error $($Err1.Message) retrieving blob '$reqURL2'"
					$MyResult.Status = -2
				}
				break
			}
			else
			{
				write-host -ForegroundColor Gray "CSV Generated completed - waiting for download path..."
			}
		}
		elseif ($SubmitStatus.Status -eq 4)
		{
			write-warning "Request Failed: Submit Status is $($SubmitStatus.Status)"
			$SubmitStatus | fl	# DEBUG
			break
		}
		elseif ($SubmitStatus.Status -eq 5)
		{
			write-warning "No Data Found for the specified period"
			$SubmitStatus | fl	# DEBUG
			break
		}
		elseif ($SubmitStatus.Status -eq 7)
		{
			write-warning "TimeOut Error returned"
			$SubmitStatus | fl	# DEBUG
			break
		}
		else
		{
			# SubmitStatus > 7, so something went wrong
			write-warning "Request Failed: Submit Status is $($SubmitStatus.Status)"
			$SubmitStatus | fl	# DEBUG
			break
		}
	}

	if ($webResult.StatusCode -ne 200)
	{
		write-warning "Queue request returned HTTP result $($webResult.StatusCode)"
		($webResult.Content | ConvertFrom-Json) | fl
	}
}


# Wrap-Up
$TimeTaken = (Get-Date) - $StartTime; $TimeTakenTxt = $TimeTaken -f "ss"
write-host -ForegroundColor Yellow "Overall Time Taken: $TimeTakenTxt"

Return $MyResult

