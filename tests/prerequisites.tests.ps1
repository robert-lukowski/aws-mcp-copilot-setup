#requires -Version 7.2
# No WinGet, installers, AWS or Copilot commands run in this test.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\prerequisites.ps1')
$script:count=0
function Assert($Condition,$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:count++; Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Action,$Message) {
    $thrown=$false
    try { & $Action | Out-Null } catch { $thrown=$true }
    Assert $thrown $Message
}
foreach ($id in @('Microsoft.PowerShell','Amazon.AWSCLI','GitHub.Copilot','astral-sh.uv')) {
    $a=@(Get-WinGetInstallArgs $id)
    Assert ($a[2] -eq $id -and $a -contains '--exact' -and $a -contains '--no-upgrade') "explicit ID and no upgrade: $id"
    Assert ($a -notcontains '--accept-package-agreements' -and $a -notcontains '--accept-source-agreements' -and $a -notcontains '--force') "no forced approval/bypass: $id"
}
Assert-Throws { Get-WinGetInstallArgs 'Unknown.Package' } 'unapproved package ID rejected'
function Reset-TestState {
    $script:installed=@{}
    $script:calls=@()
    $script:wingetAvailable=$true
    $script:answer='y'
    $script:installCode=0
    $script:revealAfterInstall=$true
    $script:refreshes=0
    $script:prompts=0
}
function Find-Dependency([string]$Id) {
    if ($script:installed.ContainsKey($Id)) { return $script:installed[$Id] }
    return $null
}
function Find-Program { if ($script:wingetAvailable) { return 'mock-winget.exe' }; return $null }
function Read-Host { param($Prompt) $script:prompts++; return $script:answer }
function Refresh-SetupPath { $script:refreshes++ }
function Invoke-WinGetInstall([string]$WinGet,[string[]]$InstallArgs) {
    $id=$InstallArgs[2]
    $script:calls+= $id
    if ($script:revealAfterInstall -and $script:installCode -eq 0) { $script:installed[$id]="mock-$id.exe" }
    return $script:installCode
}
Reset-TestState
$script:installed['Amazon.AWSCLI']='existing-aws.exe'
$script:installed['GitHub.Copilot']='existing-npm-copilot.cmd'
Install-MissingDependencies @('Amazon.AWSCLI','GitHub.Copilot')
Assert ($script:calls.Count -eq 0 -and $script:prompts -eq 0) 'existing tools cause no install or prompt'
Install-MissingDependencies @('Amazon.AWSCLI','GitHub.Copilot','astral-sh.uv')
Assert ($script:calls.Count -eq 1 -and $script:calls[0] -eq 'astral-sh.uv') 'only missing dependency installed'
Assert ($script:installed['GitHub.Copilot'] -eq 'existing-npm-copilot.cmd') 'existing npm Copilot retained'
Assert ($script:refreshes -eq 1) 'process PATH refresh after install'
Reset-TestState
$script:answer='n'
Assert-Throws { Install-MissingDependencies @('Amazon.AWSCLI') } 'declined install stops'
Assert ($script:calls.Count -eq 0) 'declined install launches nothing'
Reset-TestState
$script:wingetAvailable=$false
Assert-Throws { Install-MissingDependencies @('Amazon.AWSCLI') } 'missing WinGet stops with no fallback'
Assert ($script:calls.Count -eq 0) 'no package calls without WinGet'
Reset-TestState
$script:installCode=5
Assert-Throws { Install-MissingDependencies @('Amazon.AWSCLI','GitHub.Copilot') } 'installer failure stops sequence'
Assert ($script:calls.Count -eq 1) 'no forced retry or next package after failure'
Reset-TestState
$script:installCode=3010
Assert-Throws { Install-MissingDependencies @('Microsoft.PowerShell') } 'reboot-required result stops setup'
Reset-TestState
$script:revealAfterInstall=$false
Assert-Throws { Install-MissingDependencies @('GitHub.Copilot') } 'success exit without discoverable executable rejected'
foreach ($file in @('bootstrap.ps1','prerequisites.ps1','setup.ps1','tests/prerequisites.tests.ps1')) {
    $t=$null; $e=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../$file"),[ref]$t,[ref]$e)
    Assert ($e.Count -eq 0) "syntax: $file"
}
Write-Host "`n$script:count prerequisite assertions passed; all installer calls mocked."
