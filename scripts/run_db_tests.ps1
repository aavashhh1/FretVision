# ============================================================
# scripts/run_db_tests.ps1
# Batch D verification harness runner (Windows PowerShell 5.1+ / pwsh 7+).
#
# PHASES:
#   Phase 1 -> tests 001-005
#   Gate    -> verifies fretvision_app exists
#   Phase 2 -> test 006
#
# PostgreSQL client strategy:
#   * Prefer a host-installed psql.exe.
#   * Otherwise execute psql inside the local Supabase DB container.
#
# This script intentionally never defines a function named "psql".
# ============================================================
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$TestDir    = Join-Path $RepoRoot 'supabase\tests\database'
$ConfigPath = Join-Path $RepoRoot 'supabase\config.toml'

function Fail([string]$Message) {
  throw $Message
}

function Info([string]$Message) {
  Write-Host "==> $Message"
}

function Assert-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Fail "$Name not found on PATH"
  }
}

function ConvertTo-PgpassField([string]$Value) {
  $Value.Replace('\', '\\').Replace(':', '\:')
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

function Assert-DockerPsqlReady {
  Assert-Command 'docker'

  $State = & docker inspect `
    --format '{{.State.Running}}' `
    $script:SupabaseDbContainer 2>$null

  if (
    $LASTEXITCODE -ne 0 -or
    -not $State -or
    ([string]$State).Trim() -ne 'true'
  ) {
    Fail "Supabase database container '$script:SupabaseDbContainer' is not running"
  }

  & docker exec -i $script:SupabaseDbContainer `
    psql -U postgres -d postgres --version *> $null

  if ($LASTEXITCODE -ne 0) {
    Fail "psql is not available inside '$script:SupabaseDbContainer'"
  }
}

function Invoke-PsqlNative {
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  if ($script:UseDockerPsql) {
    & docker exec -i $script:SupabaseDbContainer `
      psql -U postgres -d postgres @Arguments
  }
  else {
    & $script:HostPsqlPath @Arguments
  }
}

function Invoke-Query([string]$Sql) {
  $PsqlArgs = @(
    '--no-psqlrc',
    '--quiet',
    '--tuples-only',
    '--no-align',
    '--set=ON_ERROR_STOP=1',
    "--command=$Sql"
  )

  $Result = Invoke-PsqlNative -Arguments $PsqlArgs 2>&1
  $NativeExitCode = $LASTEXITCODE

  if ($NativeExitCode -ne 0) {
    return $null
  }

  if (-not $Result) {
    return ''
  }

  return ($Result | Select-Object -Last 1).ToString().Trim()
}

$SupabaseCli = Join-Path $RepoRoot 'node_modules\.bin\supabase.cmd'
$HostPsql = Get-Command psql -CommandType Application -ErrorAction SilentlyContinue

$script:HostPsqlPath = if ($HostPsql) { $HostPsql.Source } else { $null }
$script:UseDockerPsql = -not [bool]$HostPsql
$script:SupabaseDbContainer = Resolve-SupabaseDbContainerName

Set-Variable -Name AppRole -Value 'fretvision_app' -Option Constant
$SkipReset = ($env:SKIP_RESET -eq '1')

$TempPgpass = $null
$OwnsPgpass = $false
$OwnsAdminPassword = $false
$ExitCode = 0
$LocationPushed = $false

try {
  if (-not (Test-Path -LiteralPath $SupabaseCli)) {
    Fail 'Local Supabase CLI not found. Run: npm install supabase --save-dev'
  }

  if (-not (Test-Path -LiteralPath $TestDir)) {
    Fail "test directory not found: $TestDir"
  }

  if (
    $env:FRETVISION_APP_ROLE -and
    $env:FRETVISION_APP_ROLE -ne $AppRole
  ) {
    Fail "FRETVISION_APP_ROLE='$($env:FRETVISION_APP_ROLE)' but the test suite is fixed to '$AppRole'."
  }

  if (
    (-not $SkipReset) -and
    $env:FRETVISION_APP_PASSWORD -and
    $env:FRETVISION_APP_PASSWORD.Length -lt 24
  ) {
    Fail 'FRETVISION_APP_PASSWORD must be at least 24 characters'
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
    Fail 'Host psql is unavailable, and Docker psql fallback is local-only.'
  }

  if (-not $script:UseDockerPsql) {
    if (-not $env:PGPASSFILE -and -not $env:ADMIN_DB_PASSWORD) {
      if ($IsLocalStack) {
        $env:ADMIN_DB_PASSWORD = 'postgres'
        $OwnsAdminPassword = $true
        Info "admin password: using the local Supabase default (PGHOST=$($env:PGHOST))"
      }
      else {
        Fail "PGHOST=$($env:PGHOST) is not local. Set ADMIN_DB_PASSWORD or PGPASSFILE explicitly."
      }
    }

    if (-not $env:PGPASSFILE) {
      $TempPgpass = Join-Path (
        [IO.Path]::GetTempPath()
      ) ("fretvision-tests-" + [Guid]::NewGuid().ToString() + ".pgpass")

      $OwnsPgpass = $true

      $Line = '{0}:{1}:*:{2}:{3}' -f `
        (ConvertTo-PgpassField $env:PGHOST), `
        (ConvertTo-PgpassField $env:PGPORT), `
        (ConvertTo-PgpassField $env:PGUSER), `
        (ConvertTo-PgpassField $env:ADMIN_DB_PASSWORD)

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
    }
  }
  else {
    Info "psql: using Docker container '$script:SupabaseDbContainer'"
  }

  Push-Location $RepoRoot
  $LocationPushed = $true

  Info 'preflight 1/8: supabase start'
  & $SupabaseCli start | Out-Null

  if ($LASTEXITCODE -ne 0) {
    Fail 'supabase start failed'
  }

  if ($script:UseDockerPsql) {
    Assert-DockerPsqlReady
  }

  if ($SkipReset) {
    Info 'preflight 2/8: SKIP_RESET=1 — reset_local.ps1 is assumed to have already run'
    Write-Host '    Migrations, bootstrap, and grants are assumed current.'
  }
  else {
    Info 'preflight 2/8: scripts/reset_local.ps1 (reset + bootstrap + grants)'

    try {
      & (Join-Path $ScriptDir 'reset_local.ps1')
    }
    catch {
      Fail "reset_local.ps1 failed: $($_.Exception.Message)"
    }
  }

  if ($script:UseDockerPsql) {
    Assert-DockerPsqlReady
  }

  Info 'preflight 3/8: required local database service is available'

  # `supabase status` may return a non-zero exit code when optional
  # services such as imgproxy or the connection pooler are stopped.
  # Batch D only requires the local PostgreSQL service, so verify that
  # dependency directly instead of treating every optional service as
  # mandatory.
  if ($script:UseDockerPsql) {
    Assert-DockerPsqlReady
  }

  Info 'preflight 4/8: admin connection accepts a query'
  if ((Invoke-Query 'select 1') -ne '1') {
    Fail "admin query failed against $($env:PGHOST):$($env:PGPORT)"
  }

  Info 'preflight 5/8: authenticated has USAGE on schema public'
  if (
    (Invoke-Query "select has_schema_privilege('authenticated','public','USAGE')") -ne 't'
  ) {
    Fail 'authenticated LACKS USAGE on schema public — migration 0006 requires revision'
  }

  Info 'preflight 6/8: anon has no USAGE on schema public'
  if (
    (Invoke-Query "select has_schema_privilege('anon','public','USAGE')") -ne 'f'
  ) {
    Fail "anon HAS USAGE on schema public — migration 0006's revocation did not take effect"
  }

  Info 'preflight 7/8: authenticated JWT-claim session reads the seeded catalog'

  $CatalogSql = @'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';
select count(*) from public.exercise_revisions where published;
rollback;
'@

  $CatalogRows = Invoke-Query $CatalogSql

  if (-not $CatalogRows -or [int]$CatalogRows -lt 1) {
    Fail 'authenticated cannot read the seeded published catalog — migration 0006 requires revision'
  }

  Info 'preflight 8/8: authenticated JWT-claim session queries the security-invoker views'

  $ViewSql = @'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';
select count(*) from public.v_latest_published_revision;
select count(*) from public.v_user_practice_summary;
rollback;
'@

  if ($null -eq (Invoke-Query $ViewSql)) {
    Fail 'authenticated cannot query the security-invoker views — migration 0006 requires revision'
  }

  Write-Host ''
  Write-Host 'preflight: PASS. Stack healthy; migration 0006 grant surface behaves as designed.'
  Write-Host ''

  Info 'PHASE 1: 001-005 (requires migrations 0001-0007 only)'

  & $SupabaseCli test db `
    (Join-Path $TestDir '001_schema_invariants.test.sql') `
    (Join-Path $TestDir '002_catalog_immutability.test.sql') `
    (Join-Path $TestDir '003_lifecycle_and_metrics.test.sql') `
    (Join-Path $TestDir '004_rls_isolation.test.sql') `
    (Join-Path $TestDir '005_client_privileges.test.sql')

  if ($LASTEXITCODE -ne 0) {
    Fail 'PHASE 1 pgTAP assertions failed; inspect the TAP output above'
  }

  Write-Host ''
  Write-Host 'PHASE 1: PASS.'
  Write-Host ''

  Info "gate: verifying role $AppRole exists"

  $RolePresent = Invoke-Query @"
select exists (
  select 1
  from pg_catalog.pg_roles
  where rolname = '$AppRole'
)
"@

  if ($RolePresent -ne 't') {
    Fail "role $AppRole does not exist. Run without SKIP_RESET=1."
  }

  Info "PHASE 2: 006 (requires $AppRole + least-privilege grants)"

  & $SupabaseCli test db `
    (Join-Path $TestDir '006_app_role_privileges.test.sql')

  if ($LASTEXITCODE -ne 0) {
    Fail "PHASE 2 pgTAP assertions failed — the $AppRole grant surface is incorrect"
  }

  Write-Host ''
  Write-Host 'PHASE 2: PASS.'
  Write-Host ''
  Write-Host 'ALL BATCH D TESTS PASSED.'
}
catch {
  Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
  $ExitCode = 1
}
finally {
  if (
    $OwnsPgpass -and
    $TempPgpass -and
    (Test-Path -LiteralPath $TempPgpass)
  ) {
    Remove-Item -LiteralPath $TempPgpass -Force -ErrorAction SilentlyContinue
    $env:PGPASSFILE = $null
  }

  if ($OwnsAdminPassword) {
    $env:ADMIN_DB_PASSWORD = $null
  }

  if ($LocationPushed) {
    Pop-Location
  }
}

exit $ExitCode