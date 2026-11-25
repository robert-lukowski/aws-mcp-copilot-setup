# Shared with the Windows PowerShell 5.1 bootstrap. Keep this file 5.1-compatible.
function Find-Program([string[]]$Names, [string[]]$Fallbacks = @()) {
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    foreach ($path in $Fallbacks) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    return $null
}

function Refresh-SetupPath {
    # Refresh only this process. Never write machine/user registry settings.
    $parts = @($env:PATH, [Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User'))
    $unique = @()
    foreach ($part in (($parts -join ';') -split ';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($part).Trim()
        if ($expanded -and $unique -notcontains $expanded) { $unique += $expanded }
    }
    $env:PATH = $unique -join ';'
}

function Find-WinGetPortable([string]$PackageId,[string]$ExeName) {
    $root = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $matches = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$PackageId`_*" })) {
        $matches += @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue)
    }
    if ($matches.Count -eq 1) { return $matches[0].FullName }
    # Ambiguous installations should be resolved by PATH, not by guessing newest.
    return $null
}

function Find-Dependency([string]$Id) {
    switch ($Id) {
        'Microsoft.PowerShell' {
            return Find-Program @('pwsh.exe') @("$env:ProgramFiles\PowerShell\7\pwsh.exe")
        }
        'Amazon.AWSCLI' {
            return Find-Program @('aws.exe') @("$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe")
        }
        'GitHub.Copilot' {
            $path = Find-Program @('copilot.cmd','copilot.exe') @("$env:APPDATA\npm\copilot.cmd", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\copilot.exe")
            if ($path) { return $path }
            return Find-WinGetPortable $Id 'copilot.exe'
        }
        'astral-sh.uv' {
            $path = Find-Program @('uv.exe') @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\uv.exe", "$env:USERPROFILE\.local\bin\uv.exe", "$env:USERPROFILE\.cargo\bin\uv.exe")
            if ($path) { return $path }
            return Find-WinGetPortable $Id 'uv.exe'
        }
        default { throw "Unsupported dependency: $Id" }
    }
}

function Get-WinGetInstallArgs([string]$Id) {
    if ($Id -notin @('Microsoft.PowerShell','Amazon.AWSCLI','GitHub.Copilot','astral-sh.uv')) { throw 'Package is not on the installer allowlist.' }
    return @('install','--id',$Id,'--exact','--source','winget','--no-upgrade','--interactive')
}

function Invoke-WinGetInstall([string]$WinGet,[string[]]$InstallArgs) {
    # Keep interactive installer/agreements visible, without polluting the return value.
    & $WinGet @InstallArgs | Out-Host
    return $LASTEXITCODE
}

function Install-MissingDependencies([string[]]$PackageIds) {
    $pending = @()
    foreach ($id in $PackageIds) {
        $null = Get-WinGetInstallArgs $id
        if (-not (Find-Dependency $id)) { $pending += $id }
    }
    if (-not $pending.Count) { return }
    $winget = Find-Program @('winget.exe') @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")
    if (-not $winget) {
        throw 'WinGet is unavailable. Install the missing tools through Company Portal/Software Center or ask IT. Then reopen setup.bat; MCP config has not been changed.'
    }
    Write-Host "`nMissing packages to install from the winget source:" -ForegroundColor Cyan
    foreach ($id in $pending) { Write-Host "  $id" }
    Write-Host 'Only missing tools will be installed. Existing installations are not automatically upgraded.'
    Write-Host 'WinGet will select available stable releases. Installer/license prompts may appear.'
    Write-Host 'Windows may request administrator approval. Use your approved company installation process if access is denied.'
    $answer = Read-Host 'Install these missing packages now? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { throw 'Dependency installation declined. Nothing further was changed.' }
    foreach ($id in $pending) {
        # Check again: an earlier package may have installed this as a dependency.
        if (Find-Dependency $id) { continue }
        $installArgs = @(Get-WinGetInstallArgs $id)
        Write-Host "`nInstalling $id..."
        $code = Invoke-WinGetInstall $winget $installArgs
        if ($code -in @(3010,1641)) {
            throw "The installer requested a Windows restart (exit code $code). Restart, then rerun setup.bat. No MCP configuration was changed."
        }
        if ($code -ne 0) {
            throw "WinGet returned exit code $code for $id. Resolve the displayed error or restart if requested, then rerun setup. Already installed packages remain installed; no forced retry will run."
        }
        Refresh-SetupPath
        $resolved = Find-Dependency $id
        if (-not $resolved) { throw "$id installation returned success but the program is not discoverable. Reopen your terminal or restart as requested, then retry setup." }
        Write-Host "[INSTALLED] $id -> $resolved"
    }
}
