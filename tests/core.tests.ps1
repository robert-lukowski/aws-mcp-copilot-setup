#requires -Version 7.2
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\core.ps1')
$script:count=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:count++; Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $thrown=$false
    try { & $Action | Out-Null } catch { $thrown=$true }
    Assert $thrown $Message
}
$team=Read-JsonMap (Join-Path $PSScriptRoot '..\team-config.json')
Assert-TeamConfig $team
$original=ConvertFrom-Json -AsHashtable '{"rootSetting":{"keep":true},"mcpServers":{"other":{"command":"custom","tools":["safe"]},"aws-mcp":{"type":"local","command":"uvx","args":["mcp-proxy-for-aws-cli@latest","https://aws-mcp.eu-central-1.api.aws/mcp","--metadata","AWS_REGION=eu-central-1"],"tools":["aws___search_documentation"],"env":{"CUSTOM":"keep"},"deferTools":"never"}}}'
$oldHash=Get-EntryHash $original
$result=New-McpConfig $original 'aws-mcp' 'C:\Users\Test User\.local\bin\mcp-proxy-for-aws-cli.exe' @('dev','test') $team
Assert ((Get-EntryHash $original) -eq $oldHash) 'merge does not mutate input'
Assert ((Get-EntryHash $result.mcpServers.other) -eq (Get-EntryHash $original.mcpServers.other)) 'other server preserved'
Assert $result.rootSetting.keep 'root field preserved'
Assert ($result.mcpServers['aws-mcp'].tools[0] -eq 'aws___search_documentation') 'existing tools restriction preserved'
Assert ($result.mcpServers['aws-mcp'].env.CUSTOM -eq 'keep') 'unrelated environment preserved'
Assert ($result.mcpServers['aws-mcp'].env.AWS_MCP_PROXY_PROFILES -eq 'dev test') 'profile order preserved'
Assert ($result.mcpServers['aws-mcp'].timeout -eq 120000) 'timeout applied'
Assert ($result.mcpServers['aws-mcp'].args[0] -eq 'https://aws-mcp.eu-central-1.api.aws/mcp') 'endpoint remains first arg'
Assert ($result.mcpServers['aws-mcp'].deferTools -eq 'never') 'unknown local field preserved'
$repeat=New-McpConfig $result 'aws-mcp' $result.mcpServers['aws-mcp'].command @('dev','test') $team
Assert ((Get-EntryHash $repeat) -eq (Get-EntryHash $result)) 'merge is idempotent'
# Known uvx forms can migrate to direct execution without dropping custom flags.
foreach ($package in @('mcp-proxy-for-aws-cli','mcp-proxy-for-aws-cli@2.0.0','mcp-proxy-for-aws-cli==2.0.0')) {
    $legacy=Copy-JsonValue $original
    $legacy.mcpServers['aws-mcp'].command='C:\Program Files\uv\uvx.exe'
    $legacy.mcpServers['aws-mcp'].args[0]=$package
    $migrated=New-McpConfig $legacy 'aws-mcp' $result.mcpServers['aws-mcp'].command @('dev','test') $team
    Assert ((Get-EntryHash $migrated) -eq (Get-EntryHash $result)) "baseline uvx form migrates: $package"
}
# Reject changed invocation semantics rather than pretending migration is safe.
$baseline=@('https://aws-mcp.eu-central-1.api.aws/mcp','--metadata','AWS_REGION=eu-central-1')
$cases=@(
    @{Name='read-only restriction'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline)+@('--read-only')},
    @{Name='custom HTTP header'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline)+@('--header','x-tenant=example')},
    @{Name='additional metadata'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline)+@('TENANT=example')},
    @{Name='logging flag'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline)+@('--log-level','DEBUG')},
    @{Name='explicit profile flags'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline)+@('--profile','dev','test')},
    @{Name='OAuth endpoint'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@('https://aws-mcp.eu-central-1.api.aws/mcp?oauth=initialize','--metadata','AWS_REGION=eu-central-1')},
    @{Name='unrelated endpoint'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@('https://example.com/mcp','--metadata','AWS_REGION=eu-central-1')},
    @{Name='wrapper command'; Command='C:\tools\aws-mcp-wrapper.cmd'; Arguments=$baseline},
    @{Name='different uvx package'; Command='uvx'; Arguments=@('other-package')+@($baseline)},
    @{Name='extra uvx flag'; Command='uvx.exe'; Arguments=@('--isolated','mcp-proxy-for-aws-cli@latest')+@($baseline)},
    @{Name='missing metadata'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline[0])},
    @{Name='string instead of array'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=($baseline -join ' ')},
    @{Name='non-string argument'; Command='mcp-proxy-for-aws-cli.exe'; Arguments=@($baseline[0],'--metadata',42)}
)
foreach ($case in $cases) {
    $customInvocation=Copy-JsonValue $result
    $customInvocation.mcpServers['aws-mcp'].command=$case.Command
    $customInvocation.mcpServers['aws-mcp'].args=$case.Arguments
    $before=Get-EntryHash $customInvocation
    $errorText=''
    try { New-McpConfig $customInvocation 'aws-mcp' 'mcp-proxy-for-aws-cli.exe' @('dev','test') $team | Out-Null }
    catch { $errorText=$_.Exception.Message }
    Assert ($errorText -like '*custom or unrecognized proxy invocation*Choose another serverName*') "custom invocation rejected with migration guidance: $($case.Name)"
    Assert ((Get-EntryHash $customInvocation) -eq $before) "rejected invocation stays intact: $($case.Name)"
}
Assert-Throws { New-McpConfig $original 'aws-mcp' 'x' @('dev','dev') $team } 'duplicate profile rejected'
Assert-Throws { New-McpConfig $original 'aws-mcp' 'x' @('dev','test bad') $team } 'whitespace profile rejected'
$remote=ConvertFrom-Json -AsHashtable '{"mcpServers":{"aws-mcp":{"type":"http","url":"https://example.com"}}}'
Assert-Throws { New-McpConfig $remote 'aws-mcp' 'x' @('dev','test') $team } 'remote entry not silently converted'
$broken=ConvertFrom-Json -AsHashtable '{"mcpServers":[]}'
Assert-Throws { New-McpConfig $broken 'aws-mcp' 'x' @('dev','test') $team } 'invalid servers structure rejected'
$fresh=New-McpConfig ([ordered]@{}) 'aws-mcp' 'x' @('dev','test') $team
Assert ($fresh.mcpServers['aws-mcp'].tools[0] -eq '*') 'new config created'
$custom=Copy-JsonValue $fresh
$customPath=Join-Path ([IO.Path]::GetTempPath()) 'existing-aws-config'
$processPath=Join-Path ([IO.Path]::GetTempPath()) 'process-aws-config'
$custom.mcpServers['aws-mcp'].env['AWS_CONFIG_FILE']=$customPath
$paths=Resolve-AwsPaths $custom 'aws-mcp' @{AWS_CONFIG_FILE=$null;AWS_SHARED_CREDENTIALS_FILE=$null}
Assert ($paths.AWS_CONFIG_FILE -eq $customPath) 'existing MCP AWS path used by setup verification'
$paths=Resolve-AwsPaths $custom 'aws-mcp' @{AWS_CONFIG_FILE=$processPath;AWS_SHARED_CREDENTIALS_FILE=$null}
Assert ($paths.AWS_CONFIG_FILE -eq $processPath) 'explicit process override takes precedence for both contexts'
$custom.mcpServers['aws-mcp'].env['AWS_CONFIG_FILE']='${UNKNOWN}/config'
Assert-Throws { Resolve-AwsPaths $custom 'aws-mcp' @{AWS_CONFIG_FILE=$null;AWS_SHARED_CREDENTIALS_FILE=$null} } 'unresolved AWS path expressions rejected'
$manifest=@{serverName='aws-mcp';beforeEntryExisted=$true;beforeEntry=$original.mcpServers['aws-mcp'];afterEntryHash=(Get-EntryHash $result.mcpServers['aws-mcp'])}
$result.mcpServers['new-server']=@{command='new'}
$restored=Restore-McpEntry $result $manifest
Assert ($restored.mcpServers.Contains('new-server')) 'rollback preserves servers added later'
Assert ((Get-EntryHash $restored.mcpServers['aws-mcp']) -eq (Get-EntryHash $original.mcpServers['aws-mcp'])) 'rollback restores original entry'
$changed=Copy-JsonValue $result
$changed.mcpServers['aws-mcp'].timeout=130000
Assert-Throws { Restore-McpEntry $changed $manifest } 'rollback refuses edited target'
$removeManifest=@{serverName='aws-mcp';beforeEntryExisted=$false;beforeEntry=$null;afterEntryHash=(Get-EntryHash $fresh.mcpServers['aws-mcp'])}
$removed=Restore-McpEntry $fresh $removeManifest
Assert (-not $removed.mcpServers.Contains('aws-mcp')) 'rollback removes newly added entry'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('aws-mcp-tests-'+[guid]::NewGuid().ToString('N'))
try {
    $path=Join-Path $tmp 'space dir\config.json'
    Write-JsonAtomic $path $result 'MISSING'
    $roundtrip=Read-JsonMap $path
    Assert ((Get-EntryHash $roundtrip) -eq (Get-EntryHash $result)) 'JSON roundtrip with spaces/backslashes'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'UTF8 without BOM'
    $hash=Get-FileFingerprint $path
    Write-JsonAtomic $path $restored $hash
    Assert ((Get-EntryHash (Read-JsonMap $path)) -eq (Get-EntryHash $restored)) 'atomic replace works'
    Assert-Throws { Write-JsonAtomic $path $result $hash } 'concurrent file edit not overwritten'
    $bad=Join-Path $tmp 'invalid.json'
    [IO.File]::WriteAllText($bad,'{"broken":')
    Assert-Throws { Read-JsonMap $bad } 'malformed JSON rejected'
} finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
foreach ($file in @('setup.ps1','core.ps1','tests/core.tests.ps1')) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../$file"),[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell syntax: $file"
}
Write-Host "`n$script:count assertions passed. No AWS, Copilot or uv processes were run."
