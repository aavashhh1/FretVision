#Requires -Version 5.1
<#
.SYNOPSIS
Fixes invalid schema-qualified COALESCE expressions in FretVision SQL files.

.DESCRIPTION
PostgreSQL COALESCE is SQL syntax, not a normal pg_catalog function.
Expressions such as pg_catalog.coalesce(...) are therefore invalid.

This script:
  1. Scans all *.sql files under supabase/migrations and
     supabase/tests/database.
  2. Creates one timestamped backup for every modified file.
  3. Replaces pg_catalog.coalesce( with coalesce(.
  4. Verifies that no invalid occurrence remains.
  5. Does not change pgTAP plan counts.

Run from the repository root:
  .\scripts\fix_sql_coalesce.ps1
#>

[CmdletBinding()]
param(
  [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string] $Message) {
  Write-Host "==> $Message"
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Content
  )

  [System.IO.File]::WriteAllText(
    $Path,
    $Content,
    [System.Text.UTF8Encoding]::new($false)
  )
}

$ResolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$SearchRoots = @(
  (Join-Path $ResolvedRoot 'supabase\migrations'),
  (Join-Path $ResolvedRoot 'supabase\tests\database')
)

foreach ($SearchRoot in $SearchRoots) {
  if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
    throw "Required directory does not exist: $SearchRoot"
  }
}

$SqlFiles = @(
  foreach ($SearchRoot in $SearchRoots) {
    Get-ChildItem -LiteralPath $SearchRoot -Filter '*.sql' -File -Recurse
  }
)

if ($SqlFiles.Count -eq 0) {
  throw 'No SQL files were found under the migration and database-test directories.'
}

$InvalidPattern = 'pg_catalog\.coalesce\s*\('
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ModifiedFiles = New-Object System.Collections.Generic.List[string]
$TotalReplacements = 0

Write-Info "scanning $($SqlFiles.Count) SQL files"

foreach ($File in $SqlFiles) {
  $Original = [System.IO.File]::ReadAllText($File.FullName)
  $Matches = [regex]::Matches(
    $Original,
    $InvalidPattern,
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  if ($Matches.Count -eq 0) {
    continue
  }

  $BackupPath = "$($File.FullName).before-coalesce-fix-$Timestamp.bak"
  [System.IO.File]::Copy($File.FullName, $BackupPath, $false)

  $Fixed = [regex]::Replace(
    $Original,
    $InvalidPattern,
    'coalesce(',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  Write-Utf8NoBom -Path $File.FullName -Content $Fixed

  $ModifiedFiles.Add($File.FullName)
  $TotalReplacements += $Matches.Count

  Write-Host "    fixed $($Matches.Count): $($File.FullName)"
  Write-Host "    backup: $BackupPath"
}

if ($TotalReplacements -eq 0) {
  throw @'
No pg_catalog.coalesce(...) occurrence was found.
The files may already be fixed, or the failing SQL differs from the files being scanned.
'@
}

$Remaining = @(
  foreach ($File in $SqlFiles) {
    $Text = [System.IO.File]::ReadAllText($File.FullName)
    if ([regex]::IsMatch(
      $Text,
      $InvalidPattern,
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) {
      $File.FullName
    }
  }
)

if ($Remaining.Count -gt 0) {
  throw "Verification failed. Invalid pg_catalog.coalesce remains in: $($Remaining -join ', ')"
}

Write-Host ''
Write-Host 'SQL COALESCE FIX: PASS' -ForegroundColor Green
Write-Host "Modified files: $($ModifiedFiles.Count)"
Write-Host "Replacements:   $TotalReplacements"
Write-Host ''
Write-Host 'No pgTAP plan count was changed.'
Write-Host 'Re-run:'
Write-Host '  $env:FRETVISION_APP_PASSWORD = ''FretVision-Local-Only-2026!'''
Write-Host '  .\scripts\run_db_tests.ps1'
