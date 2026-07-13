# ============================================================
# scripts/reset_local.ps1
# Full local reset for the FretVision database on Windows.
#
#   1. Start local Supabase
#   2. Reset database and apply migrations 0001-0007
#   3. Create/update fretvision_app
#   4. Apply least-privilege backend grants
#
# PostgreSQL administrator strategy:
#   * When using Docker psql, automatically select an accessible
#     PostgreSQL superuser. Supabase local images normally provide
#     supabase_admin for internal administration.
#   * When using host psql.exe, PGUSER must identify a superuser-
#     equivalent role.
#
# The application-role password is delivered over psql stdin only
# after all standard statement/duration logging paths are disabled.
# ============================================================
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$ConfigPath  = Join-Path $RepoRoot 'supabase\config.toml'
$SupabaseCli = Join-Path $RepoRoot 'node_modules\.bin\supabase.cmd'

$AppRole = 'fretvision_app'

function Assert-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found on PATH"
  }
}

function ConvertTo-SqlLiteral([string]$Value) {
  "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-PgpassField([string]$Value) {
  $Value.Replace('\', '\\').Replace(':', '\:')
}

function Read-HiddenString([string]$Prompt) {
  $Secure = Read-Host -Prompt $Prompt -AsSecureString
  $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)

  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
  }
}

function Resolve-SupabaseDbContainerName {
  if ($env:SUPABASE_DB_CONTAINER) {
    return $env:SUPABASE_DB_CONTAINER
  }

  if (Test-Path -LiteralPath $ConfigPath) {
    $ConfigText = Get-Content -Raw -LiteralPath $ConfigPath
    $Match = [regex]::Match(
      $ConfigText,
      '(?m)^\s*project_id\s*=\s*"([^"]+)"\s*$'
    )

    if ($Match.Success) {
      return "supabase_db_$($Match.Groups[1].Value)"
    }
  }

  return 'supabase_db_FretVision'
}

function Assert-DockerContainerRunning {
  Assert-Command 'docker'

  $State = & docker inspect `
    --format '{{.State.Running}}' `
    $script:SupabaseDbContainer 2>$null

  if (
    $LASTEXITCODE -ne 0 -or
    -not $State -or
    ([string]$State).Trim() -ne 'true'
  ) {
    throw "Supabase database container '$script:SupabaseDbContainer' is not running"
  }
}

function Resolve-DockerSuperuserRole {
  Assert-DockerContainerRunning

  $Candidates = @()

  if ($env:SUPABASE_DB_SUPERUSER) {
    $Candidates += $env:SUPABASE_DB_SUPERUSER
  }

  $Candidates += 'supabase_admin'
  $Candidates += 'postgres'
  $Candidates = $Candidates | Select-Object -Unique

  foreach ($Candidate in $Candidates) {
    $Result = & docker exec -i $script:SupabaseDbContainer `
      psql `
      -U $Candidate `
      -d postgres `
      --no-psqlrc `
      --quiet `
      --tuples-only `
      --no-align `
      --set=ON_ERROR_STOP=1 `
      --command="select rolsuper from pg_catalog.pg_roles where rolname = current_user" `
      2>$null

    $CommandExitCode = $LASTEXITCODE

    if ($CommandExitCode -eq 0 -and $Result) {
      $Value = ($Result | Select-Object -Last 1).ToString().Trim()

      if ($Value -eq 't') {
        return $Candidate
      }
    }
  }

  throw @"
No accessible PostgreSQL superuser was found in '$script:SupabaseDbContainer'.
Tried: $($Candidates -join ', ').
Verify with:
docker exec -i $script:SupabaseDbContainer psql -U supabase_admin -d postgres -tA -c "select current_user, rolsuper from pg_roles where rolname=current_user;"
"@
}

function Invoke-PsqlStdin {
  param(
    [Parameter(Mandatory)]
    [string]$Sql
  )

  $PsqlArgs = @(
    '--no-psqlrc',
    '--quiet',
    '--set=ON_ERROR_STOP=1',
    '--file=-'
  )

  if ($script:UseDockerPsql) {
    $Sql | & docker exec -i $script:SupabaseDbContainer `
      psql `
      -U $script:DockerAdminRole `
      -d postgres `
      @PsqlArgs
  }
  else {
    $Sql | & $script:HostPsqlPath @PsqlArgs
  }

  if ($LASTEXITCODE -ne 0) {
    throw "psql exited with code $LASTEXITCODE"
  }
}

