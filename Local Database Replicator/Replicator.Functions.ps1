# Reusable functions for replicating tables from a source database (QA, etc.) into a local SQL Server database.
# Dot-source this file: . "$PSScriptRoot\Replicator.Functions.ps1"

Add-Type -AssemblyName System.Data

function Write-Log
{
    # Progress line: DarkGray = routine step, Green = success, Yellow = notable, Red = problem
    param([string]$Message, [ValidateSet('DarkGray', 'Green', 'Yellow', 'Red', 'Cyan')] [string]$Color = 'DarkGray')

    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor $Color
}

function Get-EntraSqlToken
{
    Write-Log 'Requesting Entra access token for Azure SQL via az CLI...'
    $token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv 2> $null)
    if (-not $token)
    {
        throw "Could not get an Entra token. Run 'az login' first."
    }
    Write-Log 'Entra access token obtained.'
    $token
}

function Open-SqlConnection
{
    param([string]$ConnectionString, [string]$AccessToken)

    # System.Data.SqlClient has no 'Authentication' keyword: strip it and use an Entra token from the az CLI instead
    if ($ConnectionString -match 'Authentication\s*=\s*Active Directory')
    {
        $ConnectionString = $ConnectionString -replace 'Authentication\s*=[^;]*;?', ''
        if (-not $AccessToken)
        {
            $AccessToken = Get-EntraSqlToken
        }
    }
    $c = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    if ($AccessToken)
    {
        $c.AccessToken = $AccessToken
    }
    Write-Log "Opening SQL connection to [$( $c.DataSource ) / $( $c.Database )]..."
    $c.Open()
    Write-Log "Connected to [$( $c.DataSource ) / $( $c.Database )]." Green
    $c
}

function Invoke-SqlQuery
{
    param($Connection, [string]$Sql, [hashtable]$Parameters = @{ }, [int]$TimeoutSeconds = 600)

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = $TimeoutSeconds
    foreach ($k in $Parameters.Keys)
    {
        [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k])
    }
    $dt = New-Object System.Data.DataTable
    $dt.Load($cmd.ExecuteReader())
    ,$dt
}

function Assert-LocalConnection
{
    # Hard guard: only a shared-memory connection (same machine, never network) to this machine's own SQL Server passes.
    param($Connection)

    $row = (Invoke-SqlQuery -Connection $Connection -Sql "SELECT CONNECTIONPROPERTY('net_transport') AS t, CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')) AS m, CONNECTIONPROPERTY('client_net_address') AS a").Rows[0]
    if ($row.t -ne 'Shared memory' -or $row.m -ne $env:COMPUTERNAME)
    {
        throw "SAFETY: refusing to write to '$( $Connection.DataSource ) / $( $Connection.Database )': it is not the local SQL Server (transport '$( $row.t )', machine '$( $row.m )')."
    }
}

function Invoke-SqlNonQuery
{
    # All writes go through here and are only ever allowed on the local SQL Server.
    param($Connection, [string]$Sql, [int]$TimeoutSeconds = 600)

    Assert-LocalConnection $Connection
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = $TimeoutSeconds
    [void]$cmd.ExecuteNonQuery()
}

function Get-TableColumns
{
    param($Connection, [string]$Schema, [string]$Table, [int]$TimeoutSeconds = 600)

    $dt = Invoke-SqlQuery -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Parameters @{ '@s' = $Schema; '@t' = $Table } -Sql @"
SELECT c.name FROM sys.columns c
WHERE c.object_id = OBJECT_ID(QUOTENAME(@s) + '.' + QUOTENAME(@t))
  AND c.is_computed = 0 AND c.generated_always_type = 0
"@
    $dt.Rows | ForEach-Object { $_.name }
}

function Get-AllTableNames
{
    param($Connection, [int]$TimeoutSeconds = 600)

    Write-Log 'Reading table list from the source database...'
    $dt = Invoke-SqlQuery -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Sql "SELECT s.name + '.' + t.name AS n FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE t.temporal_type <> 1 ORDER BY 1"
    $names = @($dt.Rows | ForEach-Object { $_.n })
    Write-Log "Found $( $names.Count ) table(s) in the source database."
    $names
}

