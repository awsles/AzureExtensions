# Ax.Cosmos
The Ax.Cosmos module is provided as an interim PowerShell solution
for Azure Cosmos in the absence of a Microsoft-provided solution.
With this module, you can:

* Create and delete Cosmos accounts
* Create and delete Cosmos databases
* Create and delete Cosmos collections (containers)
* Create and update (upsert) Cosmos documents

The Ax.Cosmos module requires that a *context* be created in order to work with
databases and collections. The context contains the access key, the currently selected
collection / container name, and the partition key name associated with the collection.
The **New-AxCosmosContext** cmdlet is used to create a new context.
When creating a new Cosmos account with **New-AxCosmosAccount**, a context will also be return
but it will be necessary to then create a database and container before Cosmos documents can be added.
Use **Select-AxCosmosDatabaseCollection** to switch between collections (contgainers) within the selected database.

The **New-AxCosmosAccount** and **New-AxCosmosDatabase** cmdlets can take up to 10 minutes to complete.
All cmdlets are synchronous in this module version (so you just have to wait for the cmdlet to complete). Given the length of
time, these cmdlets will output a warning (which can be supressed with the -WarningAction switch) about the time it will take.
The -Verbose switch can be used to display the actual time taken.

## Cmdlets
This module provides the following commands

| Cmdlet | Description |
| --- | --- |
| Get-AxCosmosDatabase | Retrieve information for one or more databases in the Cosmos account. |
| Get-AxCosmosDatabaseCollection | Retrieve one or more collections (containers) in the specified Cosmos database. |
| Get-AxCosmosDocument | Query for a Cosmos document object in the specified database (and optionally within a collection). |
| New-AxCosmosAccount | Create a new Cosmos account. |
| New-AxCosmosContext | Create a new AxCosmosContext. |
| New-AxCosmosDatabase | Create a new Cosmos database. |
| New-AxCosmosDatabaseCollection | Create a new collection (container) within a Cosmos database. |
| New-AxCosmosDocument | Create a new document (object) within a Cosmos collection. |
| New-AxCosmoBulkDocuments | Creates multiple documents (objects) within a Cosmos collection. |
| Remove-AxCosmosAccount | Delete a Cosmos account and all databases within. |
| Remove-AxCosmosDatabase | Delete a Cosmos database instance. |
| Remove-AxCosmosDatabaseCollection | Delete a collection (container) within a Cosmos database. |
| Remove-AxCosmosDocument | Delete an existing Cosmos document by id. |
| Select-AxCosmosDatabaseCollection | Select the Cosmos database and collection (container) to use. |

### Documentation
The cmdlets are documented in the [https://github.com/lesterw1/AzureExtensions/blob/master/Ax.Cosmos/Ax.Cosmos.md](Ax.Cosmos.md) page in this repository.


## Getting Started
The following steps will help you get started:

1) Install the Ax.Cosmos module.
This is done by first determining where modules are installed. Start PowerShell and run the command:
```
$Env:PSModulePath
```
This will result in several paths.
Use the first path if you want the module to be available for a specific user.
Use the second path to make the module available for all users.

Next, copy or download the **Ax.Cosmos** into the new path.


2) Import the Ax.Cosmos module.

```
Import-Module Ax.Cosmos
```

3) The first step is to create a Cosmos account. This can be done with the **New-AxCosmosAccount** cmdlet.
The process takes 5 to 10 minutes to complete. 

```powershell
New-AzResourceGroup -Name 'rg-cosmos' -Location 'westeurope'
$c = New-AxCosmosAccount -AccountName 'contoso' -ResourceGroupName 'rg-cosmos' -Location 'westeurope' -Verbose -Force
```
The **New-AxCosmosAccount** returns a AxCosmosAccountContext object which must be used for subsequent access to the account.

4)  The next step is to create a database using the context $c from above:

```powershell
New-AxCosmosDatabase -Context $c -DatabaseName 'MyDatabase' -Force -Verbose
```

The above creates a new database named 'MyDatabase'. The process takes 1 to 2 minutes.

5) Next, create a collection (container) named 'MyCollection' within the database.
Note that it is necessary to specify the DatabaseName in this cmdlet.

```powershell
New-AxCosmosDatabaseCollection -Context $c -DatabaseName 'MyDatabase' -CollectionName 'MyCollection' -PartitionKeyName 'Country' -Force -Verbose
```

The above creates a new database named 'MyDatabase'. The context $c is updated with the selected database, collection, and
partition key names so that subsequent use of the context will default accordingly.

6) Now that a database and a collection has been created, we can insert a document:

```powershell
$MyObject = '{ "id": "100",  "Name": "John Doe",   "City": "London",  "Country": "United Kingdom" }' | ConvertFrom-Json
New-AxCosmosDocument -Context $c -Object $MyObject -Upsert -Verbose
```

