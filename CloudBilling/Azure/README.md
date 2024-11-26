# AzureBillingData
These PowerShell scripts are used to retreive the billing information from the Azure Enterprise Agreement (EA) API.
This will cover all subscriptions which are managed and billed under the EA but does not (at this time)
cover any subscriptions which are in a tenant but are NOT under the EA. 


## Enterprise Agreement (EA) Billing Data
The EA API returns detailed information about Azure consumption and Azure Marketplace usage which is
billed (and discounted) under the EA agreement. Each EA has its own price sheet which can be retrieved for
each month of the EA agreement period.

The EA API key is stored in an Azure Key vault which is coded into the Get-AzureBillingData.ps1 script.
The user context in which the script runs must have access to read the secret in the key vault.
The user context should also have access to the consumption APIs for all subscriptions.
This will allow the script to automatically identify those subscriptions which are not under the EA
(by looking at the EA billing data and comparing it with all of the subscriptions visible to the script).

## Non-EA Subscriptions
In order to cover non-EA subscriptions, it is necessary to connect to each subscription and retrieve the
relevant billing data, one subscription at a time using the Azure Consumption APIs.
The applicable price sheet is also retreieved via the consumption API for each respective subscription.

## Azure MeterIDs and Categories
Over time, Microsoft sometimes makes adjustments to MeterCategory names which can impact the summation 
by MeterCategory from month to month. Microsoft usually publishes these changes.
The script does NOT track such changes.

Similarly, the MeterIDs used for billing can change over time, either by being replaced, or
by a transition from the promotional rate to a standard rate for a service.

## Reserved Instances
Reserved Instances appear in the Azure EA billing data at the time when the reservation is made
for the reserved instances. This will be a spike in the usage bill for that month.
Thereafter, virtual machines which are eligible for a reserved instance rate will be billed at zero cost
for the duration of the day in which each virtual machine is eligible.  This means that a given VM may
have several billing lines each day, at different rates.

## Summations
As the billing data is generated for each resource on a daily basis, there can be tens to hundreds of thousands of records
for just a single day.  Each daily database entry is tagged with the billing month in the form "YYYYMM".

Most individuals are not interested in specific daily consumption. Rather, the interests are usually the consumption per month,
the associated trends, and the breakdowns as follows:

	- TotalAzure 		- The total Azure spend for the subscription
	- TotalMarketplace	- Total Marketplace spend for the subscription (always zero here)
	- MeterCategories	- Total spend for each Azure service category
	- ResourceGroups	- Total spend for each respective resource group
	- Tags				- Total spend by the tags "Cost Center ID" and "Service Name"
	- Locations			- Total spend by each Azure location
	- CostCenters		- Total spend by cost center AS LISTED IN EA PORTAL
	- DepartmentNames	- Total spend by each department name AS LISTED IN EA PORTAL

 Additionally:
 
	- Key				- SubscriptionID_20200401   (indicates start of billing period)
	- BillingDate		- Indicates the date for first entry seen for the subscription
	- BillingMonth		- Not implemented yet (YYYYMM)

**IMPORTANT NOTE:** The "Commitment Usage" Summary totals shown in the Azure EA portal WILL NOT match
the total when adding up the detailed billing data. This is because of the way Microsoft calculates
those totals, which include factors such as Reserved and Spot Instance usage and other factors.
If you view charges by heirarchy in the Azure EA portal, the numbers DO add up, subject to some
differences in rounding (a few pennies). With some trial and error, the rounding could be eliminated.
It depends where Azure rounds its numbers for billing (i.e., by service, by day, etc.).

### Cost Categories
Companies commonly have multiple perspectives by which they want to view costs, such as projects, cost centers, and
applications - with each perspetive being used for a different purpose. For example, departmental cross-charging
might be based on cost centers, but it is also often useful to see how much a project or application is costing.
AWS has Cost Category support which allows viewing of costs in multiple, corresponding perspectives. 
For Azure, this can be accomplished with proper resource tagging and controlled at the resource group level
(i.e., a resource group belongs to only one project or application, and cost center).

# Data Formats
The CSV data formats differ between the data provided by the Enterprise Agreement (EA) APIs andthat which
can be automatically exported via the Azure portal.

## Detailed Billing Data
The table below summarizes the columns for the detailed billing data:

| EA v3 Format | Standard Export Format | Description |
| --- | --- | --- |
|AccountId||A numerical account number which has no real significance.|
|AccountName|AccountName|This is the name assocated with the account owner.|
|AccountOwnerEmail|AccountOwnerId|This is the account owner email.|
|AdditionalInfo|AdditionalInfo|Usually blank|
||AvailabilityZone||
|ChargesBilledSeparately||A boolean flag to indicate if any charges are billed separately.|
|ConsumedQuantity|UsageQuantity|Quanity of the resource consumed.|
|ConsumedService|ConsumedService|Name of the service.|
|ConsumedServiceId||Consumed Service ID Index (EA internal)|
|Cost|PreTaxCost|Total charges (un-rounded)|
|CostCenter|CostCenter|Cost center, as configured in the EA portal.|
||Currency|Currency (e.g., 'GBP', 'USD')|
|Date|UsageDateTime|Usage day|
|DepartmentId||Department ID (internal to EA portal)|
|DepartmentName|DepartmentName|Department Name (as assigned in EA portal)|
|InstanceId|InstanceId|Azure ResourceID|
|Location||Azure Location|
|MeterCategory|MeterCategory|Meter Category|
|MeterId|MeterId|Meter ID|
|MeterName|MeterName|Meter Name|
|MeterRegion|MeterRegion|Meter Region|
|MeterSubCategory|MeterSubcategory|Meter Subcategory|
|OfferId|OfferId|Azure Durable Offer ID (MS-AZR-0017P is EA)|
|PartNumber||Azure Part Number (as it appears in the EA price sheet)|
|Product|ProductName|Product Name|
|ProductId||Internal Product ID|
|ResourceGroup|ResourceGroup|Resource Group Name|
|ResourceGuid||Internal GUID for the resource instance|
|ResourceLocation|ResourceLocation|Location|
|ResourceLocationId||Location ID index (EA internal)|
|ResourceRate|ResourceRate|The billing rate for the resource|
||ResourceType|Resource Type|
|ServiceAdministratorId||Service Administrator ID (often blank)|
|ServiceInfo1|ServiceInfo1|Additional information returned for some billing items|
|ServiceInfo2|ServiceInfo2|Additional information returned for some billing items|
|ServiceName||Service Name|
|ServiceTier||Service Tier (aspect of the service)|
|StoreServiceIdentifier||Unknown|
|SubscriptionGuid|SubscriptionGuid|Azure Subscription ID|
|SubscriptionId||EA Subscription ID|
|SubscriptionName|SubscriptionName|Subscription Name|
|Tags|Tags|Tags|
|UnitOfMeasure|UnitOfMeasure|Billing unit of measure|

The order of the columns in the respective CSVs may vary. 

### Meter IDs and Names
A *MeterID* identifies the specific "thing" that is being metered and billed. For every resource,
there may be one or multiple meter IDs.  For example, one meter may record bandwidth consumption,
while a related meter may record storage consumption. Typically, there is a unique meter ID for
each resource, location, and pricing type/tier. For example, "preview" pricing will have a different meter ID
from standard pricing.

Meter IDs can also change over time. Typically (but not always), Microsoft publishes this information
to EA customers, noting the specific changes.  Meter names may also change.

### Part Number
The EA price sheet returns pricing information based on a SKU part number. Prior to v3 EA API, there was
no mapping readily available between meterID and PartNumber -- you had to request it via Microsoft support.


## Marketplace Billing Data
The Azure Marketplace spend is returned separately from the primary Azure billing data and therefore has its own data format.
Unlike the detailed usage, the marketplace spend is only available via REST API which returns JSON entries for the spend.
The marketplace data typically has far fewer entries than the Azure detailed usage data.


TBD

## Enterprise Agreement (EA) Format
A sample of the EA v3 data format is provided as **SampleEAData.csv.txt**, which was created using the Azure EA REST API
to create a downloadable CSV:
https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail.

When imported using ```get-content "SampleEAData_v3.csv.txt" | select-object -skip 2 | Out-file 'data.tmp' ; $y = Import-csv 'data.tmp' ; del 'data.tmp'"```
(which creates a temporary file as the EA data has an extrac header), an entry appears as follows:

```
AccountId               : 242515
AccountName             : Project Development
AccountOwnerEmail       : owner@contoso.com
AdditionalInfo          : 
ConsumedQuantity        : 0.0146
ConsumedService         : Microsoft.Storage
ConsumedServiceId       : 68
Cost                    : 0.000003157877342
CostCenter              : IT2036F001
Date                    : 2020-05-01
DepartmentId            : 107121
DepartmentName          : Contoso
InstanceId              : /subscriptions/00000000-8bf7-4e6e-baed-000000000000/resourceGroups/APPLE-RG/providers/Microsoft.Storage/storageAccounts/APPLErgdiag
MeterCategory           : Storage
MeterId                 : 12345678-a0b3-4a2c-9b8b-000000000000
MeterName               : Batch Write Operations
MeterRegion             : 
MeterSubCategory        : Tables
Product                 : Tables - Batch Write Operations
ProductId               : 1007784
ResourceGroup           : APPLE-RG
ResourceLocation        : EastUS
ResourceLocationId      : 2
ResourceRate            : 0.000216292968653
ServiceAdministratorId  : 
ServiceInfo1            : 
ServiceInfo2            : 
StoreServiceIdentifier  : 
SubscriptionGuid        : 00000000-8bf7-4e6e-baed-000000000000
SubscriptionId          : 0
SubscriptionName        : mystorageaccount
Tags                    : {  "APPLE": "27"}
UnitOfMeasure           : 100000000
PartNumber              : N9H-00758
ResourceGuid            : 00000000-a0b3-4a2c-9b8b-000000000000
OfferId                 : MS-AZR-0017P
ChargesBilledSeparately : False
Location                : US East
ServiceName             : Storage
ServiceTier             : Tables
```


## Non-EA Subscriptions
A sample of the v3 data format is provided as **SampleData.csv.txt**, which was created using the Azure
Cost Management Export at: https://portal.azure.com/#blade/Microsoft_Azure_CostManagement/Menu/exports
When imported using ```Import-CSV "SampleData.csv.txt" ```, an entry appears as follows:

```
DepartmentName   : Contoso
AccountName      : Contoso Development
AccountOwnerId   : owner@contoso.com
SubscriptionGuid : 00000000-8bf7-4e6e-baed-000000000000
SubscriptionName : iotahoedevtest
ResourceGroup    : rg-CentricaTestData
ResourceLocation : UK South
AvailabilityZone : 
UsageDateTime    : 2020-05-13
ProductName      : Tiered Block Blob - Hot LRS - Write Operations - UK South
MeterCategory    : Storage
MeterSubcategory : Tiered Block Blob
MeterId          : 12345678-60dc-418f-9b98-000000000000
MeterName        : Hot LRS Write Operations
MeterRegion      : UK South
UnitOfMeasure    : 1000000
UsageQuantity    : 0.0095
ResourceRate     : 0.035899715826798
PreTaxCost       : 0.000341047300355
CostCenter       : IT2036F001
ConsumedService  : Microsoft.Storage
ResourceType     : Microsoft.Storage/storageAccounts
InstanceId       : /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-TestData/providers/Microsoft.Storage/storageAccounts/myteststorage
Tags             : 
OfferId          : MS-AZR-0017P
AdditionalInfo   : 
ServiceInfo1     : 
ServiceInfo2     : 
Currency         : GBP
```


# Cmdlets
The following cmdlets are provided:

## Create-AxBillingSummary.ps1
This script generates an output consisting of multiple JSON structures, one for each subscription.

The summation for Tags only sums those resources which, on each billing day, have the associated tag.
If a resource is tagged with both a "Cost Center ID" and "Service Name", the spend will be summed
up in *both* respective tags totals. Note also that there are MANY items which may not be tagged at all.

 
---
# Additional Resources
For the Enterprise Agreement (EA) consumption:

- **EA PriceSheet** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-pricesheet
- **Detailed Usage** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail
- **Marketplace Usage** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-marketplace-storecharge
- **Billing Summary** (as reported in EA portal) - Via the REST API: "https://consumption.azure.com/v2/enrollments/$EnrollmentId/billingPeriods/$billingMonth/balancesummary"
- **Billing Periods** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-billing-periods
- **Shared Reserved Instance Recommendations** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-reserved-instance-recommendation
- **Single Reserved Instance Recommendations** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-reserved-instance-recommendation
- **Detailed Usage as a native CSV**  - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail
- **Detailed Usage as async CSV** - https://docs.microsoft.com/en-us/rest/api/billing/enterprise/billing-enterprise-api-usage-detail
- **Azure Reserved Instance Pricelist** - Provided as a CSV in a storage account (updated monthly) which can be found at: https://automaticbillingspec.blob.core.windows.net/spec/Azure%20Reserved%20VM%20Instance%20Pricelist.csv
- **Billing Periods Report** - Via the REST API: "https://consumption.azure.com/v2/enrollments/$EnrollmentId/billingperiods"