function Invoke-PsqlScalar {
  param(
    [Parameter(Mandatory)]
    [string]$Sql
  )

  $PsqlArgs = @(
    '--no-psqlrc',
    '--quiet',
    '--tuples-only',
    '--no-align',
    '--set=ON_ERROR_STOP=1',
    "--command=$Sql"
  )

  if ($script:UseDockerPsql) {
    $Result = & docker exec -i $script:SupabaseDbContainer `
      psql `
      -U $script:DockerAdminRole `
      -d postgres `
      @PsqlArgs
  }
  else {
    $Result = & $script:HostPsqlPath @PsqlArgs
  }

  if ($LASTEXITCODE -ne 0) {
    throw "psql scalar query exited with code $LASTEXITCODE"
  }

  if (-not $Result) {
    return ''
  }

  return ($Result | Select-Object -Last 1).ToString().Trim()
}

$HostPsql = Get-Command psql -CommandType Application -ErrorAction SilentlyContinue

$script:HostPsqlPath = if ($HostPsql) { $HostPsql.Source } else { $null }
$script:UseDockerPsql = -not [bool]$HostPsql
$script:SupabaseDbContainer = Resolve-SupabaseDbContainerName
$script:DockerAdminRole = $null

$RequiredFiles = @(
  (Join-Path $ScriptDir 'bootstrap_role.sql'),
  (Join-Path $ScriptDir 'grant_fretvision_app.sql')
)

$TempPgpass = $null
$OwnsPgpass = $false
$PlainPassword = $null
$BootstrapSql = $null
$GrantSql = $null
$LocationPushed = $false