function ConvertTo-TableReference
{
    param([string[]]$Names)

    $Names | ForEach-Object {
        $p = $_ -split '\.', 2
        if ($p.Count -eq 1)
        {
            $p = @('dbo', $p[0])
        }
        [pscustomobject]@{ Schema = $p[0].Trim('[]'); Table = $p[1].Trim('[]') }
    }
}

function Test-TableExists
{
    param($Connection, $TableRef, [int]$TimeoutSeconds = 600)

    $row = (Invoke-SqlQuery -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Sql "SELECT OBJECT_ID(N'[$( $TableRef.Schema )].[$( $TableRef.Table )]', N'U') AS id").Rows[0]
    $row.id -isnot [DBNull]
}

function Show-ReplicationPlan
{
    param([string]$SourceName, [string]$DestinationName, $Tables, $Missing)

    Write-Host ''
    Write-Host '==================== PLAN ====================' -ForegroundColor Cyan
    Write-Host "SOURCE (READ-ONLY, WILL NOT BE MODIFIED) : $SourceName" -ForegroundColor Green
    Write-Host "DESTINATION (WILL BE EMPTIED + RELOADED) : $DestinationName" -ForegroundColor Red
    Write-Host ''
    Write-Host "Tables that will be EMPTIED in [$DestinationName]" -ForegroundColor Red
    Write-Host "and RE-SEEDED with data from [$SourceName]:" -ForegroundColor Yellow
    foreach ($t in $Tables)
    {
        Write-Host "  - [$( $t.Schema )].[$( $t.Table )]"
    }
    Write-Host ''
    if ($Missing)
    {
        Write-Host 'Tables NOT in the local DB (SKIPPED, nothing touched; run migrations if you need them):' -ForegroundColor DarkYellow
        foreach ($t in $Missing)
        {
            Write-Host "  - [$( $t.Schema )].[$( $t.Table )]" -ForegroundColor DarkYellow
        }
        Write-Host ''
    }
    Write-Host "Server [$SourceName] is left UNMODIFIED (only SELECT queries are run against it)." -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Confirm-Action
{
    param([string]$Description)

    Write-Host "About to: $Description" -ForegroundColor Yellow
    do
    {
        $answer = (Read-Host 'Proceed? [Y] Yes  [N] No (abort)').Trim().ToLowerInvariant()
    } while ($answer -notin 'y', 'n')
    $answer -eq 'y'
}

function Clear-LocalTables
{
    param($Connection, $Tables, [int]$TimeoutSeconds = 600)

    # FKs are disabled first so deletion order does not matter
    try
    {
        Write-Log "Disabling FK constraints on $( @($Tables).Count ) local table(s)..."
        foreach ($t in $Tables)
        {
            Invoke-SqlNonQuery $Connection "ALTER TABLE [$( $t.Schema )].[$( $t.Table )] NOCHECK CONSTRAINT ALL" $TimeoutSeconds
        }
        Write-Log "Emptying $( @($Tables).Count ) local table(s)..." Yellow
        foreach ($t in $Tables)
        {
            Write-Log "  DELETE FROM [$( $t.Schema )].[$( $t.Table )]"
            Invoke-SqlNonQuery $Connection "DELETE FROM [$( $t.Schema )].[$( $t.Table )]" $TimeoutSeconds
        }
    }
    catch
    {
        Write-Log "Failed while emptying local tables, re-enabling FK constraints: $( $_.Exception.Message )" Red
        foreach ($t in $Tables)
        {
            try
            {
                Invoke-SqlNonQuery $Connection "ALTER TABLE [$( $t.Schema )].[$( $t.Table )] CHECK CONSTRAINT ALL" $TimeoutSeconds
            }
            catch
            {
            }
        }
        throw
    }
}

function Copy-TableData
{
    param($Source, $Destination, $TableRef, [string]$SourceName, [string]$DestinationName, [int]$BatchSize = 5000, [int]$TimeoutSeconds = 600)

    Assert-LocalConnection $Destination
    $full = "[$( $TableRef.Schema )].[$( $TableRef.Table )]"
    $destColumns = @(Get-TableColumns $Destination $TableRef.Schema $TableRef.Table $TimeoutSeconds)
    $cols = @(Get-TableColumns $Source $TableRef.Schema $TableRef.Table $TimeoutSeconds) | Where-Object { $destColumns -contains $_ }
    if (-not $cols)
    {
        Write-Log "$full : no common columns, skipped" Yellow; return
    }
    $colList = ($cols | ForEach-Object { "[$_]" }) -join ','

    Write-Log "$full : copying $( @($cols).Count ) column(s) from source (batch size $BatchSize)..."
    $cmd = $Source.CreateCommand()
    $cmd.CommandText = "SELECT $colList FROM $full"
    $cmd.CommandTimeout = $TimeoutSeconds
    $reader = $cmd.ExecuteReader()
    try
    {
        $opts = [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock
        $bc = New-Object System.Data.SqlClient.SqlBulkCopy($Destination, $opts, $null)
        $bc.DestinationTableName = $full
        $bc.BatchSize = $BatchSize
        $bc.BulkCopyTimeout = $TimeoutSeconds
        foreach ($c in $cols)
        {
            [void]$bc.ColumnMappings.Add($c, $c)
        }
        $bc.WriteToServer($reader)
        $bc.Close()
    }
    finally
    {
        $reader.Close()
    }

    $count = (Invoke-SqlQuery -Connection $Destination -TimeoutSeconds $TimeoutSeconds -Sql "SELECT COUNT_BIG(*) AS c FROM $full").Rows[0].c
    Write-Log "$full : $count rows copied  [$SourceName] -> [$DestinationName]" Green
}

function Invoke-TableReplication
{
    <#
    .SYNOPSIS
      Copies tables from a source database into a local SQL Server database ((local), Windows auth).
      -Force skips the confirmation prompt.
    #>
    param(
        [Parameter(Mandatory)] [string]$SourceConnectionString,
        [string]$SourceAccessToken,
        [Parameter(Mandatory)] [string]$LocalDatabase,
        [string[]]$Tables,
        [switch]$AllTables,
        [string[]]$ExcludeTables = @('dbo.__EFMigrationsHistory', 'dbo.__RefactorLog'),
        [int]$BatchSize = 5000,
        [int]$TimeoutSeconds = 600,
        [switch]$Force
    )

    if ( [string]::IsNullOrWhiteSpace($LocalDatabase))
    {
        throw 'No local database specified. Pass the name of the database on the local SQL Server to overwrite with -LocalDatabase <name> (e.g. -LocalDatabase ProductApi).'
    }

    # Plain identifier only, so the name cannot inject extra connection-string keywords (e.g. ;Server=...)
    if ($LocalDatabase -notmatch '^[A-Za-z0-9_.\-]+$')
    {
        throw "Invalid local database name '$LocalDatabase'."
    }

    Write-Log "Starting replication into local database '$LocalDatabase'." Cyan
    $source = Open-SqlConnection $SourceConnectionString $SourceAccessToken
    $local = $null
    try
    {
        $local = Open-SqlConnection "Server=(local);Database=$LocalDatabase;Trusted_Connection=yes;TrustServerCertificate=True;" $null
        Assert-LocalConnection $local
        Write-Log 'Safety check passed: destination is the local SQL Server.' Green

        if ($AllTables)
        {
            $Tables = Get-AllTableNames $source $TimeoutSeconds
        }
        if (-not $Tables)
        {
            throw 'Provide -Tables or -AllTables.'
        }

        $Tables = $Tables | Where-Object { $ExcludeTables -notcontains $_ }
        $parsed = @(ConvertTo-TableReference $Tables)

        Write-Log "Checking which of $( $parsed.Count ) table(s) exist in the local database..."
        $missing = @($parsed | Where-Object { -not (Test-TableExists $local $_ $TimeoutSeconds) })
        $parsed = @($parsed | Where-Object { $missing -notcontains $_ })
        Write-Log "$( $parsed.Count ) table(s) to copy, $( $missing.Count ) missing locally (skipped)."
        if (-not $parsed)
        {
            throw 'None of the tables exist in the local database.'
        }

        $sourceName = "$( $source.DataSource ) / $( $source.Database )"
        $localName = "$( $local.DataSource ) / $( $local.Database )"
        if ($sourceName -eq $localName)
        {
            throw 'Source and destination are the same database. Aborting.'
        }

        Show-ReplicationPlan $sourceName $localName $parsed $missing

        if (-not $Force)
        {
            $action = "EMPTY $( $parsed.Count ) table(s) in LOCAL [$localName] and reload them from SOURCE [$sourceName] (source is not modified)"
            if (-not (Confirm-Action $action))
            {
                Write-Host 'Aborted. Nothing was modified.' -ForegroundColor Green; return
            }
        }

        Clear-LocalTables $local $parsed $TimeoutSeconds
        foreach ($t in $parsed)
        {
            Copy-TableData $source $local $t $sourceName $localName $BatchSize $TimeoutSeconds
        }
        Write-Log 'Re-enabling and validating FK constraints...'
        foreach ($t in $parsed)
        {
            Invoke-SqlNonQuery $local "ALTER TABLE [$( $t.Schema )].[$( $t.Table )] WITH CHECK CHECK CONSTRAINT ALL" $TimeoutSeconds
        }
        Write-Log "Done: '$LocalDatabase' replicated ($( $parsed.Count ) table(s))." Green
    }
    finally
    {
        $source.Dispose()
        if ($local)
        {
            $local.Dispose()
        }
    }
}

function Get-ConnectionStringTarget
{
    # Server / database only; never exposes credentials
    param([Parameter(Mandatory)] [string]$ConnectionString)

    $get = {
        param($names)
        foreach ($n in $names)
        {
            if ($ConnectionString -match "(?i)(?:^|;)\s*$n\s*=\s*([^;]*)")
            {
                return $Matches[1].Trim()
            }
        }
        '?'
    }
    [pscustomobject]@{ Server = (& $get @('Server', 'Data Source', 'Address', 'Addr', 'Network Address')); Database = (& $get @('Database', 'Initial Catalog')) }
}

function Read-ReplicationConfig
{
    param([Parameter(Mandatory)] [string]$Path)

    Write-Log "Reading replication config '$Path'..."
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Config file not found: $Path"
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $mappings = @($config.PSObject.Properties | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) } |
            ForEach-Object { [pscustomobject]@{ LocalDatabase = $_.Name; SecretName = [string]$_.Value } })
    if (-not $mappings)
    {
        throw "Config file '$Path' must map at least one local database name to a Key Vault secret name."
    }
    Write-Log "Config contains $( $mappings.Count ) database mapping(s)."
    $mappings
}

function Get-ShortErrorMessage
{
    param([string]$Message)

    if ($Message -match "Failed to resolve '([^']+)'")
    {
        return "Cannot resolve host '$( $Matches[1] )' (VPN/network?)"
    }
    $line = ($Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Length -gt 160)
    {
        $line = $line.Substring(0, 157) + '...'
    }
    $line
}

function Assert-AzLogin
{
    Write-Log "Checking status of 'az login'..."
    az account show --query id -o tsv 2> $null | Out-Null

    if ($LASTEXITCODE -ne 0)
    {
        throw "Not signed in to Azure. Run 'az login' first."
    }
    else
    {
        Write-Log 'Already signed in to Azure.' Green
    }
}

function Get-KeyVaultSecretValue
{
    param([Parameter(Mandatory)] [string]$VaultName, [Parameter(Mandatory)] [string]$SecretName)

    Write-Log "Reading secret '$SecretName' from vault '$VaultName'..."
    $value = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2> $null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value))
    {
        Write-Log "Failed to read secret '$SecretName'." Red
        throw "Could not read secret '$SecretName' from vault '$VaultName' (check the name and that your Entra identity has 'Key Vault Secrets User' / get permission)."
    }
    Write-Log "Secret '$SecretName' read." Green
    $value
}
