#requires -Version 5.1
# Called only when setup.bat cannot find PowerShell 7.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'prerequisites.ps1')
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This bootstrap supports Windows only.' }
    Install-MissingDependencies @('Microsoft.PowerShell')
    $pwsh = Find-Dependency 'Microsoft.PowerShell'
    if (-not $pwsh) { throw 'PowerShell 7 is still unavailable. Reopen setup after installation.' }
    & $pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'setup.ps1')
    exit $LASTEXITCODE
} catch {
    Write-Host "[STOPPED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No execution policy was changed. Follow your approved script trust/install process.'
    exit 1
}