try {
  if (-not (Test-Path -LiteralPath $SupabaseCli)) {
    throw 'Local Supabase CLI not found. Run: npm install supabase --save-dev'
  }

  if (
    $env:FRETVISION_APP_ROLE -and
    $env:FRETVISION_APP_ROLE -ne $AppRole
  ) {
    throw "FRETVISION_APP_ROLE must be '$AppRole'"
  }

  foreach ($RequiredFile in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath $RequiredFile)) {
      throw "Required file not found: $RequiredFile"
    }
  }

  if (-not $env:PGHOST)     { $env:PGHOST     = '127.0.0.1' }
  if (-not $env:PGPORT)     { $env:PGPORT     = '54322' }
  if (-not $env:PGDATABASE) { $env:PGDATABASE = 'postgres' }
  if (-not $env:PGUSER)     { $env:PGUSER     = 'postgres' }

  $IsLocalStack = (
    $env:PGHOST -eq '127.0.0.1' -or
    $env:PGHOST -eq 'localhost'
  )

  if ($script:UseDockerPsql -and -not $IsLocalStack) {
    throw 'Host psql is unavailable, and Docker psql fallback is local-only'
  }

  Push-Location $RepoRoot
  $LocationPushed = $true

  Write-Host '==> supabase start'
  & $SupabaseCli start

  if ($LASTEXITCODE -ne 0) {
    throw 'supabase start failed'
  }

  Write-Host '==> supabase db reset'
  & $SupabaseCli db reset

  if ($LASTEXITCODE -ne 0) {
    throw 'supabase db reset failed'
  }

  if ($script:UseDockerPsql) {
    $script:DockerAdminRole = Resolve-DockerSuperuserRole
    Write-Host "==> admin psql: using Docker container '$script:SupabaseDbContainer' as '$script:DockerAdminRole'"
  }
  else {
    if (-not $env:PGPASSFILE) {
      $AdminPassword = if ($env:ADMIN_DB_PASSWORD) {
        $env:ADMIN_DB_PASSWORD
      }
      elseif ($IsLocalStack) {
        'postgres'
      }
      else {
        Read-HiddenString "Admin DB password for $($env:PGUSER)@$($env:PGHOST):$($env:PGPORT)"
      }

      if ([string]::IsNullOrEmpty($AdminPassword)) {
        throw 'empty admin password'
      }

      $TempPgpass = Join-Path (
        [IO.Path]::GetTempPath()
      ) ("fretvision-" + [Guid]::NewGuid().ToString() + ".pgpass")

      $OwnsPgpass = $true

      $Line = '{0}:{1}:*:{2}:{3}' -f `
        (ConvertTo-PgpassField $env:PGHOST), `
        (ConvertTo-PgpassField $env:PGPORT), `
        (ConvertTo-PgpassField $env:PGUSER), `
        (ConvertTo-PgpassField $AdminPassword)

      [IO.File]::WriteAllText(
        $TempPgpass,
        $Line + "`n",
        [Text.UTF8Encoding]::new($false)
      )

      $Acl = Get-Acl -Path $TempPgpass
      $Acl.SetAccessRuleProtection($true, $false)
      $Acl.Access | ForEach-Object {
        [void]$Acl.RemoveAccessRule($_)
      }

      $Rule = New-Object Security.AccessControl.FileSystemAccessRule(
        [Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl',
        'Allow'
      )

      $Acl.AddAccessRule($Rule)
      Set-Acl -Path $TempPgpass -AclObject $Acl
      $env:PGPASSFILE = $TempPgpass

      $AdminPassword = $null
      Remove-Variable -Name AdminPassword -ErrorAction SilentlyContinue
    }

    $IsSuperuser = Invoke-PsqlScalar `
      -Sql "select rolsuper from pg_catalog.pg_roles where rolname = current_user"

    if ($IsSuperuser -ne 't') {
      throw "PGUSER '$($env:PGUSER)' is not a PostgreSQL superuser. Use Docker fallback or supply a superuser-equivalent role."
    }

    Write-Host "==> admin psql: using host psql as '$($env:PGUSER)'"
  }

  $PlainPassword = if ($env:FRETVISION_APP_PASSWORD) {
    $env:FRETVISION_APP_PASSWORD
  }
  else {
    Read-HiddenString "Password for role $AppRole"
  }

  if ([string]::IsNullOrEmpty($PlainPassword)) {
    throw 'empty application-role password'
  }

  if ($PlainPassword.Length -lt 24) {
    throw 'application-role password must be at least 24 characters'
  }

  Write-Host "==> creating/updating role $AppRole"

  $BootstrapSql = @(
    'begin;',
    "set local log_statement = 'none';",
    "set local log_min_error_statement = 'panic';",
    'set local log_min_duration_statement = -1;',
    'set local log_min_duration_sample = -1;',
    'set local log_transaction_sample_rate = 0;',
    "set local fretvision.app_role = $(ConvertTo-SqlLiteral $AppRole);",
    "set local fretvision.app_pw = $(ConvertTo-SqlLiteral $PlainPassword);",
    (Get-Content -Raw -LiteralPath (Join-Path $ScriptDir 'bootstrap_role.sql')),
    'commit;'
  ) -join "`n"

  Invoke-PsqlStdin -Sql $BootstrapSql | Out-Null

  $BootstrapSql = $null
  $PlainPassword = $null

  Write-Host "==> applying least-privilege grants to $AppRole"

  $GrantSql = @(
    "set fretvision.app_role = $(ConvertTo-SqlLiteral $AppRole);",
    (Get-Content -Raw -LiteralPath (Join-Path $ScriptDir 'grant_fretvision_app.sql'))
  ) -join "`n"

  Invoke-PsqlStdin -Sql $GrantSql

  Write-Host "==> reset complete. Role $AppRole exists with least-privilege grants."
  Write-Host '    The caller may now run the pgTAP database test phases.'
}
finally {
  $BootstrapSql = $null
  $PlainPassword = $null
  $GrantSql = $null

  Remove-Variable `
    -Name BootstrapSql, PlainPassword, GrantSql `
    -ErrorAction SilentlyContinue

  if (
    $OwnsPgpass -and
    $TempPgpass -and
    (Test-Path -LiteralPath $TempPgpass)
  ) {
    Remove-Item -LiteralPath $TempPgpass -Force -ErrorAction SilentlyContinue
    $env:PGPASSFILE = $null
  }

  if ($LocationPushed) {
    Pop-Location
  }

  [GC]::Collect()
}