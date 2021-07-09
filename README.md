# AzureExtensions
Miscellaneous PowerShell extensions for Azure and Office 365.

* **Ax.Application** - Script *New-AxServicePrincipal.ps1* to create a new Application Service Principal and certificate.
* **Ax.Automation** - Script *Export-AxAutomationAccount.ps1* which exports the contents of an Azure Automation account.
* **Ax.Cosmos** – Alpha version of a some CosmosDB cmdlets.  See the next steps for the work still to do.
* **Ax.Markdown** – Quick script that extracts the help info from an Azure module and generates a Markdown page for it. Useful for those 3rd party modules which often don’t have very much documentation, except within each cmdlet itself.
* **Ax.Tags** – Script *Remove-AxTags.ps1* which removes all instances of a tag or tag:value.
* **Ax.VM** - Contains *Stop-AxMyVM.ps1* which stops and deallocates the currently running VM. No need to configure the VM details (but you do need a service principal and certificate).
* **Runbooks** - Contains *Runbook_VMScheduler.ps1* which can be used to Start and stop VMs just by using tags. A simpler solution than some of the others for starting VMs on a schedule. Also contains *Runbook_TagResourceCreators.ps1* which automatically tags newly created Azure resources with the identity of the person who created it.

