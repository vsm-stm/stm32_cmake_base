param([Parameter(Mandatory = $true)][string] $TargetTag)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'update-base.cmake'
$updateDir = Join-Path ([System.IO.Path]::GetTempPath()) ('stm32-base-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $updateDir | Out-Null

$keepUpdateDir = $false
try {
    & cmake '-DUPDATE_ACTION=prepare' "-DUPDATE_DIR=$updateDir" "-DTARGET_TAG=$TargetTag" -P $scriptPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not (Test-Path -LiteralPath (Join-Path $updateDir 'files.txt'))) { exit 0 }

    if ((Read-Host 'Apply all listed changes? [y/N]') -ne 'y') { exit 0 }

    $keepUpdateDir = $true
    & cmake '-DUPDATE_ACTION=apply' "-DUPDATE_DIR=$updateDir" -P $scriptPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $keepUpdateDir = $false
} finally {
    if ($keepUpdateDir) {
        Write-Host "Prepared update and backups kept at $updateDir"
    } else {
        Remove-Item -LiteralPath $updateDir -Recurse -Force
    }
}
