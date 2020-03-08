# Ax.CosmosDb
The Ax.CosmosDb module is provided as an interim PowerShell solution
for Azure Cosmos in the absence of a Microsoft-provided solution.
With this module, you can:

* Create and delete Cosmos accounts
* Create and delete Cosmos databases
* Create and delete Cosmos collections (containers)
* Create and update (upsert) Cosmos documents

The Ax.CosmosDb module requires that a *context* be created in order to work with
databases and collections. The context contains the access key, the currently selected
collection / container name, and the partition key name associated with the collection.
The **New-AxCosmosContext** cmdlet is used to create a new context.
When creating a new Cosmos account with **New-AxCosmosAccount**, a context will also be return
but it will be necessary to then create a database and container before Cosmos documents can be added.
Use **Select-AxCosmosDatabaseCollection** to switch between collections (contgainers) within the selected database.

### Getting Started
The following steps will help you get started.

1) Install and import the Ax.CosmosDb module.

```
Import-Module Ax.CosmosDb
```

2) The first step is to create a Cosmos account. This can be done with the **New-AxCosmosAccount** cmdlet.
The process takes almost 5 minutes to complete.

3)  TBD


This small module provides the following commands

Get-AxCosmosAuthSignature
Get-AxCosmosDatabase
Get-AxCosmosDatabaseCollection
Get-AxCosmosDocuments
New-AxCosmosAccount
New-AxCosmosContext
New-AxCosmosDatabase
New-AxCosmosDatabaseCollection
New-AxCosmosDocument
Remove-AxCosmosAccount
Remove-AxCosmosDatabase
Remove-AxCosmosDatabaseCollection
Select-AxCosmosDatabaseCollection


# Next Steps

* Implement Remove-AxCosmosDocument

* Eliminate need for .Key property in AxCosmosContext.
This involves changing the code to use the hmacSHA256 instance. 

* Improve the Query-AxCosmosDocuments cmdlet.
The cmdlet is fairly narrow and tedious to use.
Provide a "simple" mode along side the more complex query mode.

* 

