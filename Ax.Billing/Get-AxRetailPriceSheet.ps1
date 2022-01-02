#Requires -Version 5
<#
.SYNOPSIS
	Get-AxRetailPriceSheet -- Returns the retail price sheet as JSON
	
.DESCRIPTION
	This cmdlet enumerates the Azure retail price API and generates a price sheet.
	
	
.NOTES
	Author: Lester Waters
	Version: v0.01
	Date: 13-Jul-21
	
	API returns 100 items with .NextPageLink. If $top and $skip are used, .NextPageLink is NULL.
	Even using $top, only a maximum of 100 items are returned.
	
.LINK
	https://docs.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
	https://github.com/MicrosoftDocs/azure-docs/issues/41082
#>

$uri = 'https://prices.azure.com/api/retail/prices'  # optionally add "?currencyCode='USD'"
$Headers = @{}
$Items = @()
$Count = 0
$estTotal = 327900		# estimated total
Do
{
	$pct = [math]::min([Math]::Truncate($Count / $estTotal * 100), 99)
	write-progress -Activity "Reading Azure Retail Price Sheet" -Status "$($Count + 1) to $($Count + 100)" -Id 1 -PercentComplete $pct
	$r = Invoke-WebRequest -Method 'Get' -uri $uri -Header $Headers -UseBasicParsing # -Verbose
	$c = $r.Content | ConvertFrom-Json
	$Items += $c.Items
	$Count += $c.Count
	$uri = $c.NextPageLink
} While ($c.NextPageLink)
write-progress -Activity "Reading Azure Retail Price Sheet" -Status "Done" -Id 1 -PercentComplete 100 -Completed

# $items() now has the JSON, Export to CSV
$Items | Export-CSV -Path ("$(get-date -format "Retail_yyyy_MM")" +'.csv') -Force 

Return $Items

