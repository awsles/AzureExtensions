# Runbook_VMScheduler.ps1
This runbook is used to automatically start and stop virtual machines based on associated tags.

While Azure VMs have an Auto-Shutdown scheduling capability, there is (sadly) no
corresponding Auto-Startup scheduling. This runbook was developed to address this gap.

This script, when run on a regular scheduled basis (every 15 minutes), will retrieve 
the tags 'AutoStart' and 'AutoStop' for each virtual machine using a kusto query
(which can span multiple Azure subscriptions if the user context has permission to do so).

**AutoStart** - Indicates the time at which the associated VM should be started.
**AutoStop** - Indicates the time at which the associated VM should be stopped.

If there is a match on the time window, the VM will be started or stopped, respectively.

## Tag Format
The tag values are in the form:   "[days] HH:MM" where 'HH:MM' is the time (UTC) and 'days'
(optional) may be either "**Weekdays**", "**Daily**", or include the application three-letter
weekday names (e.g., "**Mon,Wed,Fri**"). For example, "**Mon,Tue,Fri 08:30**" will apply to
Mondays, Tuesdays, and Fridays 08:30 AM UTC.  Multiple schedules may be specified by
separating each with a semicolon (e.g., "Weekdays 08:00;Sat,Sun 10:30").
Note that the time is always 24 hour UTC!

The AutoStop time must be at least 30 minutes after the AutoStart time.  To have a VM
run from Monday 8am to Fri 6pm, specify AutoStart="Mon 08:00" and AutoStop="Frid 18:00".

The script must be run in a security context such as 'Virtual Machine Operator' which
allows the enumerations of VMs, their tags, and stop/stop VM capability for the target VMs.. 

## Runbook
This runbook must be operated using a service principal which has read, start, and stop
access to the target virtual machines (e.g., has a "Virtual Machine Operator" role).

Necessary permissions for the Service Principal role include:

```
Microsoft.Compute/\*/read
Microsoft.Compute/virtualMachines/start/action
Microsoft.Compute/virtualMachines/restart/action
Microsoft.Compute/virtualMachines/deallocate/action
Microsoft.Compute/virtualMachines/redeploy/action
Microsoft.Compute/virtualMachines/poweroff/action
Microsoft.ClassicCompute/\*/read
Microsoft.ClassicCompute/virtualMachines/restart/action
Microsoft.ClassicCompute/virtualMachines/shutdown/action
Microsoft.ClassicCompute/virtualMachines/start/action
Microsoft.ClassicCompute/virtualMachines/stop/action
```


## Configuring a VM Schedule
In order to enable a start/stop schedule on a VM, you must:

1) Grant the Application Service Principal the "Virtual Machine Operator" or equivalent role on the target VM. 

2) Provision the AutoStart and/or AutoStop tags as desired. Specify time on a 15 minuteinterval (
(i.e., using either *hh*:**00**, *hh*:**15**, *hh*:**30**, or *hh*:**45**) as this runbook
is configured to check only once every 15 minutes.

## Limitations
Current limitations include:

* The schedule is limited to a single starting time and a single ending time each day.
However, multiple weekdays may be specified to allow for daily operation.

* Only UTC time is currently supported. A future version may support the VM's local time.

* Error logging is mininal and is only accessible in the Security Automation runbook jobs list.

