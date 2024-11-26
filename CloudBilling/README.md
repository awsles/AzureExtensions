# CloudBilling
Scripts for retrieving and analysing public cloud billing data.

PowerShell scripts and useful tips are provided for retreiving the billing information from various public cloud providers
(Azure, AWS, and Google Cloud (GCP)) and analysing the data. There is a folder and a README for each.



## PowerShell Verbs
The PowerShell cmdlets herein generally follow the Microsoft guidance for naming:
https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands

However, I use ```Create``` as a verb as it is so much more succinct than ```New```, ```Build```, and ```Add```.
It also works better for certain artefacts like reports. *I "create" a report* is MUCH better than *I "Add/Build/New" a report*.

The issue is debated here:
https://stackoverflow.com/questions/26485118/create-vs-new-powershell-approved-verbs/61833808#61833808
