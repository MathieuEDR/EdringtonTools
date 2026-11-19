<#
.SYNOPSIS
  Copies ALL tables of several databases into the matching local databases. Source connection strings are read from
  Azure Key Vault using the signed-in user's Entra identity (az CLI).

.EXAMPLE
  .\Copy-AllSourceTablesToLocal.ps1
  .\Copy-AllSourceTablesToLocal.ps1 -ConfigPath D:\other\LocalDatabaseReplicationConfig.json

.NOTES
  The config file (default: <user home>\EdringtonTools\LocalDatabaseReplicationConfig.json) maps each LOCAL database name
  to the Key Vault (without environment prefix) and the secret holding its SOURCE connection string:
    { "OrderApi": { "Vault": "egw-orderapi", "Secret": "edrington--all--OrderApiDatabaseConnectionString" } }
  The vault actually used is "<Environment>-<Vault>", e.g. qa-egw-orderapi (-Environment, default qa).
  Requires 'az login' and get permission on the vault secrets.
  Asks for confirmation once for all databases; -Force skips it. A failure on one database does not stop the others.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME 'EdringtonTools\LocalDatabaseReplicationConfig.json'),
    [ValidateSet('dev', 'qa', 'prod')] [string]$Environment = 'qa',
    [string[]]$ExcludeTables = @('dbo.__EFMigrationsHistory', 'dbo.__RefactorLog'),
    [int]$BatchSize = 5000,
    [int]$TimeoutSeconds = 600,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Replicator.Functions.ps1"

$mappings = Read-ReplicationConfig $ConfigPath
Write-Host "Config: $ConfigPath (environment: $Environment)" -ForegroundColor DarkGray

Assert-AzLogin

$resolved = foreach ($m in $mappings) {
    $db = $m.LocalDatabase
    $vault = "$Environment-$($m.Vault)"
    try {
        $cs = Get-KeyVaultSecretValue -VaultName $vault -SecretName $m.SecretName
        $target = Get-ConnectionStringTarget $cs
        $probe = Open-SqlConnection $cs $null
        $probe.Dispose()
        [pscustomobject]@{ Database = $db; Vault = $vault; SecretName = $m.SecretName; ConnectionString = $cs; Server = $target.Server; SourceDatabase = $target.Database; Error = $null }
    }
    catch {
        [pscustomobject]@{ Database = $db; Vault = $vault; SecretName = $m.SecretName; ConnectionString = $null; Server = '-'; SourceDatabase = '-'; Error = Get-ShortErrorMessage $_.Exception.Message }
    }
}

Write-Host "`nSOURCES (READ-ONLY) -> LOCAL DESTINATIONS (WILL BE EMPTIED + RELOADED), environment '$Environment':" -ForegroundColor Yellow
$resolved | ForEach-Object {
    [pscustomobject]@{
        'Target (local)'  = "(local) / $($_.Database)"
        'Source (remote)' = if ($_.Error) { "$($_.Vault) / $($_.SecretName)" } else { "$($_.Server) / $($_.SourceDatabase)" }
        'Status'          = if ($_.Error) { "ERROR: $($_.Error)" } else { 'Connected' }
    }
} | Format-Table -AutoSize -Wrap
if (-not ($resolved | Where-Object { -not $_.Error })) {
    Write-Host "`nNo source connection string could be resolved, nothing to do. Nothing was modified." -ForegroundColor Red
    Write-Host "Check you are signed in (az login), connected to the network/VPN that can reach the vaults, and that the vault and secret names in the config exist." -ForegroundColor Red
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
