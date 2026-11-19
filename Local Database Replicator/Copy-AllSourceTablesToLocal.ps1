<#
.SYNOPSIS
  Copies ALL tables of several databases into the matching local databases. Source connection strings are read from
  Azure Key Vault using the signed-in user's Entra identity (az CLI).

.EXAMPLE
  .\Copy-AllSourceTablesToLocal.ps1
  .\Copy-AllSourceTablesToLocal.ps1 -ConfigPath D:\other\LocalDatabaseReplicationConfig.json

.NOTES
  The config file (default: <user home>\EdringtonTools\LocalDatabaseReplicationConfig.json) maps each LOCAL database name
  to the fully qualified Key Vault secret name holding its SOURCE connection string:
    { "ProductApi": "edrington--all--ProductApiDatabaseConnectionString", "OrderApi": "edrington--all--OrderApiDatabaseConnectionString" }
  Requires 'az login' and get permission on the vault secrets (-VaultName, default qa-egw-common).
  Asks for confirmation once for all databases; -Force skips it. A failure on one database does not stop the others.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME 'EdringtonTools\LocalDatabaseReplicationConfig.json'),
    [string]$VaultName = 'qa-egw-common',
    [string[]]$ExcludeTables = @('dbo.__EFMigrationsHistory', 'dbo.__RefactorLog'),
    [int]$BatchSize = 5000,
    [int]$TimeoutSeconds = 600,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Replicator.Functions.ps1"

$mappings = Read-ReplicationConfig $ConfigPath
Write-Host "Config: $ConfigPath" -ForegroundColor DarkGray

Assert-AzLogin

$resolved = foreach ($m in $mappings) {
    $db = $m.LocalDatabase
    try {
        $cs = Get-KeyVaultSecretValue -VaultName $VaultName -SecretName $m.SecretName
        $target = Get-ConnectionStringTarget $cs
        $probe = Open-SqlConnection $cs $null
        $probe.Dispose()
        [pscustomobject]@{ Database = $db; ConnectionString = $cs; Server = $target.Server; SourceDatabase = $target.Database; Error = $null }
    }
    catch {
        [pscustomobject]@{ Database = $db; ConnectionString = $null; Server = '-'; SourceDatabase = '-'; Error = Get-ShortErrorMessage $_.Exception.Message }
    }
}

Write-Host "`nSOURCES (READ-ONLY) -> LOCAL DESTINATIONS (WILL BE EMPTIED + RELOADED), vault '$VaultName':" -ForegroundColor Yellow
$resolved | ForEach-Object {
    [pscustomobject]@{
        'Target (local)'  = "(local) / $($_.Database)"
        'Source (remote)' = if ($_.Error) { $m = $mappings | Where-Object LocalDatabase -eq $_.Database; "secret: $($m.SecretName)" } else { "$($_.Server) / $($_.SourceDatabase)" }
        'Status'          = if ($_.Error) { "ERROR: $($_.Error)" } else { 'Connected' }
    }
} | Format-Table -AutoSize -Wrap
if (-not ($resolved | Where-Object { -not $_.Error })) {
    Write-Host "`nNo source connection string could be resolved, nothing to do. Nothing was modified." -ForegroundColor Red
    Write-Host "Check you are signed in (az login), connected to the network/VPN that can reach the vault '$VaultName', and that the secret names in the config exist." -ForegroundColor Red
    exit 1
}
if (-not $Force -and -not (Confirm-Action "EMPTY and reload all tables of $(@($resolved | Where-Object { -not $_.Error }).Count) local database(s)")) {
    Write-Host 'Aborted. Nothing was modified.' -ForegroundColor Green
    return
}

$results = foreach ($r in $resolved) {
    $db = $r.Database
    Write-Host "`n########## $db ##########" -ForegroundColor Cyan
    try {
        if ($r.Error) { throw $r.Error }
        Invoke-TableReplication -SourceConnectionString $r.ConnectionString -LocalDatabase $db -AllTables `
            -ExcludeTables $ExcludeTables -BatchSize $BatchSize -TimeoutSeconds $TimeoutSeconds -Force
        [pscustomobject]@{ Database = $db; Status = 'Succeeded'; Error = '' }
    }
    catch {
        Write-Warning "$db failed: $($_.Exception.Message)"
        [pscustomobject]@{ Database = $db; Status = 'Failed'; Error = $_.Exception.Message }
    }
}

Write-Host "`n==================== SUMMARY ====================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
if ($results | Where-Object Status -eq 'Failed') { exit 1 }
