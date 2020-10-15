# Ax.Markdown
A module containing some helper functions for generating Markdown.


## Cmdlets
This module provides the following commands

| Cmdlet | Description |
| --- | --- |
| Get-MarkdownFromModule | Retrieve the help information in markdown format from one or all cmdlets within the specified module.|


### Get-MarkdownFromModule
The purpose of this cmdlet is to generate documentation in Markdown format for a single cmdlet or all cmdlets in the specified PowerShell module.
This is useful not only for modules which you may create, but also for 3rd party modules which have poor online documentation
Running **Get-Help** on each cmdlet is tedious, so generating reference documentation in Markdown format helps.

Hopefully, this tool can evolve to help other PowerShell module developers to automatically generate their documentation page
directly from each cmdlet's help section.


## Getting Started
The following steps will help you get started:

1) Install the single script **Get-MarkdownFromModule.ps1** within Ax.Markdown folder.

2) Generate the Markdown for a module (in this example, for Az.Storage) and output it to a file:

```
Get-MarkdownFromModule -Module 'Az.Storage' > Az.Storage.md
```


## Next Steps
In no particular order:

* Add a -Cmdlet parameter to Get-MarkdownFromModule in order to retreive the help for a specific cmdlet only.

* Add a -Output parameter to Get-MarkdownFromModule in order to generate the named file (as an alternative to redirecting the output).

