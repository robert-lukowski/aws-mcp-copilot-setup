#requires -Version 7.2
# Offline integration test: external tools, user input and AWS identities are mocked.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\core.ps1')
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\setup.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Setup syntax errors.' }
# Load only our source function definitions, never the executable main section.
foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Find-Tools { return $true }
function Confirm { param($Question,$Default) return $true }
function Select-Profile { param($Template) return $Template.suggestedName }
function Test-Identity {
    param($Profile,$AllowLogin)
    $account=if ($script:SameAccount) {'111111111111'} elseif ($Profile -eq $script:Team.profiles[0].suggestedName) {'111111111111'} else {'222222222222'}
    return @{Account=$account;Arn="arn:aws:sts::${account}:assumed-role/TestRole/TestSession"}
}
function Ensure-Proxy { return 'C:\test\mcp-proxy-for-aws-cli.exe' }
function Read-Host { param($Prompt) return '1' }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('mcp-workflow-'+[guid]::NewGuid().ToString('N'))
$savedPaths=@{}
$script:Team=Read-JsonMap (Join-Path $PSScriptRoot '..\team-config.json')
$script:ConfigPath=Join-Path $temp 'copilot\mcp-config.json'
$script:StateRoot=Join-Path $temp 'backups'
$script:passes=0
$script:SameAccount=$false
function Assert($Condition,$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passes++; Write-Host "PASS: $Message"
}
try {
    foreach ($key in @('AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE')) {
        $savedPaths[$key]=[Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key,$null)
    }
    $original=ConvertFrom-Json -AsHashtable '{"mcpServers":{"other":{"command":"keep"},"aws-mcp":{"command":"uvx","args":["mcp-proxy-for-aws-cli@latest","https://aws-mcp.eu-central-1.api.aws/mcp","--metadata","AWS_REGION=eu-central-1"],"tools":["safe"]}}}'
    Write-JsonAtomic $script:ConfigPath $original 'MISSING'
    Run-Setup
    $current=Read-Mcp
    Assert ($current.mcpServers['aws-mcp'].timeout -eq 120000) 'workflow writes intended server'
    $records=@(Get-ChildItem -LiteralPath $script:StateRoot -Recurse -Filter manifest.json)
    Assert ($records.Count -eq 1) 'workflow makes one rollback record'
    $manifest=Read-JsonMap $records[0].FullName
    Assert ($manifest.status -eq 'applied') 'manifest marked applied'
    Assert ((Get-EntryHash (Read-JsonMap (Join-Path $records[0].Directory.FullName 'mcp-config.before.json'))) -eq (Get-EntryHash $original)) 'backup contains original configuration'
    $hash=Get-FileFingerprint $script:ConfigPath
    Run-Setup
    Assert ((Get-FileFingerprint $script:ConfigPath) -eq $hash) 'repeat setup does not rewrite config'
    Assert (@(Get-ChildItem -LiteralPath $script:StateRoot -Recurse -Filter manifest.json).Count -eq 1) 'repeat setup does not create duplicate backup'
    $current.mcpServers['added-later']=@{command='preserve-me'}
    Write-JsonAtomic $script:ConfigPath $current $hash
    Run-Rollback
    $restored=Read-Mcp
    Assert ($restored.mcpServers['added-later'].command -eq 'preserve-me') 'workflow rollback preserves unrelated edit'
    Assert ((Get-EntryHash $restored.mcpServers['aws-mcp']) -eq (Get-EntryHash $original.mcpServers['aws-mcp'])) 'workflow rollback restores server'
    Assert ((Read-JsonMap $records[0].FullName).status -eq 'rolledBack') 'rollback manifest updated'
    $hash=Get-FileFingerprint $script:ConfigPath
    $script:Team.profiles[0].expectedAccountId='333333333333'
    $failed=$false
    try { Run-Setup } catch { $failed=$true }
    Assert $failed 'wrong account stops workflow'
    Assert ((Get-FileFingerprint $script:ConfigPath) -eq $hash) 'wrong account leaves config untouched'
    $script:Team.profiles[0].expectedAccountId=''
    $script:Team.profiles[0].suggestedName='readonly'
    $script:Team.profiles[1].suggestedName='operator'
    $script:SameAccount=$true
    Run-Setup
    $current=Read-Mcp
    Assert ($current.mcpServers['aws-mcp'].env.AWS_MCP_PROXY_PROFILES -ceq 'readonly operator') 'arbitrary profile names and same-account roles are accepted in order'
    $hash=Get-FileFingerprint $script:ConfigPath
    $script:Team.profiles[1].suggestedName='readonly'
    $failed=$false
    try { Run-Setup } catch { $failed=$true }
    Assert $failed 'duplicate profile names stop setup'
    Assert ((Get-FileFingerprint $script:ConfigPath) -eq $hash) 'duplicate profiles leave config untouched'

} finally {
    foreach ($key in $savedPaths.Keys) { [Environment]::SetEnvironmentVariable($key,$savedPaths[$key]) }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
Write-Host "`n$script:passes workflow assertions passed. External tools and AWS were mocked."