There are _two_ REQUIRED properties in *every* object that is inserted into this container: (1) the 'id' property whose
name MUST be lower case (e.g., 'id'); AND the property associated with the container's partition key must also be present
and must exactly match case (e.g., for the above example, we used 'Country' so that property name must match exactly; e.g., 'country'
is not acceptable).

The -Upsert switch can be used to replace the document object if it already exists (i.e., has the same 'id' value).
Note that Cosmos does not support partial document updates, so the entire document must be rewritten each time
any change is required.

7) Next, we can query for this object using the 'id' property:

```powershell
Get-AxCosmosDocument -Context $c -idValue '100'
```

This will return the object that we created in step 5, which will also
have some additional properties attached as shown below:

```
id           : 100
Name         : John Doe
City         : London
Country      : United Kingdom
_rid         : jhVrAKo4XREBAAAAAAAAAA==
_self        : dbs/jhVrAA==/colls/jhVrAKo4XRE=/docs/jhVrAKo4XREBAAAAAAAAAA==/
_etag        : "0000d72a-0000-0d00-0000-5e64cde80000"
_attachments : attachments/
_ts          : 1583664616
```

Querying for Cosmos documents (objects) using other properties is possible, but requires a more advanced structure
to be passed in.  

8) Lastly, we can remove the Cosmos document using the id:

```powershell
Remove-AxCosmosDocument -Context $c -idValue '100'
```


### AxCosmosContext Object
The Ax.Cosmos module requires that a *context* be created in order to work with
databases and collections. The **AxCosmosContext** object, used to hold this context,
contains the access key, the currently selected collection / container name, and the
partition key name associated with the collection.

For example:
```
accountName       : contoso
resourceGroupName : rg-cosmos
subscriptionId    : 00000000-0000-0000-0000-000000000000
location          : 
databaseName      : MyDatabase
collectionName    : MyCollection
partitionKeyName  : Country
AzDabatasePath    : contoso/sql/MyDatabase
AzContainerPath   : contoso/sql/MyDatabase/MyCollection
keyType           : master
tokenVersion      : 1.0
hmacSHA256        : System.Security.Cryptography.HMACSHA256
endPoint          : https://contoso.documents.azure.com
collectionURI     : https://contoso.documents.azure.com/dbs/MyDatabase/colls/MyCollection
ApiVersion        : 2018-06-18
```

The hmacSHA256 property contains the object which is used to digitally sign the underlyig Cosmos REST APIs.
Note that the location property is not filled in as the underlying API does not yet return it.


## Performance
Achieving decent performance is challenging. Event with 20,000 RUs configured, adding/upserting documents is dead slow.
I attempted to improve this by spawning jobs for calling the Cosmos REST API via Invoke-WebRequest, but even this ran
into its own issues. Some observations:

* The Cosmos REST API only allows a single document to be synchronously added at a time. 
There doesn't appear to be any API to allow multiple documents to be created at once.
The .NET team has created a bulk executor library for Cosmos: https://docs.microsoft.com/en-us/azure/cosmos-db/bulk-executor-overview
but this 1st cut of the module is itself in powershell so cannot yet take advantage. 

* The **Invoke-RestMethod** cmdlet has an unexplainable lag, as if the requests are being serialized.

Bottom line: If you have a lot of data to insert/update, you may need to develop your own solution.
But if you happy with some lightweight use, this library is acceptable.

## Next Steps
In no particular order:

* Ensure all the functions have headers. The documentation is generated from these headers.

* Add the individual help headers for each cmdlet function so that **Get-Help** may  be used to retrieve the documentation for each.

* Implement Remove-AxCosmosDocument using query parameters (vs just by id).

* Provide support for various Cosmos account sizes, replication settings, etc.
The current implementation is hard-coded for a small size.

* Implement support for Get-AxCosmosDocument with complex queries.

* Improve error handling.

* Eliminate need for .Key property in AxCosmosContext.
This involves changing the code to use the hmacSHA256 instance. 

* Improve the Query-AxCosmosDocuments cmdlet.
The cmdlet is fairly narrow and tedious to use.
Provide a "simple" mode along side the more complex query mode.

* Provide examples within each cmdlet in the .Example comment section.

* Fill in *location* property in AxCosmosContext Object. 
This is a known issue in that the underlying API does not return the location for some unknown reason.

### Implementation Notes
This module is itself implemented in PowerShell using a combination of the Azure **AzResource**
cmdlets (Get-AzResource, New-AzResource, Remove-AzResource) and by calling Cosmos REST APIs directly. 
It is intended for casual use of Cosmos databases and would benefit from being implemented in C#.NET.

