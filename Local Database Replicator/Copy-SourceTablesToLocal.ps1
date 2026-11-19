<#
.SYNOPSIS
  Copies all rows of the given tables from a source database (e.g. QA) to a local database (identity values preserved).

.EXAMPLE
  .\Copy-SourceTablesToLocal.ps1 -SourceConnectionString "Server=tcp:qa-sql.database.windows.net;Database=qa-ProductApi;Authentication=Active Directory Default;Encrypt=True" -LocalDatabase ProductApi -Tables dbo.Product,dbo.Category

.EXAMPLE
  # All tables, source via Entra token
  $token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
  .\Copy-SourceTablesToLocal.ps1 -SourceConnectionString "Server=tcp:qa-sql.database.windows.net;Database=qa-ProductApi;Encrypt=True" -SourceAccessToken $token -LocalDatabase ProductApi -AllTables

.NOTES
  The destination is always the local SQL Server ((local), Windows auth); -LocalDatabase is mandatory.
  Default exclusions: dbo.__EFMigrationsHistory, dbo.__RefactorLog.
  Destination tables are emptied (DELETE) before copy. Only columns existing in both DBs are copied;
  computed / generated-always columns are skipped. FK constraints are disabled during the load and re-validated after.
  Use -Force to skip the confirmation prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SourceConnectionString,
    [string]$SourceAccessToken,
    [string]$LocalDatabase,
    [string[]]$Tables,
    [switch]$AllTables,
    [string[]]$ExcludeTables = @('dbo.__EFMigrationsHistory', 'dbo.__RefactorLog'),
    [int]$BatchSize = 5000,
    [int]$TimeoutSeconds = 600,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Replicator.Functions.ps1"

Invoke-TableReplication @PSBoundParameters
