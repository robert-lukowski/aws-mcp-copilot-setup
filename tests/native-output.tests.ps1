#requires -Version 7.2
# Exercise real setup functions with CLI stdout/exit codes simulated locally.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../core.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../setup.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Setup syntax errors.' }
foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:passes=0
function Assert($Condition,$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passes++; Write-Host "PASS: $Message"
}
function Confirm { param($Question,$Default) return $script:Approve }
function Invoke-FakeAws {
    $global:LASTEXITCODE=0
    switch ($args[0]) {
        'sts' {
            $script:StsCalls++
            if ($script:StsCalls -eq 1) { $global:LASTEXITCODE=1; return }
            return $script:StsJson
        }
        'sso' {
            'Successfully logged into Start URL: https://example.invalid/start'
            $global:LASTEXITCODE=$script:LoginExit
        }
        'configure' {
            'Opening SSO configuration wizard'
            'Profile configured successfully'
        }
        default { throw 'Unexpected fake AWS command.' }
    }
}
$script:Aws='Invoke-FakeAws'
$script:Approve=$true
$script:LoginExit=0
$script:StsCalls=0
$script:StsJson='{"Account":"111111111111","Arn":"arn:aws:sts::111111111111:assumed-role/ExampleRole/session"}'
$items=@(Test-Identity 'example' $true)
Assert ($items.Count -eq 1) 'SSO stdout is not part of identity return value'
Assert ($items[0].Account -eq '111111111111') 'identity available after successful SSO'
Assert ($script:StsCalls -eq 2) 'STS retried after SSO'
$script:StsCalls=0; $script:LoginExit=1
$failed=$false
try { Test-Identity 'example' $true | Out-Null } catch { $failed=$true }
Assert $failed 'failed login stops identity verification'
Assert ($script:StsCalls -eq 1) 'failed login does not retry STS'
$script:StsCalls=1; $script:StsJson='{}'
$message=''
try { Test-Identity 'example' $false | Out-Null } catch { $message=$_.Exception.Message }
Assert ($message -eq 'Unexpected STS response.') 'missing identity fields produce a clear error'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('mcp-output-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $script:Team=Read-JsonMap (Join-Path $PSScriptRoot '../team-config.json')
    $script:ProfileCalls=0
    function Get-Profiles { $script:ProfileCalls++; if ($script:ProfileCalls -gt 1) { 'new-profile' } }
    function Get-AwsConfigPath { return (Join-Path $temp 'missing-config') }
    $script:Answers=[Collections.Generic.Queue[string]]::new()
    $script:Answers.Enqueue('N'); $script:Answers.Enqueue('new-profile')
    function Read-Host { param($Prompt) return $script:Answers.Dequeue() }
    $items=@(Select-Profile $script:Team.profiles[0])
    Assert ($items.Count -eq 1) 'wizard stdout is not part of profile return value'
    Assert ($items[0] -ceq 'new-profile') 'wizard returns only selected profile'
    $script:Uv='Invoke-FakeUv'
    function Invoke-FakeUv {
        $global:LASTEXITCODE=0
        if ($args[1] -eq 'dir') { return $temp }
        if ($args[1] -eq 'install') {
            'Installed proxy package successfully'
            New-Item -ItemType File -Path (Join-Path $temp 'mcp-proxy-for-aws-cli.exe') | Out-Null
            return
        }
        throw 'Unexpected fake uv command.'
    }
    # Mock only executable --help; other calls still exercise Capture.
    $script:RealCapture=${function:Capture}
    function Capture {
        param($Exe,$Arguments)
        if ($Exe -eq (Join-Path $temp 'mcp-proxy-for-aws-cli.exe')) {
            return @{Code=0;Text="MCP Proxy for AWS v$($script:Team.proxyVersion)"}
        }
        & $script:RealCapture $Exe $Arguments
    }
    $items=@(Ensure-Proxy)
    Assert ($items.Count -eq 1) 'install stdout is not part of executable return value'
    Assert ($items[0] -eq (Join-Path $temp 'mcp-proxy-for-aws-cli.exe')) 'install returns only executable path'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Host "$script:passes CLI output assertions passed. No external tools or AWS calls."
